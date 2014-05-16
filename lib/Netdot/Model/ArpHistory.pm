package Netdot::Model::ArpHistory;

use base 'Netdot::Model';
use warnings;
use strict;
use DBI qw(:sql_types);

my $logger = Netdot->log->get_logger('Netdot::Model::Device');

# Make sure to return 1
1;

=head1 NAME 

Netdot::Model::ArpHistory

=head1 SYNOPSIS

ARP Cache Entry class

=head1 CLASS METHODS
=cut

##################################################################

=head2 fast_insert - Faster inserts for specific cases

    This method will traverse a list of hashes containing ARP cache
    info.  Meant to be used by processes that insert/update large amounts of 
    objects.  We use direct SQL commands for improved speed.

  Arguments: 
    Hash containing these keys:
    list = Arrayref of hash refs with following keys:
           device    - id of Device
           interface - id of Interface
           ip_id     - id of Ipblock
           mac_id    - id of PhysAddr
    timestamp
  Returns:   
    True if successul
  Examples:
    ArpHistory->fast_insert(list=>\@list);

=cut

sub fast_insert{
    my ($class, %argv) = @_;
    $class->isa_class_method('fast_insert');
    my $list = $argv{list} || $class->throw_fatal("Missing list arg");
    my $timestamp = $argv{timestamp} || $class->timestamp;
    
    my $dbh = $class->db_Main;

    # "Upsert" trick
    my @condition;
    push @condition, "device = ?";
    push @condition, "interface = ?";
    push @condition, "ipaddr = ?";
    push @condition, "physaddr = ?";
    push @condition, "firstseen <= ?";
    push @condition, "lastseen + ?::interval >= ?";

    my $sth1 = $dbh->prepare_cached(
    	"UPDATE arphistory SET lastseen=? WHERE " . join " AND ", @condition);
	
    my $sth2 = $dbh->prepare_cached("INSERT INTO arphistory
	(device,interface,ipaddr,physaddr,firstseen,lastseen)
	SELECT ?, ?, ?, ?, ?, ?
	WHERE NOT EXISTS (
		SELECT 1 FROM arphistory WHERE " .
		(join " AND ", @condition) . ")");

    my $grace_interval = Netdot->config->get('ARPHISTORY_ENTRY_EXPIRATION');
    $grace_interval = "$grace_interval seconds";

    # Now walk our list and insert
    foreach my $r ( @$list ){
	my @cond = ($r->{device}, $r->{interface},
	    $r->{ip_id}, $r->{mac_id},
	    $timestamp, $grace_interval, $timestamp);
	$sth1->execute($timestamp, @cond);
	$sth2->execute($r->{device}, $r->{interface},
	    $r->{ip_id}, $r->{mac_id},
	    $timestamp, $timestamp,
	    @cond);
    }
    
    return 1;
}


=head1 INSTANCE METHODS
=cut

=head2 search_by_ip - Retrieve all entries corresponding to given IP

    Returns list ordered by ArpCache timestamp.  Relies on SQL for 
    sorting timestamp values efficiently.

  Arguments: 
    Ipblock id
  Returns:   
    Array of ArpCacheEntry objects
  Examples:
    ArpCacheEntry->search_by_ip($ip->id)

=cut

__PACKAGE__->set_sql(by_ip => qq{
    SELECT arpcacheentry.id, arpcacheentry.physaddr
	FROM arpcacheentry, arpcache, ipblock
	WHERE arpcacheentry.arpcache=arpcache.id AND
	arpcacheentry.ipaddr=ipblock.id AND
	ipblock.id = ?
	ORDER BY arpcache.tstamp DESC
    });


=head2 search_interface - Retrieve all entries for given interface and timestamp

  Arguments: 
    Interface id
    ArpCache timestamp
  Returns:   
    Array of ArpCacheEntry objects
  Examples:
    ArpCacheEntry->search_interface($int->id, $tstamp)

=cut

__PACKAGE__->set_sql(interface => qq{
SELECT id
FROM   arphistory
 WHERE interface=?
   AND ? BETWEEN firstseen and lastseen
});

=head1 AUTHOR

Anton Berezin, C<< <tobez at tobez.org> >>

=head1 COPYRIGHT & LICENSE

Copyright 2014 University of Oregon, all rights reserved.

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

# vim: set ts=8:
