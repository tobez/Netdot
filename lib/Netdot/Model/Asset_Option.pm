package Netdot::Model::Asset_Option;

use base 'Netdot::Model';
use warnings;
use strict;

use Netdot::Model::Asset_Option_Spec;
use Netdot::Model::Location_Option;

=head1 NAME

Netdot::Model::Asset_Option - Asset options

=cut

__PACKAGE__->add_constraint('Asset_Option_Is_Valid', value => \&check_value_validity);

sub check_value_validity
{
    my ($value, $self, $column_name, $changing) = @_;

    my $spec_id;
    if (ref $self) {
	$spec_id = $self->asset_option_spec->id;
    }
    if ($changing->{asset_option_spec}) {
	if (ref $changing->{asset_option_spec}) {
	    $spec_id = $changing->{asset_option_spec}->id;
	} else {
	    $spec_id = $changing->{asset_option_spec};
	}
    }
    return 0 unless defined $spec_id;
    return 1 unless defined $value;  # null is always fine

    my $spec = Asset_Option_Spec->retrieve($spec_id);
    return Netdot::Model::Location_Option::check_value_validity_for_option_spec($value, $spec);
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
