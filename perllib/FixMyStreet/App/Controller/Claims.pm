package FixMyStreet::App::Controller::Claims;
use Moose;
use namespace::autoclean;

BEGIN { extends 'Catalyst::Controller' }

use utf8;
use FixMyStreet::App::Form::Claims;

sub auto : Private {
    my ( $self, $c ) = @_;
    my $cobrand_check = $c->cobrand->feature('claims');
    $c->detach( '/page_error_404_not_found' ) if !$cobrand_check;
    return 1;
}

sub index : Path : Args(0) {
    my ( $self, $c ) = @_;

    $c->forward('/auth/get_csrf_token');
    $c->forward('form');
}

sub load_form {
    my ($c, $previous_form) = @_;

    my $page;
    if ($previous_form) {
        $page = $previous_form->next;
    } else {
        $page = $c->forward('get_page');
    }

    my $form = FixMyStreet::App::Form::Claims->new(
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

    # Special button on map page to go back to address unknown (hard as form wraps whole page)
    if ($c->get_param('goto-address_unknown')) {
        $c->set_param('goto', 'address_unknown');
        $c->set_param('process', '');
    }

    my $form = load_form($c);
    if ($c->get_param('process') && !$c->stash->{override_no_process}) {
        $c->forward('/auth/check_csrf_token');
        $form->process(params => $c->req->body_params);
        if ($form->validated) {
            $form = load_form($c, $form);
        }
    }

    $form->process unless $form->processed;

    $c->stash->{template} = $form->template || 'claims/index.html';
    $c->stash->{form} = $form;
}

sub get_page : Private {
    my ($self, $c) = @_;

    my $goto = $c->get_param('goto') || '';
    my $process = $c->get_param('process') || '';
    $goto = 'intro' unless $goto || $process;
    if ($goto && $process) {
        $c->detach('/page_error_400_bad_request', [ 'Bad request' ]);
    }

    return $goto || $process;
}



sub process_claim : Private {
    my ($self, $c, $form) = @_;

    my $data = $form->saved_data;
}


__PACKAGE__->meta->make_immutable;

1;
