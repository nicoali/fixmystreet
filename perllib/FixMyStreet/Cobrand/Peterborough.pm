package FixMyStreet::Cobrand::Peterborough;
use parent 'FixMyStreet::Cobrand::Whitelabel';

use strict;
use warnings;
use Integrations::Bartec;
use Sort::Key::Natural qw(natkeysort_inplace);
use Utils;

use Moo;
with 'FixMyStreet::Roles::ConfirmOpen311';
with 'FixMyStreet::Roles::ConfirmValidation';
with 'FixMyStreet::Roles::Waste';

sub council_area_id { 2566 }
sub council_area { 'Peterborough' }
sub council_name { 'Peterborough City Council' }
sub council_url { 'peterborough' }
sub default_map_zoom { 5 }

sub send_questionnaires { 0 }

sub max_title_length { 50 }

sub disambiguate_location {
    my $self    = shift;
    my $string  = shift;

    return {
        %{ $self->SUPER::disambiguate_location() },
        centre => '52.6085234396978,-0.253091266573947',
        bounds => [ 52.5060949603654, -0.497663559599628, 52.6752139533306, -0.0127696975457487 ],
    };
}

sub get_geocoder { 'OSM' }

sub contact_extra_fields { [ 'display_name' ] }

sub geocoder_munge_results {
    my ($self, $result) = @_;
    $result->{display_name} = '' unless $result->{display_name} =~ /City of Peterborough/;
    $result->{display_name} =~ s/, UK$//;
    $result->{display_name} =~ s/, City of Peterborough, East of England, England//;
}

sub admin_user_domain { "peterborough.gov.uk" }

around open311_extra_data_include => sub {
    my ($orig, $self, $row, $h) = @_;

    my $open311_only = $self->$orig($row, $h);
    foreach (@$open311_only) {
        if ($_->{name} eq 'description') {
            my ($ref) = grep { $_->{name} =~ /pcc-Skanska-csc-ref/i } @{$row->get_extra_fields};
            $_->{value} .= "\n\nSkanska CSC ref: $ref->{value}" if $ref;
        }
    }
    if ( $row->geocode && $row->contact->email =~ /Bartec/ ) {
        my $address = $row->geocode->{resourceSets}->[0]->{resources}->[0]->{address};
        my ($number, $street) = $address->{addressLine} =~ /\s*(\d*)\s*(.*)/;
        push @$open311_only, (
            { name => 'postcode', value => $address->{postalCode} },
            { name => 'house_no', value => $number },
            { name => 'street', value => $street }
        );
    }
    return $open311_only;
};
# remove categories which are informational only
sub open311_extra_data_exclude { [ '^PCC-', '^emergency$', '^private_land$' ] }

sub lookup_site_code_config { {
    buffer => 50, # metres
    url => "https://tilma.mysociety.org/mapserver/peterborough",
    srsname => "urn:ogc:def:crs:EPSG::27700",
    typename => "highways",
    property => "Usrn",
    accept_feature => sub { 1 },
    accept_types => { Polygon => 1 },
} }

sub open311_munge_update_params {
    my ($self, $params, $comment, $body) = @_;

    # Peterborough want to make it clear in Confirm when an update has come
    # from FMS.
    $params->{description} = "[Customer FMS update] " . $params->{description};

    # Send the FMS problem ID with the update.
    $params->{service_request_id_ext} = $comment->problem->id;

    my $contact = $comment->problem->contact;
    $params->{service_code} = $contact->email;
}

around 'open311_config' => sub {
    my ($orig, $self, $row, $h, $params) = @_;

    $params->{upload_files} = 1;
    $self->$orig($row, $h, $params);
};

sub dashboard_export_problems_add_columns {
    my ($self, $csv) = @_;

    $csv->add_csv_columns(
        usrn => 'USRN',
        nearest_address => 'Nearest address',
    );

    $csv->csv_extra_data(sub {
        my $report = shift;

        my $address = '';
        $address = $report->geocode->{resourceSets}->[0]->{resources}->[0]->{name}
            if $report->geocode;

        return {
            usrn => $report->get_extra_field_value('site_code'),
            nearest_address => $address,
        };
    });
}

# We can resend reports upon category change
sub category_change_force_resend {
    my ($self, $old, $new) = @_;

    # Get the Open311 identifiers
    my $contacts = $self->{c}->stash->{contacts};
    ($old) = map { $_->email } grep { $_->category eq $old } @$contacts;
    ($new) = map { $_->email } grep { $_->category eq $new } @$contacts;

    return 0 if $old =~ /^Bartec/ && $new =~ /^Bartec/;
    return 0 if $old =~ /^Ezytreev/ && $new =~ /^Ezytreev/;
    return 0 if $old !~ /^(Bartec|Ezytreev)/ && $new !~ /^(Bartec|Ezytreev)/;
    return 1;
}

=head2 Waste product code

Functions specific to the waste product & Bartec integration.

=cut 

=head2 munge_around_category_where, munge_reports_category_list, munge_report_new_contacts

These filter out waste-related categories from the main FMS report flow.
TODO: Are these small enough to be here or should they be in a Role?

=cut 

sub munge_around_category_where {
    my ($self, $where) = @_;
    $where->{extra} = [ undef, { -not_like => '%T10:waste_only,I1:1%' } ];
}

sub munge_reports_category_list {
    my ($self, $categories) = @_;
    @$categories = grep { !$_->get_extra_metadata('waste_only') } @$categories;
}

sub munge_report_new_contacts {
    my ($self, $categories) = @_;

    if ($self->{c}->action =~ /^waste/) {
        @$categories = grep { $_->get_extra_metadata('waste_only') } @$categories;
        return;
    }

    @$categories = grep { !$_->get_extra_metadata('waste_only') } @$categories;
    $self->SUPER::munge_report_new_contacts($categories);
}

sub _premises_for_postcode {
    my $self = shift;
    my $pc = shift;

    my $key = "peterborough:bartec:premises_for_postcode:$pc";

    unless ( $self->{c}->session->{$key} ) {
        my $bartec = $self->feature('bartec');
        $bartec = Integrations::Bartec->new(%$bartec);
        my $response = $bartec->Premises_Get($pc);

        $self->{c}->session->{$key} = [ map { {
            id => $pc . ":" . $_->{UPRN},
            uprn => $_->{UPRN},
            address => $self->_format_address($_),
            latitude => $_->{Location}->{Metric}->{Latitude},
            longitude => $_->{Location}->{Metric}->{Longitude},
        } } @$response ];
    }

    return $self->{c}->session->{$key};
}

sub _clear_cached_postcode_lookup {
    my $self = shift;

    my ($pc, $uprn) = split ":", $self->{c}->stash->{property}->{id};
    my $key = "peterborough:bartec:premises_for_postcode:$pc";

    delete $self->{c}->session->{$key};
}


sub bin_addresses_for_postcode {
    my $self = shift;
    my $pc = shift;

    my $premises = $self->_premises_for_postcode($pc);
    my $data = [ map { {
        value => $pc . ":" . $_->{uprn},
        label => $_->{address},
    } } @$premises ];
    natkeysort_inplace { $_->{label} } @$data;
    return $data;
}

sub look_up_property {
    my $self = shift;
    my $id = shift;

    my ($pc, $uprn) = split ":", $id;

    my $premises = $self->_premises_for_postcode($pc);

    my %premises = map { $_->{uprn} => $_ } @$premises;

    return $premises{$uprn};
}

sub image_for_service {
    my ($self, $service_id) = @_;
    my $base = '/cobrands/peterborough/images';
    my $images = {
        6533 => "$base/black-bin",
        6534 => "$base/green-bin",
        6579 => "$base/brown-bin",
    };
    return $images->{$service_id};
}


sub bin_services_for_address {
    my $self = shift;
    my $property = shift;

    my %service_name_override = (
        "Empty Bin 240L Black" => "Black Bin",
        "Empty Bin 240L Brown" => "Brown Bin",
        "Empty Bin 240L Green" => "Green Bin",
        "Empty Bin Recycling 1100l" => "Recycling",
        "Empty Bin Recycling 240l" => "Recycling",
        "Empty Bin Recycling 660l" => "Recycling",
        "Empty Bin Refuse 1100l" => "Refuse",
        "Empty Bin Refuse 240l" => "Refuse",
        "Empty Bin Refuse 660l" => "Refuse",
    );

    $self->{c}->stash->{containers} = {
        419 => "240L Black",
        420 => "240L Green",
        425 => "All bins",
        493 => "Both food bins",
        424 => "Large food caddy",
        423 => "Small food caddy",
        428 => "Food bags",
    };

    my %container_request_ids = (
        6533 => [ 419 ], # 240L Black
        6534 => [ 420 ], # 240L Green
        6579 => undef, # 240L Brown
        6836 => undef, # Refuse 1100l
        6837 => undef, # Refuse 660l
        6839 => undef, # Refuse 240l
        6840 => undef, # Recycling 1100l
        6841 => undef, # Recycling 660l
        6843 => undef, # Recycling 240l
        # all bins?
        # large food caddy?
        # small food caddy?
    );

    my %container_removal_ids = (
        6533 => [ 487 ], # 240L Black
        6534 => [ 488 ], # 240L Green
        6579 => [ 489 ], # 240L Brown
        6836 => undef, # Refuse 1100l
        6837 => undef, # Refuse 660l
        6839 => undef, # Refuse 240l
        6840 => undef, # Recycling 1100l
        6841 => undef, # Recycling 660l
        6843 => undef, # Recycling 240l
        # black 360L?
    );

    my %container_request_max = (
        6533 => 1, # 240L Black
        6534 => 2, # 240L Green (max 2 per household, need to check how many property already has dynamically)
        6579 => 1, # 240L Brown
        6836 => undef, # Refuse 1100l
        6837 => undef, # Refuse 660l
        6839 => undef, # Refuse 240l
        6840 => undef, # Recycling 1100l
        6841 => undef, # Recycling 660l
        6843 => undef, # Recycling 240l
        # all bins?
        # large food caddy?
        # small food caddy?
    );

    my $bartec = $self->feature('bartec');
    $bartec = Integrations::Bartec->new(%$bartec);

    # TODO parallelize these calls
    my $jobs = $bartec->Jobs_FeatureScheduleDates_Get($property->{uprn});
    my $schedules = $bartec->Features_Schedules_Get($property->{uprn});
    my %schedules = map { $_->{JobName} => $_ } @$schedules;

    my @out;

    foreach (@$jobs) {
        my $last = construct_bin_date($_->{PreviousDate});
        my $next = construct_bin_date($_->{NextDate});
        my $container_id = $schedules{$_->{JobName}}->{Feature}->{FeatureType}->{ID};

        my $row = {
            id => $_->{JobID},
            last => { date => $last, ordinal => ordinal($last->day) },
            next => { date => $next, ordinal => ordinal($next->day) },
            service_name => $service_name_override{$_->{JobDescription}} || $_->{JobDescription},
            schedule => $schedules{$_->{JobName}}->{Frequency},
            service_id => $container_id,
            request_containers => $container_request_ids{$container_id},

            # can this container type be requested?
            request_allowed => $container_request_ids{$container_id} ? 1 : 0,
            # what's the maximum number of this container that can be request?
            request_max => $container_request_max{$container_id} || 0,
            # can this collection be reported as having been missed?
            report_allowed => 1,
            # is there already a missed collection report open for this container?
            report_open => 0,
        };
        push @out, $row;
    }

    # Some need to be added manually as they don't appear in Bartec responses
    # as they're not "real" collection types (e.g. requesting all bins)
    push @out, {
        id => "_FOOD_BINS",
        service_name => "Food bins",
        service_id => "_FOOD_BINS",
        request_containers => [ 493, 424, 423, 428 ],
        request_allowed => 1,
        request_max => 1,
        request_only => 1,
        report_only => 1,
    };
    push @out, {
        id => "_ALL_BINS",
        service_name => "All bins",
        service_id => "_ALL_BINS",
        request_containers => [ 425 ],
        request_allowed => 1,
        request_max => 1,
        request_only => 1,
    };

    return \@out;
}

sub bin_future_collections {
    my $self = shift;

    my $bartec = $self->feature('bartec');
    $bartec = Integrations::Bartec->new(%$bartec);

    my $jobs = $bartec->Jobs_FeatureScheduleDates_Get($self->{c}->stash->{property}{uprn});

    my $events = [];
    foreach (@$jobs) {
        my $dt = construct_bin_date($_->{NextDate});
        push @$events, { date => $dt, desc => '', summary => $_->{JobName} };
    }
    return $events;
}

sub bin_request_form_extra_fields {
    my ($self, $service, $container_id, $field_list) = @_;

    if ($container_id =~ /419|425/) { # Request New Black 240L
        # Add a new "reason" field
        push @$field_list, "reason-$container_id" => {
            type => 'Text',
            label => 'Why do you need new bins?',
            tags => {
                initial_hidden => 1,
            },
            required_when => { "container-$container_id" => 1 },
        };
        # And make sure it's revealed when the box is ticked
        my %fields = @$field_list;
        $fields{"container-$container_id"}{tags}{toggle} .= ", #form-reason-$container_id-row";
    }
}

sub waste_munge_request_data {
    my ($self, $id, $data) = @_;

    my $c = $self->{c};

    my $address = $c->stash->{property}->{address};
    my $container = $c->stash->{containers}{$id};
    my $quantity = $data->{"quantity-$id"};
    $data->{title} = "Request new $container";
    $data->{detail} = "Quantity: $quantity\n\n$address";
    if (my $reason = $data->{"reason-$id"}) {
        $data->{detail} .= "\n\nReason: $reason";
    }

    $data->{category} = $self->body->contacts->find({ email => "Bartec-$id" })->category;

    $self->_clear_cached_postcode_lookup;
}

sub waste_munge_report_data {
    my ($self, $id, $data) = @_;


    use Data::Dumper;
    warn "XXX $id";
    warn Dumper($data);

    my %container_service_ids = (
        6533 => 255, # 240L Black
        6534 => 254, # 240L Green
        6579 => 253, # 240L Brown
        6836 => undef, # Refuse 1100l
        6837 => undef, # Refuse 660l
        6839 => undef, # Refuse 240l
        6840 => undef, # Recycling 1100l
        6841 => undef, # Recycling 660l
        6843 => undef, # Recycling 240l
        # black 360L?
    );


    my $c = $self->{c};

    my $address = $c->stash->{property}->{address};
    my $service_id = $container_service_ids{$id};
    my $container = $c->stash->{containers}{$id};
    $data->{title} = "Report missed $container";
    $data->{detail} = "$data->{title}\n\n$address";

    $data->{category} = $self->body->contacts->find({ email => "Bartec-$service_id" })->category;

    $self->_clear_cached_postcode_lookup;
}

sub waste_munge_enquiry_data {
    my ($self, $data) = @_;

    my %container_ids = (
        6533 => "240L Black",
        6534 => "240L Green",
        6579 => "240L Brown",
    );


    my $address = $self->{c}->stash->{property}->{address};
    my $bin = $container_ids{$data->{service_id}};
    $data->{title} = "Repair: $bin $data->{category}";
    $data->{detail} = "$data->{title}\n\n$address";
}



sub _format_address {
    my ($self, $property) = @_;

    my $a = $property->{Address};
    my $prefix = join(" ", $a->{Address1}, $a->{Address2}, $a->{Street});
    return Utils::trim_text(FixMyStreet::Template::title(join(", ", $prefix, $a->{Town}, $a->{PostCode})));
}

sub bin_day_format { '%A, %-d~~~ %B %Y' }

1;
