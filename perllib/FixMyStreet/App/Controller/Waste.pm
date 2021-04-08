package FixMyStreet::App::Controller::Waste;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller' }

use utf8;
use Lingua::EN::Inflect qw( NUMWORDS );
use FixMyStreet::App::Form::Waste::UPRN;
use FixMyStreet::App::Form::Waste::AboutYou;
use FixMyStreet::App::Form::Waste::Request;
use FixMyStreet::App::Form::Waste::Report;
use FixMyStreet::App::Form::Waste::Enquiry;
use FixMyStreet::App::Form::Waste::Garden;
use FixMyStreet::App::Form::Waste::Garden::Modify;
use FixMyStreet::App::Form::Waste::Garden::Cancel;
use FixMyStreet::App::Form::Waste::Garden::Renew;
use Open311::GetServiceRequestUpdates;
use Integrations::SCP;
use Digest::MD5 qw(md5_hex);

sub auto : Private {
    my ( $self, $c ) = @_;
    my $cobrand_check = $c->cobrand->feature('waste');
    $c->detach( '/page_error_404_not_found' ) if !$cobrand_check;
    return 1;
}

sub index : Path : Args(0) {
    my ( $self, $c ) = @_;

    if (my $id = $c->get_param('address')) {
        $c->cobrand->call_hook('clear_cached_lookups', => $id );
        $c->detach('redirect_to_id', [ $id ]);
    }

    $c->stash->{title} = 'What is your address?';
    my $form = FixMyStreet::App::Form::Waste::UPRN->new( cobrand => $c->cobrand );
    $form->process( params => $c->req->body_params );
    if ($form->validated) {
        my $addresses = $form->value->{postcode};
        $form = address_list_form($addresses);
    }
    $c->stash->{form} = $form;
}

sub address_list_form {
    my $addresses = shift;
    HTML::FormHandler->new(
        field_list => [
            address => {
                required => 1,
                type => 'Select',
                widget => 'RadioGroup',
                label => 'Select an address',
                tags => { last_differs => 1, small => 1 },
                options => $addresses,
            },
            go => {
                type => 'Submit',
                value => 'Continue',
                element_attr => { class => 'govuk-button' },
            },
        ],
    );
}

sub redirect_to_id : Private {
    my ($self, $c, $id) = @_;
    my $uri = '/waste/' . $id;
    my $type = $c->get_param('type') || '';
    $uri .= '/request' if $type eq 'request';
    $uri .= '/report' if $type eq 'report';
    $c->res->redirect($uri);
    $c->detach;
}

sub check_payment_redirect_id : Private {
    my ( $self, $c, $id, $token ) = @_;

    $c->detach( '/page_error_404_not_found' ) unless $id =~ /^\d+$/;

    my $p = $c->model('DB::Problem')->find({
        id => $id,
    });

    $c->detach( '/page_error_404_not_found' )
        unless $p && $p->get_extra_metadata('redirect_id') eq $token;

    if ( $p->state ne 'unconfirmed' ) {
        $c->stash->{error} = 'Already confirmed';
        $c->stash->{template} = 'waste/pay.html';
        $c->detach;
    }

    $c->stash->{report} = $p;
}

sub pay : Path('pay') : Args(0) {
    my ($self, $c, $id) = @_;

    my $payment = Integrations::SCP->new({
        config => $c->cobrand->feature('payment_gateway')
    });

    my $p = $c->stash->{report};

    my $amount = $p->get_extra_field( name => 'pro_rata' );
    unless ($amount) {
        $amount = $p->get_extra_field( name => 'payment' );
    }

    my $redirect_id = mySociety::AuthToken::random_token();
    $p->set_extra_metadata('redirect_id', $redirect_id);
    $p->update;

    my $result = $payment->pay({
        returnUrl => $c->uri_for('pay_complete', $p->id, $redirect_id ) . '',
        backUrl => $c->uri_for('pay') . '',
        ref => $p->id,
        request_id => $p->id,
        description => $p->title,
        amount => $amount->{value},
    });

    if ( $result ) {
        $c->stash->{xml} = $result;

        # GET back
        # requestId - should match above
        # scpReference - transaction Ref, used later for query
        # transactionState - in progress/complete
        # invokeResult/status - SUCCESS/INVALID_REQUEST/ERROR
        # invokeResult/redirectURL - what is says
        # invokeResult/errorDetails - what it says
        #
        if ( $result->{transactionState} eq 'COMPLETE' &&
             $result->{invokeResult}->{status} eq 'SUCCESS' ) {

             $p->set_extra_metadata('scpReference', $result->{scpReference});
             $p->update;

             # need to save scpReference against request here
             my $redirect = $result->{invokeResult}->{redirectURL};
             $c->res->redirect( $redirect );
             $c->detach;
         } else {
             # XXX - should this do more?
            $c->stash->{error} = 'Unknown error';
            $c->stash->{template} = 'waste/pay.html';
            $c->detach;
         }
     } else {
        $c->stash->{error} = 'Unknown error';
        $c->stash->{template} = 'waste/pay.html';
        $c->detach;
    }
}

# redirect from cc processing
sub pay_complete : Path('pay_complete') : Args(2) {
    my ($self, $c, $id, $token) = @_;

    $c->forward('check_payment_redirect_id', [ $id, $token ]);
    my $p = $c->stash->{report};

    # need to get some ID Things which I guess we stored in pay
    my $scpReference = $p->get_extra_metadata('scpReference');
    $c->detach( '/page_error_404_not_found' ) unless $scpReference;

    my $payment = Integrations::SCP->new(
        config => $c->cobrand->feature('payment_gateway')
    );

    my $resp = $payment->query({
        scpReference => $scpReference,
    });

    if ($resp->{transactionState} eq 'COMPLETE') {
        if ($resp->{paymentResult}->{status} eq 'SUCCESS') {
            # create sub in echo
            my $ref = $resp->{paymentResult}->{paymentDetails}->{paymentHeader}->{uniqueTranId};
            $c->stash->{message} = 'Payment succesful';
            $c->stash->{reference} = $ref;
            $c->forward( 'confirm_subscription', [ $ref ] );
        } else {
            # cancelled, not attempted, logged out - try again option
            # card rejected - try again with different card/cancel
            # otherwise error page?
            $c->stash->{template} = 'waste/pay.html';
            $c->stash->{error} = 'Payment failed: ' . $resp->{paymentResult}->{status};
            $c->detach;
        }
    } else {
        # retry if in progress, error if invalid ref.
        $c->stash->{template} = 'waste/pay.html';
        $c->stash->{error} = 'Payment failed: ' . $resp->{transactionState};
        $c->detach;
    }
}

sub confirm_subscription : Private {
    my ($self, $c, $reference) = @_;

    my $p = $c->stash->{report};
    $p->set_extra_metadata('payment_reference', $reference) if $reference;
    $p->confirm;
    $p->update;
    $c->stash->{template} = 'waste/garden/subscribe_confirm.html';
    $c->detach;
}

sub cancel_subscription : Private {
    my ($self, $c, $reference) = @_;

    $c->stash->{template} = 'waste/garden/cancel_confirmation.html';
    $c->detach;
}

sub populate_dd_details : Private {
    my ($self, $c) = @_;

    my $p = $c->stash->{report};
    my $reference = mySociety::AuthToken::random_token();
    $p->set_extra_metadata('redirect_id', $reference);
    $p->update;

    my $address = $c->stash->{property}{address};

    my @parts = split ',', $address;

    my $name = $c->stash->{report}->name;
    my ($first, $last) = split /\s/, $name, 2;

    $c->stash->{account_holder} = $name;
    $c->stash->{first_name} = $first;
    $c->stash->{last_name} = $last;
    $c->stash->{address1} = shift @parts;
    $c->stash->{address2} = shift @parts;
    $c->stash->{postcode} = pop @parts;
    $c->stash->{town} = pop @parts;
    $c->stash->{address3} = join ', ', @parts;

    my $dt = $c->cobrand->waste_get_next_dd_day;

    my $payment_details = $c->cobrand->feature('payment_gateway');
    $c->stash->{payment_details} = $payment_details;
    $c->stash->{amount} = sprintf( '%.2f', $c->stash->{report}->get_extra_field(name => 'payment')->{value} / 100 ),
    $c->stash->{reference} = $p->id;
    $c->stash->{lookup} = $reference;
    $c->stash->{payment_date} = $dt;
    $c->stash->{day} = $dt->day;
    $c->stash->{month} = $dt->month;
    $c->stash->{year} = $dt->year;
}

sub direct_debit : Path('dd') : Args(0) {
    my ($self, $c) = @_;

    $c->forward('populate_dd_details');
    $c->stash->{template} = 'waste/dd.html';
    $c->detach;
}

# we process direct debit payments when they happen so this page
# is only for setting expectations.
sub direct_debit_complete : Path('dd_complete') : Args(0) {
    my ($self, $c) = @_;

    my $token = $c->get_param('reference');
    my $id = $c->get_param('report_id');
    $c->forward('check_payment_redirect_id', [ $id, $token]);

    $c->stash->{title} = "Direct Debit mandate";

    $c->stash->{template} = 'waste/dd_complete.html';
}

sub direct_debit_cancelled : Path('dd_cancelled') : Args(0) {
    my ($self, $c) = @_;

    my $id = $c->get_param('reference');
    if ( $id ) {
        $c->forward('check_payment_redirect_id', [ $id ]);
        $c->forward('populate_dd_details');
    }

    $c->stash->{template} = 'waste/dd_cancelled.html';
}

sub direct_debit_modify : Path('dd_amend') : Args(0) {
    my ($self, $c) = @_;

    my $p = $c->stash->{report};

    my $ad_hoc = $p->get_extra_field_value('pro_rata');
    my $total = $p->get_extra_field_value('payment');

    my $i = Integrations::Pay360->new( { config => $c->cobrand->feature('payment_gateway') } );

    # if reducing bin count then there won't be an ad-hoc payment
    if ( $ad_hoc ) {
        my $dt = $c->cobrand->waste_get_next_dd_day;

        my $one_off_ref = $i->one_off_payment( {
                payer_reference => 1, # XXX
                amount => sprintf('%.2f', $ad_hoc / 100),
                reference => $p->id,
                comments => '',
        } );
    }

    my $update_ref = $i->amend_plan( {
        payer_reference => 1, # XXX
        amount => sprintf('%.2f', $total / 100),
    } );
}

sub direct_debit_cancel_sub : Path('dd_cancel_sub') : Args(0) {
    my ($self, $c) = @_;

    my $p = $c->stash->{report};

    my $i = Integrations::Pay360->new( { config => $c->cobrand->feature('payment_gateway') } );

    my $update_ref = $i->cancel_plan( {
        payer_reference => 1, # XXX
    } );
}

sub direct_debit_renew : Path('dd_renew') : Args(0) {
    my ($self, $c) = @_;

    $c->res->body('ERROR - DD renewal is automatic');
}

sub property : Chained('/') : PathPart('waste') : CaptureArgs(1) {
    my ($self, $c, $id) = @_;

    if ($id eq 'missing') {
        $c->stash->{template} = 'waste/missing.html';
        $c->detach;
    }

    $c->forward('/auth/get_csrf_token');

    # clear this every time they visit this page to stop stale content.
    $c->log->debug($c->req->path);
    if ( $c->req->path =~ m#^waste/\d+$# ) {
        $c->log->debug('clear cache');
        $c->cobrand->call_hook( 'clear_cached_lookups' => $id );
    }

    my $property = $c->stash->{property} = $c->cobrand->call_hook(look_up_property => $id);
    $c->detach( '/page_error_404_not_found', [] ) unless $property;

    $c->stash->{latitude} = $property->{latitude};
    $c->stash->{longitude} = $property->{longitude};

    $c->stash->{service_data} = $c->cobrand->call_hook(bin_services_for_address => $property) || [];
    $c->stash->{services} = { map { $_->{service_id} => $_ } @{$c->stash->{service_data}} };
    $c->stash->{services_available} = $c->cobrand->call_hook(available_bin_services_for_address => $property) || {};
}

sub bin_days : Chained('property') : PathPart('') : Args(0) {
    my ($self, $c) = @_;
}

sub calendar : Chained('property') : PathPart('calendar.ics') : Args(0) {
    my ($self, $c) = @_;
    $c->res->header(Content_Type => 'text/calendar');
    require Data::ICal::RFC7986;
    require Data::ICal::Entry::Event;
    my $calendar = Data::ICal::RFC7986->new(
        calname => 'Bin calendar',
        rfc_strict => 1,
        auto_uid => 1,
    );
    $calendar->add_properties(
        prodid => '//FixMyStreet//Bin Collection Calendars//EN',
        method => 'PUBLISH',
        'refresh-interval' => [ 'P1D', { value => 'DURATION' } ],
        'x-published-ttl' => 'P1D',
        calscale => 'GREGORIAN',
        'x-wr-timezone' => 'Europe/London',
        source => [ $c->uri_for_action($c->action, [ $c->stash->{property}{id} ]), { value => 'URI' } ],
        url => $c->uri_for_action('waste/bin_days', [ $c->stash->{property}{id} ]),
    );

    my $events = $c->cobrand->bin_future_collections;
    my $stamp = DateTime->now->strftime('%Y%m%dT%H%M%SZ');
    foreach (@$events) {
        my $event = Data::ICal::Entry::Event->new;
        $event->add_properties(
            summary => $_->{summary},
            description => $_->{desc},
            dtstamp => $stamp,
            dtstart => [ $_->{date}->ymd(''), { value => 'DATE' } ],
            dtend => [ $_->{date}->add(days=>1)->ymd(''), { value => 'DATE' } ],
        );
        $calendar->add_entry($event);
    }

    $c->res->body($calendar->as_string);
}

sub construct_bin_request_form {
    my $c = shift;

    my $field_list = [];

    foreach (@{$c->stash->{service_data}}) {
        next unless $_->{next} && !$_->{request_open};
        my $name = $_->{service_name};
        my $containers = $_->{request_containers};
        my $max = $_->{request_max};
        foreach my $id (@$containers) {
            push @$field_list, "container-$id" => {
                type => 'Checkbox',
                apply => [
                    {
                        when => { "quantity-$id" => sub { $_[0] > 0 } },
                        check => qr/^1$/,
                        message => 'Please tick the box',
                    },
                ],
                label => $name,
                option_label => $c->stash->{containers}->{$id},
                tags => { toggle => "form-quantity-$id-row" },
            };
            $name = ''; # Only on first container
            push @$field_list, "quantity-$id" => {
                type => 'Select',
                label => 'Quantity',
                tags => {
                    hint => "You can request a maximum of " . NUMWORDS($max) . " containers",
                    initial_hidden => 1,
                },
                options => [
                    { value => "", label => '-' },
                    map { { value => $_, label => $_ } } (1..$max),
                ],
                required_when => { "container-$id" => 1 },
            };
        }
    }

    return $field_list;
}

sub request : Chained('property') : Args(0) {
    my ($self, $c) = @_;

    my $field_list = construct_bin_request_form($c);

    $c->stash->{first_page} = 'request';
    $c->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Request';
    $c->stash->{page_list} = [
        request => {
            fields => [ grep { ! ref $_ } @$field_list, 'submit' ],
            title => 'Which containers do you need?',
            next => 'about_you',
        },
    ];
    $c->stash->{field_list} = $field_list;
    $c->forward('form');
}

sub process_request_data : Private {
    my ($self, $c, $form) = @_;
    my $data = $form->saved_data;
    my $address = $c->stash->{property}->{address};
    my @services = grep { /^container-/ && $data->{$_} } keys %$data;
    foreach (@services) {
        my ($id) = /container-(.*)/;
        my $container = $c->stash->{containers}{$id};
        my $quantity = $data->{"quantity-$id"};
        $data->{title} = "Request new $container";
        $data->{detail} = "Quantity: $quantity\n\n$address";
        $c->set_param('Container_Type', $id);
        $c->set_param('Quantity', $quantity);
        $c->forward('add_report', [ $data ]) or return;
        push @{$c->stash->{report_ids}}, $c->stash->{report}->id;
    }
    return 1;
}

sub construct_bin_report_form {
    my $c = shift;

    my $field_list = [];

    foreach (@{$c->stash->{service_data}}) {
        next unless $_->{last} && $_->{report_allowed} && !$_->{report_open};
        my $id = $_->{service_id};
        my $name = $_->{service_name};
        push @$field_list, "service-$id" => {
            type => 'Checkbox',
            label => $name,
            option_label => $name,
        };
    }

    return $field_list;
}

sub report : Chained('property') : Args(0) {
    my ($self, $c) = @_;

    my $field_list = construct_bin_report_form($c);

    $c->stash->{first_page} = 'report';
    $c->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Report';
    $c->stash->{page_list} = [
        report => {
            fields => [ grep { ! ref $_ } @$field_list, 'submit' ],
            title => 'Select your missed collection',
            next => 'about_you',
        },
    ];
    $c->stash->{field_list} = $field_list;
    $c->forward('form');
}

sub process_report_data : Private {
    my ($self, $c, $form) = @_;
    my $data = $form->saved_data;
    my $address = $c->stash->{property}->{address};
    my @services = grep { /^service-/ && $data->{$_} } keys %$data;
    foreach (@services) {
        my ($id) = /service-(.*)/;
        my $service = $c->stash->{services}{$id}{service_name};
        $data->{title} = "Report missed $service";
        $data->{detail} = "$data->{title}\n\n$address";
        $c->set_param('service_id', $id);
        $c->forward('add_report', [ $data ]) or return;
        push @{$c->stash->{report_ids}}, $c->stash->{report}->id;
    }
    return 1;
}

sub enquiry : Chained('property') : Args(0) {
    my ($self, $c) = @_;

    if (my $template = $c->get_param('template')) {
        $c->stash->{template} = "waste/enquiry-$template.html";
        $c->detach;
    }

    $c->forward('setup_categories_and_bodies');

    my $category = $c->get_param('category');
    my $service = $c->get_param('service_id');
    if (!$category || !$service || !$c->stash->{services}{$service}) {
        $c->res->redirect('/waste/' . $c->stash->{property}{id});
        $c->detach;
    }
    my ($contact) = grep { $_->category eq $category } @{$c->stash->{contacts}};
    if (!$contact) {
        $c->res->redirect('/waste/' . $c->stash->{property}{id});
        $c->detach;
    }

    my $field_list = [];
    foreach (@{$contact->get_metadata_for_input}) {
        next if $_->{code} eq 'service_id' || $_->{code} eq 'uprn' || $_->{code} eq 'property_id';
        my $type = 'Text';
        $type = 'TextArea' if 'text' eq ($_->{datatype} || '');
        my $required = $_->{required} eq 'true' ? 1 : 0;
        push @$field_list, "extra_$_->{code}" => {
            type => $type, label => $_->{description}, required => $required
        };
    }

    $c->stash->{first_page} = 'enquiry';
    $c->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Enquiry';
    $c->stash->{page_list} = [
        enquiry => {
            fields => [ 'category', 'service_id', grep { ! ref $_ } @$field_list, 'continue' ],
            title => $category,
            next => 'about_you',
            update_field_list => sub {
                my $form = shift;
                my $c = $form->c;
                return {
                    category => { default => $c->get_param('category') },
                    service_id => { default => $c->get_param('service_id') },
                }
            }
        },
    ];
    $c->stash->{field_list} = $field_list;
    $c->forward('form');
}

sub process_enquiry_data : Private {
    my ($self, $c, $form) = @_;
    my $data = $form->saved_data;
    my $address = $c->stash->{property}->{address};
    $data->{title} = $data->{category};
    $data->{detail} = "$data->{category}\n\n$address";
    # Read extra details in loop
    foreach (grep { /^extra_/ } keys %$data) {
        my ($id) = /^extra_(.*)/;
        $c->set_param($id, $data->{$_});
    }
    $c->set_param('service_id', $data->{service_id});
    $c->forward('add_report', [ $data ]) or return;
    push @{$c->stash->{report_ids}}, $c->stash->{report}->id;
    return 1;
}

sub garden : Chained('property') : Args(0) {
    my ($self, $c) = @_;

    my $service = $c->cobrand->garden_waste_service_id;
    $c->stash->{garden_form_data} = {
        max_bins => $c->stash->{quantity_max}->{$service}
    };
    $c->stash->{first_page} = 'intro';
    $c->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Garden';
    $c->forward('form');
}

sub garden_modify : Chained('property') : Args(0) {
    my ($self, $c) = @_;

    unless ( $c->user_exists ) {
        $c->detach( '/auth/redirect' );
    }

    $c->forward('get_original_sub');

    my $service = $c->cobrand->garden_waste_service_id;

    my $pick = $c->get_param('task') || '';
    if ($pick eq 'problem') {
        $c->res->redirect('/waste/' . $c->stash->{property}{id} . '/enquiry?template=problem&service_id=' . $service);
        $c->detach;
    }
    if ($pick eq 'cancel') {
        $c->res->redirect('/waste/' . $c->stash->{property}{id} . '/garden_cancel');
        $c->detach;
    }

    my $max_bins = $c->stash->{quantity_max}->{$service};
    $service = $c->stash->{services}{$service};
    if (!$service) {
        $c->res->redirect('/waste/' . $c->stash->{property}{id});
        $c->detach;
    }

    my $payment_method = 'credit_card';
    my $billing_address;
    if ( $c->stash->{orig_sub} ) {
        my $orig_sub = $c->stash->{orig_sub};
        $payment_method = $orig_sub->get_extra_field_value('payment_method') if $orig_sub->get_extra_field_value('payment_method');
        $billing_address = $orig_sub->get_extra_field_value('billing_address');
    }

    $c->stash->{garden_form_data} = {
        max_bins => $max_bins,
        bins => $service->{garden_bins},
        end_date => $service->{end_date},
        payment_method => $payment_method,
        billing_address => $billing_address,
    };

    $c->stash->{first_page} = 'intro';
    $c->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Garden::Modify';
    $c->forward('form');
}

sub garden_cancel : Chained('property') : Args(0) {
    my ($self, $c) = @_;

    unless ( $c->user_exists ) {
        $c->detach( '/auth/redirect' );
    }

    $c->forward('get_original_sub');

    $c->stash->{first_page} = 'intro';
    $c->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Garden::Cancel';
    $c->forward('form');
}

sub garden_renew : Chained('property') : Args(0) {
    my ($self, $c) = @_;

    unless ( $c->user_exists ) {
        $c->detach( '/auth/redirect' );
    }

    $c->forward('get_original_sub');

    # direct debit renewal is automatic so you should not
    # be doing this
    my $payment_method = $c->forward('get_current_payment_method');
    if ( $payment_method eq 'direct_debit' ) {
        $c->stash->{template} = 'waste/garden/dd_renewal_error.html';
        $c->detach;
    }

    my $service = $c->cobrand->garden_waste_service_id;
    my $max_bins = $c->stash->{quantity_max}->{$service};
    $service = $c->stash->{services}{$service};
    $c->stash->{garden_form_data} = {
        max_bins => $max_bins,
        bins => $service->{garden_bins},
    };


    $c->stash->{first_page} = 'intro';
    $c->stash->{form_class} = 'FixMyStreet::App::Form::Waste::Garden::Renew';
    $c->forward('form');
}

sub process_garden_cancellation : Private {
    my ($self, $c, $form) = @_;

    my $data = $form->saved_data;

    $data->{name} = $c->user->name;
    $data->{email} = $c->user->email;
    $data->{phone} = $c->user->phone;
    $data->{category} = 'Cancel Garden Subscription';

    my $bin_count = $c->cobrand->get_current_garden_bins;

    $data->{new_bins} = $bin_count * -1;
    $c->forward('setup_garden_sub_params', [ $data ]);

    $c->forward('add_report', [ $data, 1 ]) or return;

    my $payment_method = $c->forward('get_current_payment_method');

    if ( FixMyStreet->staging_flag('skip_waste_payment') ) {
        $c->stash->{report}->confirm;
        $c->stash->{report}->update;
    } else {
        if ( $payment_method eq 'direct_debit' ) {
            $c->forward('direct_debit_cancel_sub');
        } else {
            $c->stash->{report}->confirm;
            $c->stash->{report}->update;
        }
    }
    return 1;
}

# XXX the payment method will be stored in Echo so we should check there instead once
# this is in place
sub get_current_payment_method : Private {
    my ($self, $c) = @_;

    if ( !$c->stash->{orig_sub} ) {
        $c->forward('get_original_sub');
    }

    my $payment_method;

    if ($c->stash->{orig_sub}) {
        $payment_method = $c->stash->{orig_sub}->get_extra_field_value('payment_method');
    }

    return $payment_method || 'credit_card';

}

sub get_original_sub : Private {
    my ($self, $c) = @_;

    my $p = $c->model('DB::Problem')->search({
        user_id => $c->user->id,
        category => 'New Garden Subscription',
        extra => { like => '%property_id,T5:value,I_:'. $c->stash->{property}{id} . '%' }
    },
    {
        order_by => { -desc => 'id' }
    });

    if ( $p->count == 1) {
        $c->stash->{orig_sub} = $p->first;
    } else {
        $c->stash->{orig_sub} = $p->first; # XXX
    }

    return 1;
}

sub setup_garden_sub_params : Private {
    my ($self, $c, $data) = @_;

    my $address = $c->stash->{property}->{address};

    my %container_types = map { $c->{stash}->{containers}->{$_} => $_ } keys %{ $c->stash->{containers} };

    $data->{title} = $data->{category};
    $data->{detail} = "$data->{category}\n\n$address";

    $c->set_param('service_id', $c->cobrand->garden_waste_service_id);
    $c->set_param('Subscription_Details_Container_Type', $container_types{'Garden Waste'});
    $c->set_param('Subscription_Details_Quantity', $data->{bin_count});
    if ( $data->{new_bins} ) {
        if ( $data->{new_bins} > 0 ) {
            $c->set_param('Container_Request_Details_Action', $c->stash->{container_actions}->{deliver} );
        } elsif ( $data->{new_bins} < 0 ) {
            $c->set_param('Container_Request_Details_Action',  $c->stash->{container_actions}->{remove} );
        }
        $c->set_param('Container_Request_Details_Container_Type', $container_types{'Garden Waste'});
        $c->set_param('Container_Request_Details_Quantity', abs($data->{new_bins}));
    }
    $c->set_param('current_containers', $data->{current_bins});
    $c->set_param('new_containers', $data->{new_bins});
    $c->set_param('payment_method', $data->{payment_method});
}

sub process_garden_modification : Private {
    my ($self, $c, $form) = @_;
    my $data = $form->saved_data;

    $data->{category} = 'Amend Garden Subscription'; # XXX
    $c->set_param('Subscription_Type', $c->stash->{garden_subs}->{Amend});

    my $new_bins = $data->{bin_number} - $c->stash->{garden_form_data}->{bins};

    $data->{new_bins} = $new_bins;
    $data->{bin_count} = $data->{bin_number};

    my $pro_rata;
    if ( $new_bins > 0 ) {
        $pro_rata = $c->cobrand->waste_get_pro_rata_cost( $new_bins, $c->stash->{garden_form_data}->{end_date});
        $c->set_param('pro_rata', $pro_rata);
    }
    my $payment = $c->cobrand->garden_waste_cost($data->{bin_number});
    $c->set_param('payment', $payment);

    $c->forward('setup_garden_sub_params', [ $data ]);
    $c->forward('add_report', [ $data, 1 ]) or return;

    my $payment_method = $c->stash->{garden_form_data}->{payment_method};

    if ( FixMyStreet->staging_flag('skip_waste_payment') ) {
        $c->stash->{message} = 'Payment skipped on staging';
        $c->stash->{reference} = $c->stash->{report}->id;
        $c->forward('confirm_subscription', [ $c->stash->{reference} ] );
    } else {
        if ( $payment_method eq 'direct_debit' ) {
            $c->forward('direct_debit_modify');
        } elsif ( $pro_rata ) {
            $c->forward('pay');
        } else {
            $c->forward('confirm_subscription', [ undef ]);
        }
    }
    return 1;
}

sub process_garden_renew : Private {
    my ($self, $c, $form) = @_;

    my $data = $form->saved_data;
    my $service = $c->stash->{services}{$c->cobrand->garden_waste_service_id};

    my $total_bins = $data->{current_bins} + $data->{new_bins};
    my $payment = $c->cobrand->garden_waste_cost($total_bins);
    $data->{bin_count} = $total_bins;


    if ( !$service || $c->cobrand->waste_sub_overdue( $service->{end_date} ) ) {
        $data->{category} = 'New Garden Subscription';
        $c->set_param('Subscription_Type', $c->stash->{garden_subs}->{New});
    } else {
        $data->{category} = 'Renew Garden Subscription';
        $c->set_param('Subscription_Type', $c->stash->{garden_subs}->{Renew});

        # only override the new bin count if we know the current bin number
        my $current_bins = $c->cobrand->get_current_garden_bins;
        $data->{new_bins} = $total_bins - $current_bins;
    }


    $c->set_param('payment', $payment);

    $c->forward('setup_garden_sub_params', [ $data ]);
    $c->forward('add_report', [ $data, 1 ]) or return;

    # it should not be possible to get to here if it's direct debit but
    # grab this so we can check and redirect to an information page if
    # they manage to get here
    my $payment_method = $c->forward('get_current_payment_method');

    if ( FixMyStreet->staging_flag('skip_waste_payment') ) {
        $c->stash->{message} = 'Payment skipped on staging';
        $c->stash->{reference} = $c->stash->{report}->id;
        $c->forward('confirm_subscription', [ $c->stash->{reference} ] );
    } else {
        if ( $payment_method eq 'direct_debit' ) {
            $c->forward('direct_debit_renew');
        } else {
            $c->forward('pay');
        }
    }

    return 1;
}

sub process_garden_data : Private {
    my ($self, $c, $form) = @_;
    my $data = $form->saved_data;

    $c->set_param('Subscription_Type', $c->stash->{garden_subs}->{New});

    my $bin_count = $data->{new_bins} + $data->{current_bins};
    $data->{bin_count} = $bin_count;

    my $total = $c->cobrand->garden_waste_cost($bin_count);
    $c->set_param('payment', $total);

    $c->forward('setup_garden_sub_params', [ $data ]);
    $c->forward('add_report', [ $data, 1 ]) or return;

    if ( FixMyStreet->staging_flag('skip_waste_payment') ) {
        $c->stash->{message} = 'Payment skipped on staging';
        $c->stash->{reference} = $c->stash->{report}->id;
        $c->forward('confirm_subscription', [ $c->stash->{reference} ] );
    } else {
        if ( $data->{payment_method} eq 'direct_debit' ) {
            $c->forward('direct_debit');
        } else {
            $c->forward('pay');
        }
    }
    return 1;
}

sub load_form {
    my ($c, $previous_form) = @_;

    my $page;
    if ($previous_form) {
        $page = $previous_form->next;
    } else {
        $page = $c->forward('get_page');
    }

    my $form = $c->stash->{form_class}->new(
        page_list => $c->stash->{page_list} || [],
        $c->stash->{field_list} ? (field_list => $c->stash->{field_list}) : (),
        page_name => $page,
        csrf_token => $c->stash->{csrf_token},
        c => $c,
        previous_form => $previous_form,
        saved_data_encoded => $c->get_param('saved_data'),
        no_preload => 1,
    );

    if (!$form->has_current_page) {
        $c->detach('/page_error_400_bad_request', [ 'Bad request' ]);
    }

    return $form;
}

sub form : Private {
    my ($self, $c) = @_;

    my $form = load_form($c);
    if ($c->get_param('process')) {
        $c->forward('/auth/check_csrf_token');
        $form->process(params => $c->req->body_params);
        if ($form->validated) {
            $form = load_form($c, $form);
        }
    }

    $form->process unless $form->processed;

    $c->stash->{template} = $form->template || 'waste/index.html';
    $c->stash->{form} = $form;
    $c->stash->{label_for_field} = \&label_for_field;
}

sub get_page : Private {
    my ($self, $c) = @_;

    my $goto = $c->get_param('goto') || '';
    my $process = $c->get_param('process') || '';
    $goto = $c->stash->{first_page} unless $goto || $process;
    if ($goto && $process) {
        $c->detach('/page_error_400_bad_request', [ 'Bad request' ]);
    }

    return $goto || $process;
}

sub add_report : Private {
    my ( $self, $c, $data, $no_confirm ) = @_;

    $c->stash->{cobrand_data} = 'waste';

    # XXX Is this best way to do this?
    if ($c->user_exists && $c->user->from_body && $c->user->email ne $data->{email}) {
        $c->set_param('form_as', 'another_user');
        $c->set_param('username', $data->{email} || $data->{phone});
    } else {
        $c->set_param('username_register', $data->{email} || $data->{phone});
    }

    # Set the data as if a new report form has been submitted

    $c->set_param('submit_problem', 1);
    $c->set_param('pc', '');
    $c->set_param('non_public', 1);

    $c->set_param('name', $data->{name});
    $c->set_param('phone', $data->{phone});

    $c->set_param('category', $data->{category});
    $c->set_param('title', $data->{title});
    $c->set_param('detail', $data->{detail});
    $c->set_param('uprn', $c->stash->{property}{uprn});
    $c->set_param('property_id', $c->stash->{property}{id});

    $c->forward('setup_categories_and_bodies') unless $c->stash->{contacts};
    $c->forward('/report/new/non_map_creation', [['/waste/remove_name_errors']]) or return;
    my $report = $c->stash->{report};
    # have to explicitly do this as otherwise will be auto confirmed
    # if a user a logged in and sometimes we only want to confirm on payment
    if ( $no_confirm ) {
        $report->state('unconfirmed');
        $report->confirmed(undef);
    } else {
        $report->confirm;
    }
    $report->update;

    $c->model('DB::Alert')->find_or_create({
        user => $report->user,
        alert_type => 'new_updates',
        parameter => $report->id,
        cobrand => $report->cobrand,
        lang => $report->lang,
    })->confirm;

    $c->cobrand->call_hook( 'clear_cached_lookups' => $c->stash->{property}{id} );

    return 1;
}

sub remove_name_errors : Private {
    my ($self, $c) = @_;
    # We do not mind about missing title/split name here
    my $field_errors = $c->stash->{field_errors};
    delete $field_errors->{fms_extra_title};
    delete $field_errors->{first_name};
    delete $field_errors->{last_name};
}

sub setup_categories_and_bodies : Private {
    my ($self, $c) = @_;

    $c->stash->{all_areas} = $c->stash->{all_areas_mapit} = { $c->cobrand->council_area_id => { id => $c->cobrand->council_area_id } };
    $c->forward('/report/new/setup_categories_and_bodies');
    my $contacts = $c->stash->{contacts};
    @$contacts = grep { grep { $_ eq 'Waste' } @{$_->groups} } @$contacts;
}

sub receive_echo_event_notification : Path('/waste/echo') : Args(0) {
    my ($self, $c) = @_;
    $c->stash->{format} = 'xml';
    $c->response->header(Content_Type => 'application/soap+xml');

    require SOAP::Lite;

    $c->detach('soap_error', [ 'Invalid method', 405 ]) unless $c->req->method eq 'POST';

    my $echo = $c->cobrand->feature('echo');
    $c->detach('soap_error', [ 'Missing config', 500 ]) unless $echo;

    # Make sure we log entire request for debugging
    $c->detach('soap_error', [ 'Missing body' ]) unless $c->req->body;
    my $soap = join('', $c->req->body->getlines);
    $c->log->debug($soap);

    my $body = $c->cobrand->body;
    $c->detach('soap_error', [ 'Bad jurisdiction' ]) unless $body;

    my $env = SOAP::Deserializer->deserialize($soap);

    my $header = $env->header;
    $c->detach('soap_error', [ 'Missing SOAP header' ]) unless $header;
    my $action = $header->{Action};
    $c->detach('soap_error', [ 'Incorrect Action' ]) unless $action && $action eq $echo->{receive_action};
    $header = $header->{Security};
    $c->detach('soap_error', [ 'Missing Security header' ]) unless $header;
    my $token = $header->{UsernameToken};
    $c->detach('soap_error', [ 'Authentication failed' ])
        unless $token && $token->{Username} eq $echo->{receive_username} && $token->{Password} eq $echo->{receive_password};

    my $event = $env->result;

    my $cfg = { echo => Integrations::Echo->new(%$echo) };
    my $request = $c->cobrand->construct_waste_open311_update($cfg, $event);
    $request->{updated_datetime} = DateTime::Format::W3CDTF->format_datetime(DateTime->now);
    $request->{service_request_id} = $event->{Guid};

    my $updates = Open311::GetServiceRequestUpdates->new(
        system_user => $body->comment_user,
        current_body => $body,
    );

    my $p = $updates->find_problem($request);
    if ($p) {
        $c->forward('check_existing_update', [ $p, $request, $updates ]);
        my $comment = $updates->process_update($request, $p);
    }
    # Still want to say it is okay, even if we did nothing with it
    $c->forward('soap_ok');
}

sub soap_error : Private {
    my ($self, $c, $comment, $code) = @_;
    $code ||= 400;
    $c->response->status($code);
    my $type = $code == 500 ? 'Server' : 'Client';
    $c->response->body(SOAP::Serializer->fault($type, "Bad request: $comment", soap_header()));
}

sub soap_ok : Private {
    my ($self, $c) = @_;
    $c->response->status(200);
    my $method = SOAP::Data->name("NotifyEventUpdatedResponse")->attr({
        xmlns => "http://www.twistedfish.com/xmlns/echo/api/v1"
    });
    $c->response->body(SOAP::Serializer->envelope(method => $method, soap_header()));
}

sub soap_header {
    my $attr = "http://www.twistedfish.com/xmlns/echo/api/v1";
    my $action = "NotifyEventUpdatedResponse";
    my $header = SOAP::Header->name("Action")->attr({
        xmlns => 'http://www.w3.org/2005/08/addressing',
        'soap:mustUnderstand' => 1,
    })->value("$attr/ReceiverService/$action");

    my $dt = DateTime->now();
    my $dt2 = $dt->clone->add(minutes => 5);
    my $w3c = DateTime::Format::W3CDTF->new;
    my $header2 = SOAP::Header->name("Security")->attr({
        'soap:mustUnderstand' => 'true',
        'xmlns' => 'http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd'
    })->value(
        \SOAP::Header->name(
            "Timestamp" => \SOAP::Header->value(
                SOAP::Header->name('Created', $w3c->format_datetime($dt)),
                SOAP::Header->name('Expires', $w3c->format_datetime($dt2)),
            )
        )->attr({
            xmlns => "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd",
        })
    );
    return ($header, $header2);
}

sub check_existing_update : Private {
    my ($self, $c, $p, $request, $updates) = @_;

    my $cfg = { updates => $updates };
    $c->detach('soap_ok')
        unless $c->cobrand->waste_check_last_update(
            $cfg, $p, $request->{status}, $request->{external_status_code});
}

sub label_for_field {
    my ($form, $field, $key) = @_;
    foreach ($form->field($field)->options) {
        return $_->{label} if $_->{value} eq $key;
    }
}

__PACKAGE__->meta->make_immutable;

1;
