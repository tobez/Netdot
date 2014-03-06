package Netdot::Model::Site;

use base 'Netdot::Model';
use warnings;
use strict;

# Make sure to return 1
1;

=head1 NAME

Netdot::Model::Site

=head1 CLASS METHODS
=cut

=head2 search_with_backbones

=cut

__PACKAGE__->set_sql(with_backbones => qq{
SELECT   site.id 
FROM     site, closet, room, floor, backbonecable
WHERE    (backbonecable.start_closet=closet.id OR backbonecable.end_closet=closet.id) 
  AND    ((closet.room=room.id AND room.floor=floor.id) AND floor.site=site.id) 
GROUP BY site.id, site.name    
ORDER BY site.name
});

=head2 search_with_closets

=cut

__PACKAGE__->set_sql(with_closets => qq{
SELECT   site.id 
FROM     site, closet, room, floor
WHERE    (closet.room=room.id AND room.floor=floor.id) AND floor.site=site.id 
GROUP BY site.id, site.name    
ORDER BY site.name
});

=head1 INSTANCE METHODS
=cut

############################################################################

=head2 rooms - Get list of rooms
   
  Arguments:
    None
  Returns:
    Array of Room objects
  Examples:
    my @rooms = $site->rooms;

=cut

sub rooms { 
    my ($self) = @_;
    
    my @rooms;
    foreach my $floor ( $self->floors ){
	push @rooms, $floor->rooms;
    }
    return @rooms;
}

#############################################################################

=head2 closets - Get list of closets
  
  Arguments:
    None
  Returns:
    Array of Closet objects
  Examples:
    my @closets = $site->closets;

=cut

sub closets {
    my ($self) = @_;
    my @closets;
    foreach my $room ( $self->rooms ){
	if ( $room->closets ){
	    push @closets, $room->closets;
	}
    }
    return @closets;
}

##################################################################

=head2 get_label - Override get_label method

    Appends site number if available

  Arguments:
    None
  Returns:
    string
  Examples:
    print $site->get_label();

=cut

sub get_label {
    my $self = shift;
    $self->isa_object_method('get_label');
    my $lbl = $self->name;
    if ( my $aliases = $self->aliases ){
	$lbl .= " ($aliases)"; 
    } 
    if ( my $number = $self->number ){
	$lbl .= " ($number)";
    }
    return $lbl;
}

=head1 AUTHOR

Carlos Vicente, C<< <cvicente at ns.uoregon.edu> >>

=head1 COPYRIGHT & LICENSE

Copyright 2012 University of Oregon, all rights reserved.

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

1;
# vim: set ts=8:
