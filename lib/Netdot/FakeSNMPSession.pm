package Netdot::FakeSNMPSession;

use strict;
use warnings;
use Carp;
use Coro;
use AnyEvent;
use Net::SNMP::QueryEngine::AnyEvent;
use Socket;
use Data::Dump 'pp', 'dd';
use SNMP;  # we use that for OID translation

sub new
{
    my ($class, %p) = @_;
    my $me = bless \%p, $class;
    $me->_self_check;

    my %setopt;
    $setopt{version}         = $me->{Version};
    $setopt{community}       = $me->{Community} || "public";
    $setopt{timeout}         = int($me->{Timeout}/1000+0.5) if $me->{Timeout};
    $setopt{retries}         = $me->{Retries} if $me->{Retries};
    $setopt{max_repetitions} = $me->{BulkRepeaters} if $me->{BulkRepeaters};

    # XXX Handle DestHost name resolution here.  Use AnyEvent::DNS for that.
    #       kinda working method: $me->{ip} = inet_ntoa(scalar gethostbyname $p{DestHost});
    $me->{ip} = $me->{DestHost};

    my $callback = rouse_cb;
    $me->{sqe}->setopt($me->{ip}, 161, \%setopt, $callback);
    rouse_wait $callback;  # no reason to check for errors here

    $me;
}

sub _self_check
{
    my $me = shift;
    my $class = ref($me) || $me;
    for my $p (qw(sqe DestHost Version)) {
	croak("$class:\:new: argument \"$p\" must be supplied") unless $me->{$p};
    }
    croak("$class:\:new: unsupported SNMP version: $me->{Version}")
    	unless $me->{Version} == 1 || $me->{Version} == 2;
}

sub DESTROY {}

sub AUTOLOAD
{
    croak("IMPLEMENT ME: called $Netdot::FakeSNMPSession::AUTOLOAD");
}

sub get
{
    my ($me, $v, $cb) = @_;

    if (ref($v)) {
	if (ref($v) eq "SNMP::Varbind") {
	    if (@$v == 1) {
		$v = $v->[0];
	    }
	}
    }
    croak("IMPLEMENT ME: GET var is a reference we cannot (for now) handle: " . pp($v))
	if ref $v;

    my $oid = $v;
    $oid = SNMP::translateObj($oid) unless $oid =~ /^[\d.]+$/;
    $oid =~ s/^\.//;

    my $callback = rouse_cb;
    $me->{sqe}->get($me->{ip}, 161, [$oid], $callback);
    my ($sqe, $ok, $res) = rouse_wait $callback;

    # XXX error handling MUST be implemented here

    return unless $res && @$res;
    my $ret = $res->[0][1];
	$ret = "NOSUCHOBJECT" if ref $ret && $ret->[0] eq "no-such-object";
    return if ref $ret;  # error in reply

    # SNMP::Info expects OIDs in a form ".a.b.c", while
    # SQE returns OIDSs in "a.b.c" form, account for that:
    $ret = ".$ret" if $ret =~ /^1\.3\.6(?:\.\d+)+$/;

    return $ret;
}

sub bulkwalk
{
	my ($me, $non_repeaters, $max_repeaters, $vars) = @_;
	croak "Internal: non-zero non-repeaters value not supported"
		if $non_repeaters;
	croak "Vars must be a reference"
		unless ref $vars;
	croak "Internal: only SNMP::Varbind vars are supported"
		unless ref($vars) eq "SNMP::Varbind";
		
	my $oid = $vars->[0];
	$oid = SNMP::translateObj($oid) unless $oid =~ /^[\d.]+$/;
	$oid =~ s/^\.//;

	#print "bulkwalk: $oid, R($max_repeaters)\n";
	my $callback = rouse_cb;
	# XXX non-default port
	$me->{sqe}->gettable($me->{ip}, 161, $oid, $callback);
	my ($sqe, $ok, $res) = rouse_wait $callback;
	#print "Ahaha $sqe,$ok\n";

	#my $real = $me->{debug_session}->bulkwalk($non_repeaters, $max_repeaters, $vars);
	#print "Real thing:\n";
	#dd $real;

#print "GOT TABLE from $oid ($vars->[0])\n";
	# XXX error handling
	my @r;
	for my $r (@$res) {
		my $v = $r->[1];
		$v = "NOSUCHOBJECT" if ref $v && $v->[0] eq "no-such-object";
		next if ref $v;
		my $idx = $r->[0];
		$idx =~ s/^\.?\Q$oid\E\.//;

		$v = ".$v" if $v =~ /^1\.3\.6(?:\.\d+)+$/;
		push @r, bless([ $vars->[0], $idx, $v, "OCTETSTR" ], "SNMP::Varbind");
	}
	#print "Unreal thing:\n";
	#dd [bless(\@r, "SNMP::VarList")];

	return (bless(\@r, "SNMP::VarList"));
}

1;
