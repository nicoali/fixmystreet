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

sub council_area_id { 2566 }
sub council_area { 'Peterborough' }
sub council_name { 'Peterborough City Council' }
sub council_url { 'peterborough' }
sub map_type { 'MasterMap' }
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

    return if $self->{c}->action =~ /^waste/;

    @$categories = grep { !$_->get_extra_metadata('waste_only') } @$categories;
    $self->SUPER::munge_report_new_contacts($categories);
}


sub bin_addresses_for_postcode {
    my $self = shift;
    my $pc = shift;

    my $bartec = $self->feature('bartec');
    $bartec = Integrations::Bartec->new(%$bartec);
    my $premises = $bartec->Premises_Get($pc);
    my $data = [ map { {
        value => $pc . ":" . $_->{UPRN},
        label => $self->_format_address($_),
    } } @$premises ];
    natkeysort_inplace { $_->{label} } @$data;
    return $data;
}

sub _format_address {
    my ($self, $property) = @_;

    my $a = $property->{Address};
    my $prefix = join(" ", $a->{Address1}, $a->{Address2}, $a->{Street});
    return Utils::trim_text(FixMyStreet::Template::title(join(", ", $prefix, $a->{Town}, $a->{PostCode})));
}

1;
