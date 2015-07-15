package Netdot::Model::Location_Option;

use base 'Netdot::Model';
use warnings;
use strict;

use Netdot::Model::Location_Option_Spec;

=head1 NAME

Netdot::Model::Location_Option - Location options

=cut

__PACKAGE__->add_constraint('Location_Option_Is_Valid', value => \&check_value_validity);

sub check_value_validity
{
    my ($value, $self, $column_name, $changing) = @_;

    my $spec_id;
    if (ref $self) {
	$spec_id = $self->location_option_spec->id;
    }
    if ($changing->{location_option_spec}) {
	if (ref $changing->{location_option_spec}) {
	    $spec_id = $changing->{location_option_spec}->id;
	} else {
	    $spec_id = $changing->{location_option_spec};
	}
    }
    return 0 unless defined $spec_id;
    return 1 unless defined $value;  # null is always fine

    my $spec = Location_Option_Spec->retrieve($spec_id);
    return Netdot::Model::Location_Option::check_value_validity_for_option_spec($value, $spec);
}

sub check_value_validity_for_option_spec
{
    # NOTE!  This function might be called from any XXX_Option module.
    #        It is not specific to Location_Option.
    my ($value, $spec) = @_;

    if ($spec->option_type eq "text") {
	return 1 if $value eq "";    # empty string is always fine for text options
	my $validator = $spec->validator;
	return 1 unless $validator;
	$validator = qr($validator);
	return 1 if $value =~ /^$validator$/;
	return 0;
    } elsif ($spec->option_type eq "int") {
	return 1 if $value eq "";    # empty string is always fine for integer options
	return 0 unless $value =~ /^[-+]?\d+$/;
	return 0 if defined $spec->minint && $value < $spec->minint;
	return 0 if defined $spec->maxint && $value > $spec->maxint;
    } elsif ($spec->option_type eq "select") {
	return 1 if $value eq "";    # empty string is always fine for selectable options
	my @vals = split /\|/, $spec->selection;
	for my $possible_val (@vals) {
	    return 1 if $value eq $possible_val;
	}
	return 0;  # not a good value
    } elsif ($spec->option_type eq "bool") {
	return 1;  # XXX  how about "yes" or "no" etc?
    }

    return 1;  # accept by default
}

1;

=head1 COPYRIGHT & LICENSE

Copyright 2015 University of Oregon, all rights reserved.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY
or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software Foundation,
Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

=cut
