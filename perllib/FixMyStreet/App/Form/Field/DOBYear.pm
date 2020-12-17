package FixMyStreet::App::Form::Field::DOBYear;
use Moose;
extends 'HTML::FormHandler::Field::IntRange';

has '+range_start' => (
    default => sub {
        return 1900;
    }
);
has '+range_end' => (
    default => sub {
        my $year = (localtime)[5] + 1900;
        return $year;
    }
);


__PACKAGE__->meta->make_immutable;
use namespace::autoclean;
1;
