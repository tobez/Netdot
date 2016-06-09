package Netdot::Model::Location;

use base 'Netdot::Model';
use warnings;
use strict;
use JSON::XS;

use constant MAGIC_RACK   => 0x10;
use constant MAGIC_HIDDEN => 0x20;  # used for rack positions

use constant FIB_FRONT    => 0x01;
use constant FIB_INTERIOR => 0x02;
use constant FIB_BACK     => 0x04;

=head1 NAME

Netdot::Model::Location - Location class

=head1 SYNOPSIS

my @roots = Location->roots();

=head1 CLASS METHODS
=cut

###########################################################################

=head2 roots - Get all locations without a parent

  Arguments: 
    None
  Returns: 
    Array of Location objects, possibly empty

=cut

sub roots
{
    my ($class) = @_;
    $class->isa_class_method('roots');
    
    return $class->retrieve_from_sql("located_in is null");
}

=head1 INSTANCE METHODS
=cut

###########################################################################

=head2 as_hash - return location information as a hash

  Arguments: 
    None
  Returns: 
    A hash reference representing the location, with extras

=cut

sub as_hash
{
    my $self = shift;
    $self->isa_object_method('as_hash');

    my $dbh = Netdot::Model->db_Main;

    my $label = $self->get_label;
    my $t_obj = $self->location_type;
    my @po_obj = $t_obj->possible_options;
    my @po;
    for my $po (sort { $a->id <=> $b->id } @po_obj) {
        push @po, {
            id          => $po->id,
            name        => $po->name,
            option_type => $po->option_type,
            selection   => $po->selection,
            validator   => $po->validator,
            minint      => $po->minint,
            maxint      => $po->maxint,
            defvalue    => $po->defvalue,
            description => $po->description,
        };
    }

    my @o_obj = $self->options;
    my @o;
    for my $o (@o_obj) {
        push @o, {
            id             => $o->id,
            value          => $o->value,
            option_spec_id => $o->location_option_spec->id,
            option_type    => $o->location_option_spec->option_type,
        };
    }

    my %want_assets;
    my %id2magic;
    $want_assets{$self->id} = 1;
    $id2magic{$self->id} = $t_obj->magic;

    my $kids = $dbh->selectall_arrayref(
	"select l.id, l.name, l.description, l.info, " .
	"lt.id as lt_id, lt.name as lt_name, lt.magic " .
	"from location l, location_type lt where " .
	"l.located_in = ? and lt.id = l.location_type " .
	"order by l.id", {Slice=>{}}, $self->id) || [];

    my $n_hidden_children = 0;
    my %rp;
    my %fp;
    my %bp;
    my %rack_pos_labels;
    my $n_children = @$kids;
    my @racks;

    if ($t_obj->magic & MAGIC_RACK) {

	my $positions = $dbh->selectall_arrayref(
	    "select l.id, lo.value from
	    location l, location_option_spec los, location_option lo
	    where
	    l.located_in = ? and
	    los.location_type = l.location_type and
	    los.name = 'position' and
	    lo.location = l.id and
	    los.id = lo.location_option_spec",
	    {Slice=>{}}, $self->id
	);
	my %kid2pos;
	for my $kp (@$positions) {
	    $kid2pos{$kp->{id}} = $kp->{value};
	}

	for my $kid (@$kids) {
	    $id2magic{$kid->{id}} = $kid->{magic};
	    if ($kid->{magic} & MAGIC_HIDDEN) {
		$n_hidden_children++;
		$want_assets{$kid->{id}} = 1;
		my $rp = $kid2pos{$kid->{id}};
		if (defined $rp) {
		    $rp{$kid->{id}} = $rp;

		    my $l = "$label, position $rp";
		    if ($kid->{magic} & FIB_FRONT) {
			$l .= " at the front";
		    } elsif ($kid->{magic} & FIB_BACK) {
			$l .= " at the back";
		    } else {
			$l .= " in the interior";
		    }
		    $rack_pos_labels{$kid->{id}} = $l;

		    if ($kid->{magic} & FIB_FRONT) {
			$fp{$rp} = $kid->{id};
		    } elsif ($kid->{magic} & FIB_BACK) {
			$bp{$rp} = $kid->{id};
		    }
		}
	    }
	}
    } else {
	for my $kid (@$kids) {
	    $id2magic{$kid->{id}} = $kid->{magic};
	    if ($kid->{magic} & MAGIC_RACK) {
		# XXX bless to call
		my $kid_obj = Location->retrieve($kid->{id});
		push @racks, $kid_obj->as_hash;
	    }
	}
    }

my $sql = 
	    "select a.id, a.location, p.hsize, p.vsize
	    from asset a left join product p
	    on a.product_id = p.id
	    where
	    a.location in (" . join(",",keys %want_assets) . ")";
#print "$sql\n";
    my $assets = $dbh->selectall_arrayref(
	    "select
	    a.id, a.location, a.serial_number, a.physaddr,
	    p.hsize, p.vsize, p.name as product_name,
	    e.name as manufacturer,
	    m.address as mac
	    from asset a
	    join product p on a.product_id = p.id
	    join entity e on p.manufacturer = e.id
	    left join physaddr m on a.physaddr = m.id
	    where
	    a.location in (" . join(",",keys %want_assets) . ") order by a.id",
	    {Slice=>{}}
	);

    my @assets;
    for my $as (@$assets) {
	my $loc_id = $as->{location};
	my $pos = $rp{$loc_id};
	my $hsize = $as->{hsize};
	my $fib = 0;

	if ($pos) {
	    my $magic = $id2magic{$loc_id};
	    if ($hsize == 1) {
		$fib = (FIB_FRONT & $magic) | (FIB_BACK & $magic);
	    } elsif ($hsize == 2) {
		$fib = (FIB_FRONT & $magic) | FIB_INTERIOR | (FIB_BACK & $magic);
	    } else {  # anything else assume full-size
	    	$fib = FIB_FRONT | FIB_INTERIOR | FIB_BACK;
	    }
	}
	$as->{serial_number} //= "";
	$as->{mac}           //= "";
	my $l = "$as->{manufacturer} $as->{product_name}";
	$l .= ", $as->{serial_number}" if $as->{serial_number};
	$l .= ", $as->{mac}" if $as->{mac};
	push @assets, {
	    id          => $as->{id},
	    hsize       => $hsize,
	    vsize       => $as->{vsize},
	    location_id => $loc_id,
	    label       => $l,
	    position    => defined $pos ? 0+$pos : undef,
	    fib         => defined $fib ? 0+$fib : undef, # front-interior-back
	}
    }

    return {
        id            => $self->id,
        located_in    => $self->located_in ? $self->located_in->id : undef,
        name          => $self->name,
        description   => $self->description,
        info          => $self->info,
        location_type => {
            id    => $t_obj->id,
            name  => $t_obj->name,
            magic => $t_obj->magic,
        },
        possible_options => \@po,
        options          => \@o,
	has_children     => $n_children > $n_hidden_children ? 1 : 0,
	assets           => \@assets,
	racks            => \@racks,
	label            => $label,
	front_positions  => \%fp,
	back_positions   => \%bp,
	rack_pos_labels  => \%rack_pos_labels,
    };
}

sub as_hash_slow
{
    my $self = shift;
    $self->isa_object_method('as_hash_slow');
    
    my $t_obj = $self->location_type;
    my @po_obj = $t_obj->possible_options;
    my @po;
    for my $po (sort { $a->id <=> $b->id } @po_obj) {
        push @po, {
            id          => $po->id,
            name        => $po->name,
            option_type => $po->option_type,
            selection   => $po->selection,
            validator   => $po->validator,
            minint      => $po->minint,
            maxint      => $po->maxint,
            defvalue    => $po->defvalue,
            description => $po->description,
        };
    }

    my @o_obj = $self->options;
    my @o;
    for my $o (@o_obj) {
        push @o, {
            id             => $o->id,
            value          => $o->value,
            option_spec_id => $o->location_option_spec->id,
            option_type    => $o->location_option_spec->option_type,
        };
    }

    my @c = $self->contains;
    my @a = $self->assets;
    my %rp;
    my %fp;
    my %bp;
    my %rack_pos_labels;
    my $n_hidden_children = 0;
    my $n_children = @c;
    my @racks;
    if ($t_obj->magic & MAGIC_RACK) {
	for my $kid (@c) {
	    my $magic = $kid->location_type->magic;
	    if ($magic & MAGIC_HIDDEN) {
		$n_hidden_children++;
		push @a, $kid->assets;
		my @rp = $kid->options;
		for my $rp (@rp) {
		    if ($rp->location_option_spec->name eq "position") {
			$rp{$kid->id} = $rp->value;
			$rack_pos_labels{$kid->id} = $kid->get_label;
			if ($magic & FIB_FRONT) {
			    $fp{$rp->value} = $kid->id;
			} elsif ($magic & FIB_BACK) {
			    $bp{$rp->value} = $kid->id;
			}
		    }
		}
	    }
	}
    } else {
	for my $kid (@c) {
	    my $magic = $kid->location_type->magic;
	    if ($magic & MAGIC_RACK) {
		push @racks, $kid->as_hash_slow;
	    }
	}
    }
    my @assets;
    for my $as (@a) {
	my $loc_id = $as->location->id;
	my $pos = $rp{$loc_id};
	my $hsize = $as->product_id->hsize;
	my $fib = 0;

	if ($pos) {
	    my $magic = $as->location->location_type->magic;
	    if ($hsize == 1) {
		$fib = (FIB_FRONT & $magic) | (FIB_BACK & $magic);
	    } elsif ($hsize == 2) {
		$fib = (FIB_FRONT & $magic) | FIB_INTERIOR | (FIB_BACK & $magic);
	    } else {  # anything else assume full-size
	    	$fib = FIB_FRONT | FIB_INTERIOR | FIB_BACK;
	    }
	}
	push @assets, {
	    id          => $as->id,
	    hsize       => $hsize,
	    vsize       => $as->product_id->vsize,
	    location_id => $loc_id,
	    label       => $as->get_label,
	    position    => defined $pos ? 0+$pos : undef,
	    fib         => defined $fib ? 0+$fib : undef, # front-interior-back
	}
    }

    return {
        id            => $self->id,
        located_in    => $self->located_in ? $self->located_in->id : undef,
        name          => $self->name,
        description   => $self->description,
        info          => $self->info,
        location_type => {
            id    => $t_obj->id,
            name  => $t_obj->name,
            magic => $t_obj->magic,
        },
        possible_options => \@po,
        options          => \@o,
	has_children     => $n_children > $n_hidden_children ? 1 : 0,
	assets           => \@assets,
	racks            => \@racks,
	label            => $self->get_label,
	front_positions  => \%fp,
	back_positions   => \%bp,
	rack_pos_labels  => \%rack_pos_labels,
    };
}

###########################################################################

=head2 as_json - return location information as a JSON string

  Arguments: 
    None
  Returns: 
    A JSON string representing the location

=cut

sub as_json
{
    my $self = shift;
    $self->isa_object_method('as_json');
    
    return JSON::XS::encode_json($self->as_hash);
}

###########################################################################

=head2 is_hidden - return whether the location should be hidden in the ui

  Arguments: 
    None
  Returns: 
    Boolean

=cut

sub is_hidden
{
    my $self = shift;
    $self->isa_object_method('is_hidden');
    
    return $self->location_type->magic & MAGIC_HIDDEN;
}

##################################################################

=head2 get_label - Override get_label method

  Returns the typename + the name of the location,
  or, for rack positions, "rack: " + the name of the rack,
  position@front or position@back

  Arguments:
    None
  Returns:
    string
  Examples:
    print $loc->get_label();

=cut

sub get_label
{
    my $self = shift;
    $self->isa_object_method('get_label');

    my $t_obj = $self->location_type;
    my $magic = $t_obj->magic;
    if ($magic & MAGIC_HIDDEN) {
	my $pos = "position ";
	my @o_obj = $self->options;
	for my $o (@o_obj) {
	    if ($o->location_option_spec->name eq "position") {
		$pos .= $o->value;
	    }
	}
	if ($magic & FIB_FRONT) {
	    $pos .= " at the front";
	} elsif ($magic & FIB_BACK) {
	    $pos .= " at the back";
	} else {
	    $pos .= " in the interior";
	}
	return $self->located_in->get_label . ", $pos";
    } else {
	return $self->location_type->name . ": " . $self->name;
    }
}

##################################################################

=head2 delete - Delete Location object

    We override delete to handle reparenting of children properly

  Arguments:
    none
   Returns:
    True if successful
  Examples:
    $loc->delete();

=cut

sub delete {
    my $self = shift;
    $self->isa_object_method('delete');
    my $class = ref($self);

    my @c = $self->contains;
    for my $c (@c) {
	if ($c->location_type->magic & MAGIC_HIDDEN) {
	    # hidden children are to be deleted
	    $c->delete;
	} else {
	    # other children are to be reparented
	    $c->located_in($self->located_in);
	    $c->update;
	}
    }

    $self->SUPER::delete();
    return 1;
}


##################################################################

=head2 hash_update - handle location update 

  Takes a hashref similar in structure to that returned by
  as_hash() method, and performs a location (and location
  options) update.

  Arguments:
    A hash
  Returns:
    An updated hash
  Examples:
    $rest->print_serialized(Netdot::Model::Location->hash_update($loc_hash));

=cut

sub hash_update
{
    my ($class, $new) = @_;
    $class->isa_class_method('hash_update');
    
    my $loc = $class->retrieve($new->{id});
    my $old = $loc->as_hash;

    # XXX add sanity checks and other validations

    my $do_update = 0;
    if ($new->{name} ne $old->{name}) {
	$loc->name($new->{name});
	$do_update = 1;
    }
    if ($new->{info} ne $old->{info}) {
	$loc->info($new->{info});
	$do_update = 1;
    }
    if ($do_update) {
	$loc->update;
    }
    my %oo;
    for my $oo (@{$old->{options}||[]}) {
	$oo{$oo->{id}} = $oo;
    }
    for my $no (@{$new->{options}||[]}) {
	if ($no->{id}) {
	    # edit option
	    my $oo = $oo{$no->{id}};
	    if ($oo->{value} ne $no->{value}) {
		my $opt = Netdot::Model::Location_Option->retrieve($no->{id});
		$opt->value($no->{value});
		$opt->update;
	    }
	} else {
	    # new option
	    my $opt = Netdot::Model::Location_Option->insert({
		location_option_spec => $no->{option_spec_id},
		location             => $new->{id},
		value                => $no->{value},
	    });
	}
    }

    $loc = Netdot::Model::Location->retrieve($new->{id});
    return $loc->as_hash;
}

##################################################################

=head2 hash_insert - handle location insert

  Takes a hashref similar in structure to that returned by
  as_hash() method, and creates a new location together with
  the supplied options.

  Arguments:
    A hash
  Returns:
    A hash of the inserted location
  Examples:
    $rest->print_serialized(Netdot::Model::Location->hash_insert($loc_hash));

=cut

sub hash_insert
{
    my ($class, $new) = @_;
    $class->isa_class_method('hash_insert');
    
    # XXX add sanity checks and other validations
    # XXX add population of rack positions if the inserted location is a rack

    my $loc = $class->insert({
	description   => $new->{description},
	located_in    => $new->{located_in},
	location_type => $new->{location_type},
	name          => $new->{name},
	info          => $new->{info},
    });

    for my $no (@{$new->{options}||[]}) {
        my $opt = Netdot::Model::Location_Option->insert({
	    location_option_spec => $no->{option_spec_id},
	    location             => $loc->{id},
	    value                => $no->{value},
	});
    }

    if ($loc->location_type->magic & MAGIC_RACK) {
	my $rack_size = $loc->opt("size");
	my $direction = $loc->opt("direction");
	my @types = Location_Type->retrieve_all;

	my @to_add;
	for my $t (@types) {
	    my $magic = $t->magic;
	    next unless $magic & MAGIC_HIDDEN;
	    if ($magic & (FIB_FRONT|FIB_BACK)) {
		my $add = {
		    location_type_id => $t->id
		};
		for my $po ($t->possible_options) {
		    if ($po->name eq "position") {
			$add->{option_spec_id} = $po->id;
		    }
		}
		push @to_add, $add;
	    }
	}

	for my $i (1..$rack_size) {
	    my $n = $direction eq "downwards" ? $i : $rack_size - $i + 1;
	    for my $add (@to_add) {
		my $rackpos = $class->insert({
		    description   => "",
		    located_in    => $loc->id,
		    location_type => $add->{location_type_id},
		    name          => "pos $n",
		});
		my $opt = Netdot::Model::Location_Option->insert({
		    location_option_spec => $add->{option_spec_id},
		    location             => $rackpos->id,
		    value                => $n,
		});
	    }
	}
    }

    $loc = Netdot::Model::Location->retrieve($loc->id);
    return $loc->as_hash;
}

# XXX add documentation and other customary formatting
sub opt
{
    my ($self, $opt_name) = @_;
# XXX instance method

    my $t_obj = $self->location_type;

    my $val;
    my $id;
    for my $po ($t_obj->possible_options) {
	if ($po->name eq $opt_name) {
	    $id = $po->id;
	    if (defined $po->defvalue) {
		$val = $po->defvalue;
	    } elsif ($po->option_type eq "select") {
		$val = (split /\|/, $po->selection)[0];
	    }
	}
    }

    my @o_obj = $self->options;
    for my $o ($self->options) {
	if ($o->location_option_spec->id == $id) {
	    $val = $o->value;
	}
    }

    return $val;
}

=head2 search_with_backbones

=cut

__PACKAGE__->set_sql(with_backbones => qq{
SELECT   location.id 
FROM     location, backbonecable
WHERE    backbonecable.start_location=location.id OR backbonecable.end_location=location.id
GROUP BY location.id, location.name    
ORDER BY location.name
});

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
