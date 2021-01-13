package FixMyStreet::App::Form::Claims;

use HTML::FormHandler::Moose;
extends 'FixMyStreet::App::Form::Wizard';

use Path::Tiny;
use File::Copy;
use Digest::SHA qw(sha1_hex);
use File::Basename;

has c => ( is => 'ro' );

has default_page_type => ( is => 'ro', isa => 'Str', default => 'Claims' );

has finished_action => ( is => 'ro' );

before _process_page_array => sub {
    my ($self, $pages) = @_;
    foreach my $page (@$pages) {
        $page->{type} = $self->default_page_type
            unless $page->{type};
    }
};

# Add some functions to the form to pass through to the current page
has '+current_page' => (
    handles => {
        intro_template => 'intro',
        title => 'title',
        template => 'template',
    }
);

has_page intro => (
    fields => ['start'],
    title => 'Claim for Damages',
    intro => 'start.html',
    next => 'what',
);

has_page what => (
    fields => ['what', 'claimed_before', 'continue'],
    title => 'What are you claiming for',
    next => 'about_you',
);

has_field what => (
    required => 1,
    type => 'Select',
    widget => 'RadioGroup',
    label => 'What are you claiming for?',
    options => [
        { value => '0', label => 'Vehicle damage' },
        { value => '1', label => 'Personal injury' },
        { value => '2', label => 'Property' },
    ]
);

has_field claimed_before => (
    type => 'Select',
    widget => 'RadioGroup',
    required => 1,
    label => 'Have you ever filed a Claim for damages with Buckinghamshire Council?',
    options => [
        { label => 'Yes', value => '1' },
        { label => 'No', value => '0' },
    ],
);

has_page about_you => (
    fields => ['name', 'phone', 'email', 'address', 'continue'],
    title => 'About you',
    next => 'fault_fixed',
);

with 'FixMyStreet::App::Form::Claims::AboutYou';

has_field address => (
    required => 1,
    type => 'Text',
    widget => 'Textarea',
    label => 'Address',
);

has_page fault_fixed => (
    fields => ['fault_fixed', 'continue'],
    intro => 'fault_fixed.html',
    title => 'About the fault',
    next => sub {
        $_[0]->{fault_fixed} == 1 ? 'where' :
        'fault_reported'
    }
);

has_field fault_fixed => (
    type => 'Select',
    widget => 'RadioGroup',
    required => 1,
    label => 'Has the fault been fixed?',
    options => [
        { label => 'Yes', value => '1' },
        { label => 'No', value => '2' },
        { label => 'Don\'t know', value => '3' },
    ],
);

has_page fault_reported => (
    fields => [ 'fault_reported', 'continue' ],
    title => 'About the fault',
    intro => 'fault_reported.html',
    next => sub {
        $_[0]->{fault_reported} == 1 ? 'about_fault' :
        'where'
    }
);

has_field fault_reported => (
    type => 'Select',
    widget => 'RadioGroup',
    required => 1,
    label => 'Have you reported the fault to the Council?',
    options => [
        { label => 'Yes', value => '1' },
        { label => 'No', value => '2' },
    ],
);


has_page about_fault => (
    fields => ['report_id', 'continue'],
    intro => 'fault_reported.html',
    title => 'About the fault',
    next => 'where',
);

has_field report_id => (
    required => 1,
    type => 'Text',
    label => 'Fault ID',
);

has_page where => (
    fields => ['location', 'continue'],
    title => 'Where did the incident happen',
    next => 'when',
    next => sub { $_[0]->{possible_location_matches} ? 'choose_location' : $_[0]->{latitude} ? 'map' : 'choose_location' },
);

#has_field XXXX_location => (
    #required => 1,
    #type => 'Text',
    #widget => 'Textarea',
    #label => 'Place a pin on the map (TBD)',
#);

has_field location => (
    required => 1,
    type => 'Text',
    label => 'Postcode, or street name and area of the source',
    tag => { hint => 'If you know the postcode please use that' },
    validate_method => sub {
        my $self = shift;
        my $c = $self->form->c;
        return if $self->has_errors; # Called even if already failed
        my $value = $self->value;
        my $saved_data  = $self->form->saved_data;
        my $ret = $c->forward('/location/determine_location_from_pc', [ $self->value ]);
        if (!$ret) {
            if ( $c->stash->{possible_location_matches} ) {
                return $saved_data->{possible_location_matches} = $c->stash->{possible_location_matches};
            } else {
                $self->add_error($c->stash->{location_error});
            }
        }
        $saved_data->{latitude} = $c->stash->{latitude};
        $saved_data->{longitude} = $c->stash->{longitude};
    },
);

has_page 'choose_location' => (
    fields => ['location_matches', 'continue'],
    title => 'The location of the incident',
    next => 'map',
    update_field_list => sub {
        my $form = shift;
        my $saved_data = $form->saved_data;
        my $locations = $saved_data->{possible_location_matches};
        my $options = [];
        for my $location ( @$locations ) {
            push @$options, { label => $location->{address}, value => $location->{latitude} . "," . $location->{longitude} }
        }
        return { location_matches => { options => $options } };
    },
    post_process => sub {
        my $form = shift;
        my $saved_data = $form->saved_data;
        if ( my $location = $saved_data->{location_matches} ) {
            my ($lat, $lon) = split ',', $location;
            $saved_data->{latitude} ||= $lat;
            $saved_data->{longitude} ||= $lon;
        }
    },
);

has_field 'location_matches' => (
    required => 1,
    type => 'Select',
    widget => 'RadioGroup',
    label => 'Select a location',
    validate_method => sub {
        my $self = shift;
        my $value = $self->value;
        my $saved_data  = $self->form->saved_data;

        if ($saved_data->{location_matches} && $value ne $saved_data->{location_matches}) {
            delete $saved_data->{latitude};
            delete $saved_data->{longitude};
        }
    }
);

has_page map => (
    fields => ['latitude', 'longitude', 'continue'],
    title => 'The location of the incident',
    template => 'claims/map.html',
    next => 'when',
    update_field_list => sub {
        my $form = shift;
        my $c = $form->c;
        if ($c->forward('/report/new/determine_location_from_tile_click')) {
            $c->forward('/around/check_location_is_acceptable', []);
            # We do not want to process the form if they have clicked the map
            $c->stash->{override_no_process} = 1;

            my $saved_data = $form->saved_data;
            $saved_data->{latitude} = $c->stash->{latitude};
            $saved_data->{longitude} = $c->stash->{longitude};
            return {};
        }
    },
    post_process => sub {
        my $form = shift;
        my $c = $form->c;
        my $latitude = $form->fif->{latitude};
        my $longitude = $form->fif->{longitude};
        $c->stash->{page} = 'new';
        FixMyStreet::Map::display_map(
            $c,
            latitude => $latitude,
            longitude => $longitude,
            clickable => 1,
            pins => [ {
                latitude => $latitude,
                longitude => $longitude,
                draggable => 1,
                colour => $c->cobrand->pin_new_report_colour,
            } ],
        );
    },
);

has_field latitude => (
    type => 'Hidden'
);

has_field longitude => (
    type => 'Hidden'
);

has_page when => (
    fields => ['incident_date', 'incident_time', 'continue'],
    title => 'When did the incident happen',
    next => sub {
            $_[0]->{what} == 0 ? 'details_vehicle' : 'details_no_vehicle'
        },
);

has_field incident_date => (
    required => 1,
    type => 'DateTime',
    hint => 'For example 27 09 2020',
    label => 'What day did the incident happen?',
);

has_field 'incident_date.year' => ( type => 'Year' );
has_field 'incident_date.month' => ( type => 'Month' );
has_field 'incident_date.day' => ( type => 'MonthDay' );

has_field incident_time => (
    required => 1,
    type => 'Text',
    label => 'What time did the incident happen?',
);

has_page details_vehicle => (
    fields => ['weather', 'direction', 'details', 'in_vehicle', 'speed', 'actions', 'continue'],
    title => 'What are the details of the incident',
    next => 'witnesses',
);

has_page details_no_vehicle => (
    fields => ['weather', 'direction', 'details', 'continue'],
    title => 'What are the details of the incident',
    next => 'witnesses',
);

has_field weather => (
    required => 1,
    type => 'Text',
    label => 'Describe the weather conditions at the time',
);

has_field direction => (
    required_when => { 'what' => sub { $_[1]->form->saved_data->{what} == 0; } },
    type => 'Text',
    label => 'What direction were you travelling in at the time?',
);

has_field details => (
    required => 1,
    type => 'Text',
    widget => 'Textarea',
    label => 'Describe the details of the incident',
);

has_field in_vehicle => (
    type => 'Select',
    widget => 'RadioGroup',
    required_when => { 'what' => sub { $_[1]->form->saved_data->{what} == 0; } },
    label => 'Where you in a vehicle when the incident happened?',
    options => [
        { label => 'Yes', value => '1' },
        { label => 'No', value => '0' },
    ],
);

has_field speed => (
    required_when => { 'what' => sub { $_[1]->form->saved_data->{what} == 0; } },
    type => 'Text',
    label => 'What speed was the vehicle travelling?',
);

has_field actions => (
    required_when => { 'what' => sub { $_[1]->form->saved_data->{what} == 0; } },
    type => 'Text',
    widget => 'Textarea',
    label => 'If you were not driving, what were you doing when the incident happened?',
);

has_page witnesses => (
    fields => ['witnesses', 'witness_details', 'report_police', 'incident_number', 'continue'],
    title => 'Witnesses and police',
    next => 'cause',
);

has_field witnesses => (
    type => 'Select',
    widget => 'RadioGroup',
    required => 1,
    label => 'Were there any witnesses?',
    options => [
        { label => 'Yes', value => '1' },
        { label => 'No', value => '0' },
    ],
);

has_field witness_details => (
    type => 'Text',
    widget => 'Textarea',
    label => 'Please give the witness\' details',
);

has_field report_police => (
    type => 'Select',
    widget => 'RadioGroup',
    required => 1,
    label => 'Did you report the incident to the police?',
    options => [
        { label => 'Yes', value => '1' },
        { label => 'No', value => '0' },
    ],
);

has_field incident_number => (
    type => 'Text',
    label => 'What was the incident reference number?',
);


has_page cause => (
    fields => ['what_cause', 'aware', 'where_cause', 'describe_cause', 'upload_fileid', 'photos', 'continue'],
    title => 'What caused the incident?',
    next => sub {
            $_[0]->{what} == 0 ? 'about_vehicle' :
            $_[0]->{what} == 1 ? 'about_you_personal' :
            'about_property',
        },
    update_field_list => sub {
        my ($form) = @_;
        my $saved_data = $form->saved_data;
        if ($saved_data->{photos}) {
            $saved_data->{upload_fileid} = $saved_data->{photos};
            return { upload_fileid => { default => $saved_data->{photos} } };
        }
        return {};
    },
    post_process => sub {
            my ($form) = @_;
            my $c = $form->{c};
            #$c->forward('/photo/process_photo');

            my $saved_data = $form->saved_data;
            $saved_data->{photos} = $saved_data->{upload_fileid};
            $saved_data->{upload_fileid} = '';
        },
);

has_field upload_fileid => (
    type => 'Hidden'
);

has_field what_cause => (
    type => 'Select',
    widget => 'RadioGroup',
    required => 1,
    label => 'What was the cause of the incident?',
    options => [
        { label => 'Bollard', value => 'bollard' },
        { label => 'Cats Eyes', value => 'catseyes' },
        { label => 'Debris', value => 'debris' },
    ],
);

has_field aware => (
    type => 'Select',
    widget => 'RadioGroup',
    required => 1,
    label => 'Were you aware of it before?',
    options => [
        { label => 'Yes', value => '1' },
        { label => 'No', value => '0' },
    ],
);

has_field where_cause => (
    type => 'Select',
    widget => 'RadioGroup',
    required => 1,
    label => 'Where was the cause of the incident?',
    options => [
        { label => 'Bridge', value => 'bridge' },
        { label => 'Carriageway', value => 'carriageway' },
    ],
);

has_field describe_cause => (
    required => 1,
    type => 'Text',
    widget => 'Textarea',
    label => 'Describe the incident cause',
);

has_field photos => (
    type => 'Photo',
    label => 'Please provide two dated photos of the incident',
);

has_page about_vehicle => (
    fields => ['make', 'registration', 'mileage', 'v5', 'v5_in_name', 'insurer_address', 'damage_claim', 'vat_reg', 'continue'],
    title => 'About the vehicle',
    next => 'damage_vehicle',
);

has_field make => (
    required => 1,
    type => 'Text',
    label => 'Make and model',
);

has_field registration => (
    required => 1,
    type => 'Text',
    label => 'Registration number',
);

has_field mileage => (
    required => 1,
    type => 'Text',
    label => 'Vehicle mileage',
);

has_field v5 => (
    required => 1,
    type => 'Text',
    label => 'Copy of the vehicles V5 Registration Document',
);

has_field v5_in_name => (
    type => 'Select',
    widget => 'RadioGroup',
    required => 1,
    label => 'Is the V5 document in your name?',
    options => [
        { label => 'Yes', value => '1' },
        { label => 'No', value => '0' },
    ],
);

has_field insurer_address => (
    type => 'Text',
    widget => 'Textarea',
    label => 'Name and address of the Vehicle\'s Insurer',
);

has_field damage_claim => (
    type => 'Select',
    widget => 'RadioGroup',
    required => 1,
    label => 'Are you making a claim via the insurance company?',
    options => [
        { label => 'Yes', value => '1' },
        { label => 'No', value => '0' },
    ],
);

has_field vat_reg => (
    type => 'Select',
    widget => 'RadioGroup',
    required => 1,
    label => 'Are you registered for VAT?',
    options => [
        { label => 'Yes', value => '1' },
        { label => 'No', value => '0' },
    ],
);

has_page damage_vehicle => (
    fields => ['vehicle_damage', 'vehicle_upload_fileid', 'vehicle_photos', 'vehicle_receipts', 'tyre_damage', 'tyre_mileage', 'tyre_receipts', 'continue'],
    title => 'What was the damage to the vehicle',
    next => 'summary',
    update_field_list => sub {
        my ($form) = @_;
        my $fields = {};
        my $c = $form->{c};
        my $saved_data = $form->saved_data;
        if ($saved_data->{vehicle_photos}) {
            $saved_data->{vehicle_upload_fileid} = $saved_data->{vehicle_photos};
            $fields = { vehicle_upload_fileid => { default => $saved_data->{vehicle_photos} } };
        }

        $form->handle_upload( 'vehicle_receipts', $fields );
        $form->handle_upload( 'tyre_receipts', $fields );

        return $fields;
    },
    post_process => sub {
        my ($form) = @_;
        my $c = $form->{c};

        my $saved_data = $form->saved_data;
        $saved_data->{vehicle_photos} = $saved_data->{vehicle_upload_fileid};
        $saved_data->{upload_fileid} = '';

        if ( $form->params->{vehicle_receipts_fileid} ) {
            $saved_data->{vehicle_receipts} = $form->params->{vehicle_receipts_fileid};
        }
        if ( $form->params->{tyre_receipts_fileid} ) {
            $saved_data->{tyre_receipts} = $form->params->{tyre_receipts_fileid};
        }

    },
);

has_field vehicle_damage => (
    required => 1,
    type => 'Text',
    widget => 'Textarea',
    label => 'Describe the damage to the vehicle',
);

has_field vehicle_upload_fileid => (
    required => 1,
    type => 'Hidden',
    validate_method => sub {
        my $self = shift;
        my $value = $self->value;
        my @parts = split(/,/, $value);
        return scalar @parts == 2;
    }
);

has_field vehicle_photos => (
    type => 'Photo',
    tags => { upload_field => 'vehicle_upload_fileid' },
    label => 'Please provide two photos of the damage to the vehicle',
);

has_field vehicle_receipts=> (
    type => 'Upload',
    label => 'Please provide receipted invoiced for repairs',
    hint => 'Or estimates where the damage has not yet been repaired',
    validate_method => sub {
        my $self = shift;
        my $c = $self->form->{c};
        return 1 if $c->req->upload('vehicle_receipts');
    }
);

has_field tyre_damage => (
    type => 'Select',
    widget => 'RadioGroup',
    required => 1,
    label => 'Are you claiming for tyre damage?',
    options => [
        { label => 'Yes', value => '1' },
        { label => 'No', value => '0' },
    ],
);

has_field tyre_mileage => (
    type => 'Text',
    label => 'Age and Mileage of the tyre(s) at the time of the incident',
    required_when => { 'tyre_damage' => 1 },
);

has_field tyre_receipts => (
    type => 'Upload',
    label => 'Please provide copy of tyre purchase receipts',
    validate_method => sub {
        my $self = shift;
        my $c = $self->form->{c};
        return 1 if $self->form->saved_data->{tyre_damage} == 1 && $c->req->upload('tyre_receipts');
    }
);

has_page about_property => (
    fields => ['property_insurance', 'continue'],
    title => 'About the property',
    next => 'damage_property',
);

has_field property_insurance => (
    required => 1,
    type => 'Upload',
    label => 'Please provide a copy of the home/contents insurance certificate',
);

has_page damage_property => (
    fields => ['property_damage_description', 'upload_fileid', 'upload_fileid', 'property_photos', 'property_invoices', 'continue'],
    title => 'What was the damage to the property?',
    next => 'summary',
    update_field_list => sub {
        my ($form) = @_;
        my $saved_data = $form->saved_data;
        if ($saved_data->{property_photos}) {
            $saved_data->{upload_fileid} = $saved_data->{property_photos};
            return { upload_fileid => { default => $saved_data->{property_photos} } };
        }
        return {};
    },
    post_process => sub {
            my ($form) = @_;
            my $c = $form->{c};
            #$c->forward('/photo/process_photo');

            my $saved_data = $form->saved_data;
            $saved_data->{property_photos} = $saved_data->{upload_fileid};
            $saved_data->{upload_fileid} = '';
        },
);

has_field property_damage_description => (
    required => 1,
    type => 'Text',
    widget => 'Textarea',
    label => 'Describe the damage to the property',
);

has_field property_photos => (
    required => 1,
    type => 'Text',
    label => 'Please provide two photos of the damage to the property',
);

has_field property_invoices => (
    required => 1,
    type => 'Text',
    hint => 'Or estimates where the damage has not yet been repaired. These must be on headed paper, addressed to you and dated',
    label => 'Please provide receipted invoices for repairs',
);

has_page about_you_personal => (
    fields => ['dob', 'ni_number', 'occupation', 'employer_contact', 'continue'],
    title => 'About you',
    next => 'injuries',
);

has_field dob => (
    required => 1,
    type => 'DateTime',
    hint => 'For example 23 05 1983',
    label => 'Your date of birth',
);

has_field 'dob.year' => ( type => 'DOBYear' );
has_field 'dob.month' => ( type => 'Month' );
has_field 'dob.day' => ( type => 'MonthDay' );

has_field ni_number => (
    required => 1,
    type => 'Text',
    hint => "It's on your National Insurance card, benefit letter, payslip or P60. For example 'QQ 12 34 56 C'.",
    label => 'Your national insurance number',
);

has_field occupation => (
    required => 1,
    type => 'Text',
    label => 'Your occupation',
);

has_field employer_contact => (
    required => 1,
    type => 'Text',
    widget => 'Textarea',
    label => 'Your employer\'s contact details',
);

has_page injuries => (
    fields => ['describe_injuries', 'medical_attention', 'attention_date', 'gp_contact', 'absent_work', 'absence_dates', 'ongoing_treatment', 'treatment_details', 'continue'],
    title => 'About your injuries',
    next => 'summary',
);

has_field describe_injuries => (
    required => 1,
    type => 'Text',
    widget => 'Textarea',
    label => 'Describe the injuries you sustained',
);

has_field medical_attention => (
    type => 'Select',
    widget => 'RadioGroup',
    required => 1,
    label => 'Did you seek medical attention?',
    options => [
        { label => 'Yes', value => '1' },
        { label => 'No', value => '0' },
    ],
);

has_field attention_date => (
    required => 0,
    type => 'DateTime',
    hint => 'For example 11 08 2020',
    label => 'Date you received medical attention',
    required_when => { 'medical_attention' => 1 },
);

has_field 'attention_date.year' => ( type => 'Year' );
has_field 'attention_date.month' => ( type => 'Month' );
has_field 'attention_date.day' => ( type => 'MonthDay' );

has_field gp_contact => (
    required => 0,
    type => 'Text',
    widget => 'Textarea',
    label => 'Please give the name and contact details of the GP or hospital where you recieved medical attention',
    required_when => { 'medical_attention' => 1 },
);

has_field absent_work => (
    type => 'Select',
    widget => 'RadioGroup',
    required => 1,
    label => 'Were you absent from work due to the incident?',
    options => [
        { label => 'Yes', value => '1' },
        { label => 'No', value => '0' },
    ],
);

has_field absence_dates => (
    required => 0,
    type => 'Text',
    widget => 'Textarea',
    label => 'Please give dates of absences',
    required_when => { 'absent_work' => 1 },
);

has_field ongoing_treatment => (
    type => 'Select',
    widget => 'RadioGroup',
    required => 1,
    label => 'Are you having any ongoing treatment?',
    options => [
        { label => 'Yes', value => '1' },
        { label => 'No', value => '0' },
    ],
);

has_field treatment_details => (
    required => 0,
    type => 'Text',
    widget => 'Textarea',
    label => 'Please give treatment details',
    required_when => { 'ongoing_treatment' => 1 },
);


has_page summary => (
    fields => ['submit'],
    title => 'Review',
    template => 'claims/summary.html',
    finished => sub {
        my $form = shift;
        my $c = $form->c;
        my $success = $c->forward('process_claim', [ $form ]);
        if (!$success) {
            $form->add_form_error('Something went wrong, please try again');
            foreach (keys %{$c->stash->{field_errors}}) {
                $form->add_form_error("$_: " . $c->stash->{field_errors}{$_});
            }
        }
        return $success;
    },
    next => 'done',
);

has_page done => (
    title => 'Submit',
    template => 'claims/confirmation.html',
);

has_field start => ( type => 'Submit', value => 'Start', element_attr => { class => 'govuk-button' } );
has_field continue => ( type => 'Submit', value => 'Continue', element_attr => { class => 'govuk-button' } );
has_field submit => ( type => 'Submit', value => 'Submit', element_attr => { class => 'govuk-button' } );

sub handle_upload {
    my ($form, $fieldname, $fields) = @_;

    my $c = $form->{c};
    my $saved_data = $form->saved_data;

    my $cfg = FixMyStreet->config('PHOTO_STORAGE_OPTIONS');
    my $dir = $cfg ? $cfg->{UPLOAD_DIR} : FixMyStreet->config('UPLOAD_DIR');
    $dir = path($dir, "claims_files")->absolute(FixMyStreet->path_to());
    $dir->mkpath;

    my $receipts = $c->req->upload($fieldname);
    if ( $receipts ) {
        FixMyStreet::PhotoStorage::base64_decode_upload($c, $receipts);
        my ($p, $n, $ext) = fileparse($receipts->filename, qr/\.[^.]*/);
        my $key = sha1_hex($receipts->slurp) . $ext;
        my $out = path($dir, $key);
        unless (copy($receipts->tempname, $out)) {
            $c->log->info('Couldn\'t copy temp file to destination: ' . $!);
            $c->stash->{photo_error} = _("Sorry, we couldn't save your file(s), please try again.");
            return;
        }
        # Then store the file hashes in report->extra along with the original filenames
        $form->saved_data->{$fieldname} =  $key;
        $fields->{$fieldname} = { default => $key, tags => { files => $key, filenames => [ $receipts->raw_basename ] } };
        $form->params->{$fieldname . '_fileid'} = '';
    } elsif ( $saved_data->{$fieldname} ) {
        my $file = $saved_data->{$fieldname};
        $fields->{$fieldname} = { default => $file, tags => { files => $file, filenames => [ $file] } };
    }
}

1;
