package Netdot::Model::Ipblock;

use base 'Netdot::Model';
use warnings;
use strict;
use Math::BigInt;
use NetAddr::IP ':lower';
use Storable qw(nfreeze thaw);
use Scalar::Util qw(blessed);
use DBI qw(:sql_types);

=head1 NAME

Netdot::Model::Ipblock - Manipulate IP Address Space

=head1 SYNOPSIS
    
    my $newblock = Ipblock->insert({address=>'192.168.1.0', prefix=>32});
    print $newblock->cidr;
    my $subnet = $newblock->parent;
    print "Address Usage ", $subnet->address_usage;
    
=cut

# We want an easy and family-independent way to produce "127.0.0.1"
# and "2001:db8::6" strings.
# "Standard" NetAddr::IP::short would produce "127.1" and "2001:db8::6",
# while NetAddr::IP::addr would produce "127.0.0.1" and
# "2001:2010:0:0:0:0:0:1".  Hence we monkey patch NetAddr::IP namespace
# to add a palliative method ->ip().
*NetAddr::IP::ip = sub {
    $_[0]->version == 4 ? $_[0]->addr : $_[0]->short;
};

my $logger = Netdot->log->get_logger('Netdot::Model::Ipblock');

BEGIN{
    # Load plugins at compile time

    my $ip_name_plugin_class = __PACKAGE__->config->get('DEVICE_IP_NAME_PLUGIN');
    eval  "require $ip_name_plugin_class";
    if ( my $e = $@ ){
	die $e;
    }
    
    sub _load_ip_name_plugin{
	$logger->debug("Loading IP_NAME_PLUGIN: $ip_name_plugin_class");
	return $ip_name_plugin_class->new();
    }

    my $range_dns_plugin_class = __PACKAGE__->config->get('IP_RANGE_DNS_PLUGIN');
    eval  "require $range_dns_plugin_class";
    if ( my $e = $@ ){
	die $e;
    }
    
    sub _load_range_dns_plugin{
	$logger->debug("Loading IP_RANGE_DNS_PLUGIN: $range_dns_plugin_class");
	return $range_dns_plugin_class->new();
    }
}

my $IPV4 = Netdot->get_ipv4_regex();
my $IPV6 = Netdot->get_ipv6_regex();

my $ip_name_plugin   = __PACKAGE__->_load_ip_name_plugin();
my $range_dns_plugin = __PACKAGE__->_load_range_dns_plugin();

=head1 CLASS METHODS

=cut

##################################################################

=head2 int2ip - Convert a decimal IP into a string address

  Arguments:
    address (decimal)
    version (4 or 6)
  Returns:
    string
  Example:
    my $address = Ipblock->int2ip($number, $version);

=cut

sub int2ip {
    my ($class, $address, $version) = @_;
    
    unless ( defined($address) ) {
	$class->throw_fatal(sprintf("Missing required argument: address"));
    }
    unless ( defined($version) ){
	$class->throw_fatal(sprintf("Missing required argument: version "));
    }
    
    my $val;
    if ( $version == 4 ){
	$val = NetAddr::IP->new($address)->addr();
    }elsif ( $version == 6 ) {
	my $bigint = new Math::BigInt $address;
	# Use the compressed version
	$val = NetAddr::IP->new6($bigint)->short();

	# Per RFC 5952 recommendation
	$val = lc($val);

    }else{
	$class->throw_fatal(sprintf("Invalid IP version: %s", $version));
    }
    return $val;
}

##################################################################

=head2 search - Search Ipblock objects

    We override the base search method for these reasons:
    - Ipblock objects are stored as decimal integers, so 
      there must be a conversion prior to searching
    - Allow the user to specify a CIDR address

  Arguments:
    Hash with field/value pairs
  Returns:
    Array of Ipblock objects, iterator or undef
  Examples:
    my @objs = Ipblock->search(field => $keyword);

=cut

sub search {
    my ($class, @args) = @_;
    $class->isa_class_method('search');
    
    # Class::DBI::search() might include an extra 'options' hash ref
    # at the end.  In that case, we want to extract the 
    # field/value hash first.
    my $opts = @args % 2 ? pop @args : {}; 
    my %args = @args;
   
    if ( defined $args{status} ){
	my $statusid = $class->_get_status_id($args{status});
	$args{status} = $statusid;
    }
    if ( defined $args{address} ){
	if ( $args{address} =~ /.+\/\d+$/ ){
	    $args{addr} = delete $args{address};
	}elsif ( $args{address} =~ /\D/ ){
	    # Address contains non-digits
	    if ( $class->matches_ip($args{address}) ){
		$args{addr} = delete $args{address};
		$args{addr} .= "/$args{prefix}" if defined $args{prefix};
		delete $args{prefix};
	    }else{
		$class->throw_user(sprintf("Address %s does not match valid IP v4/v6 formats", $args{address}));
	    }
	}
    }
    if ($args{version}) {
	$args{"family(addr)"} = delete $args{version};
    }
    if ($args{prefix}) {
	$args{"masklen(addr)"} = delete $args{prefix};
    }
    return $class->search_where(\%args, $opts);
}

##################################################################

=head2 search_like - Search IP Blocks that match the specified regular expression

    We override the base method to adapt to the specific nature of Ipblock objects.

    When specifying an address search, a Perl regular expression is expected.
    The regular expression is applied to the CIDR version of the address.
    The result set is limited by the configuration variable 'IPMAXSEARCH'

    If search is performed on other fields, it behaves as base method (See Class::DBI).

 Arguments: 
    hash with key/value pairs
 Returns:   
    array of Ipblock objects sorted by address
  Examples:
    
    my @ips = Ipblock->search_like(address=>'^192.*\/32')

    Returns all /32 addresses starting with 192

=cut

sub search_like {
    # XXX rewrite according to Carlos' intentions
    my $class = shift;
    $class->isa_class_method('search_like');

    my $opts;
    $opts = pop @_ if @_ % 2;
    my %argv = @_;
    $opts->{order_by} = "addr" unless $opts && $opts->{order_by};

    if ($argv{address}) {
	my $addr = $argv{address};
	$addr =~ s/\/(\d+)$//;
	my $prefix = $1;
	$addr =~ s/[.:]$//;
	if ($addr =~ /^[\d.]+$/) {
	    # assume IPv4
	    my $o = $addr =~ tr/././;   $o++;
	    $addr = join ".", $addr, ("0") x (4-$o);
	    $addr .= "/" . (32-(4-$o)*8);
	    $argv{'addr'} = { '<<=', $addr };
	    $argv{'masklen(addr)'} = { '=', $prefix } if $prefix;
	} elsif ($addr =~ /^[\da-fA-F:]+$/) {
	    # assume IPv6
	    my $o = $addr =~ tr/:/:/;  $o++;
	    $addr = join ":", $addr, ("0") x (8-$o);
	    $addr .= "/" . (128-(8-$o)*16);
	    $argv{'addr'} = { '<<=', $addr };
	    $argv{'masklen(addr)'} = { '=', $prefix } if $prefix;
	} else {
	    # normal "like" from text
	    $argv{'text(addr)'} = { LIKE => "$argv{address}%" };
	}
	delete $argv{address};
    }

    # replacing search_like with search_where
    for my $like (values %argv) {
	next if ref $like;
	$like = { LIKE => $like };
    }
    return $class->search_where(\%argv, $opts);	
}

##################################################################

=head2 keyword_search - Search by keyword
    
    The list of search fields includes Entity, Site, Description and Comments
    The result set is limited by the configuration variable 'IPMAXSEARCH'

 Arguments: 
    string or substring
 Returns: 
    array of Ipblock objects
  Examples:
    Ipblock->keyword_search('Administration');

=cut

sub keyword_search {
    my ($class, $string) = @_;
    $class->isa_class_method('keyword_search');

    # Add wildcards
    my $crit = "%" . $string . "%";

    my @sites    = Site->search_like  (name => $crit );
    my @ents     = Entity->search_like(name => $crit );
    my %blocks;  # Hash to prevent dups
    map { $blocks{$_} = $_ } __PACKAGE__->search_like(description => $crit);
    map { $blocks{$_} = $_ } __PACKAGE__->search_like(info        => $crit);

    # Use the SiteSubnet relationship if available
    map { $blocks{$_->subnet} = $_->subnet } map { $_->subnets } @sites; 
    
    # Add the entities related to the sites matching the criteria
    map { push @ents, $_->entity } map { $_->entities } @sites; 
    # Get the Ipblocks related to those entities
    map { $blocks{$_} = $_ } 
    map { $_->used_blocks, $_->owned_blocks } @ents;

    my @ipb;
    foreach ( keys %blocks ){
	push @ipb, $blocks{$_};
	last if (scalar (@ipb) > $class->config->get('IPMAXSEARCH'));
    }

    @ipb = sort { $a->address_numeric <=> $b->address_numeric } @ipb;
    wantarray ? ( @ipb ) : $ipb[0]; 
}


##################################################################

=head2 get_unused_subnets - Retrieve subnets with no addresses

  Arguments:
    version - 4 or 6 (defaults to all)
  Returns: 
    Array of Ipblock objects
  Examples:
    my @unused = Ipblock->get_unused_subnets(version=>4);
=cut

sub get_unused_subnets {
    my ($class, %args) = @_;
    $class->isa_class_method('get_unused_subnets');

    my (@phrases, @values);
    push @phrases, <<EOF;
id in (
 select id from ipblock o where not exists (
  select id from ipblock i where o.addr >> i.addr))
EOF
    push @phrases, <<EOF;
status in (
 select id from ipblockstatus where name = 'Subnet')
EOF
    if ($args{version} && $args{version} == 4) {
	push @phrases, "family(addr) = ?";
	push @values, 4;
	push @phrases, "not(addr <<= ?)";
	push @values, '224.0.0.0/4';
    } elsif ($args{version} && $args{version} == 6) {
	push @phrases, "family(addr) = ?";
	push @values, 6;
	push @phrases, "not(addr <<= ?)";
	push @values, 'FF00::/8';
    } else {
	push @phrases, "not(addr <<= ?)";
	push @values, '224.0.0.0/4';
	push @phrases, "not(addr <<= ?)";
	push @values, 'FF00::/8';
    }
    return $class->retrieve_from_sql(
	join(" AND ", @phrases) . " order by addr",
	@values);
}


##################################################################

=head2 get_subnet_addr - Get subnet address for a given address


  Arguments:
    address  ipv4 or ipv6 address
    prefix   dotted-quad netmask or prefix length

  Returns: 
    In scalar context, returns subnet address
    In list context, returns subnet address and prefix length

  Examples:
    my ($subnet,$prefix) = Ipblock->get_subnet_addr( address => $addr
						     prefix  => $prefix );

=cut

sub get_subnet_addr {
    my ($class, %args) = @_;
    $class->isa_class_method('get_subnet_addr');
    
    my $ip;
    unless($ip = $class->netaddr(address=>$args{address}, prefix=>$args{prefix})){
	$class->throw_fatal("Invalid IP: $args{address}/$args{prefix}");
    }
    
    return wantarray ? ($ip->network->ip, $ip->masklen) : $ip->network->ip;
}

##################################################################

=head2 is_loopback - Check if address is a loopback address

  Arguments:
    address - dotted quad ip address. Required unless called as object method.
    prefix  - dotted quad or prefix length. Optional. 
              NetAddr::IP will assume it is a host (/32 or /128)

  Returns:
    1 or 0
  Example:
    my $flag = $ipblock->is_loopback;
    my $flag = Ipblock->is_loopback('127.0.0.1');

=cut

sub is_loopback{
    my ( $self, $address, $prefix ) = @_;
    my ($netaddr, $version);
    if ( ref($self) ){
	# Called as object method
	$netaddr = $self->netaddr;
	$version = $self->version;
    }else{
	# Called as class method
	$self->throw_fatal("Missing required arguments when called as class method: address")
	    unless ( defined $address );
	if ( !($netaddr = NetAddr::IP->new($address, $prefix))){
	    my $str = ( $address && $prefix ) ? (join '/', $address, $prefix) : $address;
	    $self->throw_user("Invalid IP: $str");
	}
	$version = $netaddr->version;
    }
    if ( $version == 4 && 
	 $netaddr->within(new NetAddr::IP '127.0.0.0', '255.0.0.0') ){
	return 1;
    }elsif ( $version == 6 &&
	     $netaddr == NetAddr::IP->new6('::1') ){
	return 1;
    }
    return 0;
}

##################################################################

=head2 is_link_local - Check if address is v6 Link Local

    Can be called as either class or instance method

  Arguments:
    address - IPv6 address. Required if called as class method
    prefix  - Prefix length. Optional. NetAddr::IP will assume it is a host (/128)
  Returns:
    1 or 0
  Example:
    my $flag = Ipblock->is_link_local('fe80::1');
    my $flag = $ipblock->is_link_local();

=cut

sub is_link_local{
    my ( $self, $address, $prefix ) = @_;
    my $class = ref($self);
    my $ip;
    if ( $class ){
	$ip = $self->netaddr();
    }else{
	$self->throw_fatal("Missing required arguments: address")
	    unless $address;
	my $str;
	if ( !($ip = NetAddr::IP->new6($address, $prefix))){
	    $str = ( $address && $prefix ) ? (join '/', $address, $prefix) : $address;
	    $self->throw_user("Invalid IP: $str");
	}
    }
    if ( $ip->within(NetAddr::IP->new6("fe80::/10")) ) {
	return 1;	
    }
    return 0;
}

##################################################################
=head2 is_multicast - Check if address is a multicast address
    
  Arguments:
    address - dotted quad ip address.  Required unless called as object method
    prefix  - dotted quad or prefix length. Optional. NetAddr::IP will assume it is a host (/32 or /128)

  Returns:
    True (1) or False (0)
  Example:
    my $flag = $ipblock->is_multicast();
    my $flag = Ipblock->is_multicast('239.255.0.1');

=cut
sub is_multicast{
    my ($self, $address, $prefix) = @_;
    my ($netaddr, $version);
    if ( ref($self) ){
	# Called as object method
	$netaddr = $self->netaddr;
	$version = $self->version;
    }else{
	# Called as class method
	$self->throw_fatal("Missing required arguments when called as class method: address")
	    unless ( defined $address );
	if ( !($netaddr = NetAddr::IP->new($address, $prefix))){
	    my $str = ( $address && $prefix ) ? (join '/', $address, $prefix) : $address;
	    $self->throw_user("Invalid IP: $str");
	}
	$version = $netaddr->version;
    }
    if ( $version == 4 && 
	 $netaddr->within(new NetAddr::IP "224.0.0.0/4") ){
	return 1;
    }elsif ( $version == 6 &&
	     $netaddr->within(new6 NetAddr::IP "FF00::/8") ){
	return 1;
    }
    return 0;
}

##################################################################

=head2 within - Check if address is within block

  Arguments:
    address - dotted quad ip address.  Required.
    block   - dotted quad network address.  Required.

  Returns:
    True or false
  Example:
    Ipblock->within('127.0.0.1', '127.0.0.0/8');

=cut

sub within{
    my ($class, $address, $block) = @_;
    $class->isa_class_method('within');
    
    $class->throw_fatal("Ipblock::within: Missing required arguments: address and/or block")
	unless ( $address && $block );
    
    unless ( $block =~ /\// ){
	$class->throw_user("Ipblock::within: $block not a valid CIDR string")
    }

    my $ip = NetAddr::IP->new($address);
    $class->throw_user("Ipblock::within: bad address $address") unless $ip;

    my ($baddr, $bprefix) = split /\//, $block;
    my $network = NetAddr::IP->new($baddr, $bprefix);
    $class->throw_user("Ipblock::within: bad block $block") unless $network;
    
    return 1 if $ip->within($network);
    return 0;
}

##################################################################

=head2 insert - Insert a new block

  Modified Arguments:
    status          - name of, id or IpblockStatus object (default: Container)
    validate(flag)  - Optionally skip validation step
    no_update_tree  - Do not update IP tree
  Returns: 
    New Ipblock object or 0
  Examples:
    Ipblock->insert(\%data);
    

=cut

sub insert {
    my ($class, $argv) = @_;
    $class->isa_class_method('insert');

    $class->throw_fatal("Missing required arguments: address")
	unless ( exists $argv->{address} );

    if ( $argv->{address} =~ /.+\/\d+$/o ){
	# Address is in CIDR format
	my ($a,$p) = split /\//, $argv->{address};
	$argv->{address} = $a;
	$argv->{prefix} ||= $p; # Only if not passed explicitly
    }

    unless ( $argv->{status} ){
	if (defined $argv->{prefix} && 
	    ($class->matches_v4($argv->{address}) && $argv->{prefix} eq '32') || 
	    ($class->matches_v6($argv->{address}) && $argv->{prefix} eq '128')) {
	    $argv->{status} = "Static";
	} else {
	    $argv->{status} = "Container";
	}
    }
    
    # $ip is a NetAddr::IP object;
    my $ip = $class->_prevalidate($argv->{address}, $argv->{prefix});
    $argv->{address} = $ip->ip;
    $argv->{prefix}  = $ip->masklen;
    $argv->{version} = $ip->version;
    
    my $statusid     = $class->_get_status_id($argv->{status});
    $argv->{status}  = $statusid;

    my $timestamp = $class->timestamp;
    $argv->{first_seen} = $timestamp;
    $argv->{last_seen}  = $timestamp;

    my $no_update_tree = $argv->{no_update_tree};
    delete $argv->{no_update_tree};

    my $validate  = 1;
    if ( defined $argv->{validate} ){
	$validate = $argv->{validate};
	delete $argv->{validate};
    }

    $argv->{addr} = "$argv->{address}/$argv->{prefix}";
    delete $argv->{address};
    delete $argv->{prefix};
    delete $argv->{version};
    my $newblock = $class->SUPER::insert($argv);
    
    #####################################################################
    # Now check for rules
    # We do it after inserting because having the object and the tree
    # makes things much simpler.  Workarounds welcome.
    # Notice that we might be told to skip validation
    #####################################################################
    
    # This is a funny hack to avoid the address being shown in numeric.
    # It also makes sure that the object's attributes are updated before
    # calling validation methods
    my $id = $newblock->id;
    undef $newblock;
    $newblock = $class->retrieve($id);

    if ( $validate ){
	# We need to delete the object before bailing out
	eval { 
	    $newblock->_validate($argv);
	};
	if ( my $e = $@ ){
	    $newblock->delete();
	    $e->rethrow() if ref($e);
	}
    }
    
    # Inherit some of parent's values if it's not an address
    if ( !$newblock->is_address && $newblock->parent ){
	$newblock->SUPER::update({owner=>$newblock->parent->owner});
    }
    
    # Generate a hostaudit entry if necessary to trigger
    # a DHCP update
    if ( $newblock->status->name eq 'Dynamic' ){
	my %args;
	$args{operation} = 'insert';
	my (@fields, @values);
	foreach my $col ( $newblock->columns ){
	    if ( defined $newblock->$col ){ 
		push @fields, $col;
		if ( $newblock->$col && blessed($newblock->$col) ){
		    push @values, $newblock->$col->get_label();
		}else{
		    push @values, $newblock->$col;
		}
	    } 
	}
	$args{fields} = join ',', @fields;
	$args{values} = join ',', map { "'$_'" } @values if @values;
	$newblock->_host_audit(%args);
    }

    # Reserve first or last N addresses
    if ( !$newblock->is_address && $newblock->status->name eq 'Subnet' ){
	$newblock->reserve_first_n();
    }

    return $newblock;
}

#########################################################################

=head2 reserve_first_n - Reserve first (or last) N addresses in subnet

 Based on config option SUBNET_AUTO_RESERVE

  Arguments: 
    None
  Returns:   
    True
  Examples:
    $block->reserve_first_n();

=cut

sub reserve_first_n {
    my ($self) = @_;
    $self->isa_object_method('reserve_first_n');
    my $class = ref($self);
    my $num = $class->config->get('SUBNET_AUTO_RESERVE');
    if ( $num && $num < $self->num_addr ){
	for ( 1..$num ){
	    my $strategy = $class->config->get('SUBNET_AUTO_RESERVE_STRATEGY');
	    my $addr = $self->get_next_free(strategy=>$strategy);
	    eval {
		$class->insert({address=>$addr, status=>'Reserved', 
				no_update_tree=>1,
				validate=>0});
	    };
	    if ( my $e = $@ ){
		# Dups are possible when running parallel processes
		# Just warn and go on
		$logger->warn("Ipblock::reserve_first_n: Failed to insert address: $e");
	    }
	}
    }
    1;
}

##################################################################

=head2 get_covering_block - Get the closest available block that contains a given block

    When a block is searched and not found, it is useful in some cases to show 
    the closest existing block that would contain it.

 Arguments: 
    IP address and (optional) prefix length
 Returns:   
    Ipblock object or 0 if not found
  Examples:
    my $ip = Ipblock->get_covering_block(address=>$address, prefix=>$prefix);

=cut

sub get_covering_block {
    my ($class, %args) = @_;
    $class->isa_class_method('get_covering_block');

    $class->throw_fatal('Ipblock::get_covering_block: Missing required arguments: address')
	unless ( $args{address} );

    my @ipargs = ($args{address});
    push @ipargs, $args{prefix} if defined $args{prefix};
    my $ip = NetAddr::IP->new(@ipargs);
    return unless defined $ip;
    # XXX the retrieval code is similar to "parent" sub

    my $phrase = <<'EOF';
id in (
 select id from ipblock
 where addr >>= ?
 order by masklen(addr) desc
 limit 1)
EOF

    return $class->retrieve_from_sql($phrase, "$ip")->first;
}


##################################################################

=head2 get_roots - Get a list of root IP blocks

    Root IP blocks are blocks at the top of the hierarchy.  
    This list does not include end node addresses.

 Arguments:   
    IP version [4|6|all]
 Returns:     
    Array of Ipblock objects, ordered by prefix length
  Examples:
    @list = Ipblock->get_roots($rootversion);

=cut

sub get_roots {
    my ($class, $version) = @_;
    $class->isa_class_method('get_roots');

    $version ||= 4;
   
    my %where = ('ipblock_parent(id)' => undef);
    my %opts  = (order_by => 'addr');
    
    my $len;
    my @ipb;
    if ( $version eq '4' || $version eq 'all' ){
	$len = 32;
	$where{'family(addr)'} = 4;
	$where{'masklen(addr)'} = { '!=', $len };
	push @ipb, $class->search_where(\%where, \%opts);
    }
    if ( $version eq '6' || $version eq 'all' ){
	$len = 128;
	$where{'family(addr)'} = 6;
	$where{'masklen(addr)'} = { '!=', $len };
	push @ipb, $class->search_where(\%where, \%opts);
    }
    wantarray ? ( @ipb ) : $ipb[0]; 
}

##################################################################

=head2 numhosts - Number of hosts (/32s) in a subnet. 

    Including network and broadcast addresses

  Arguments:
    x: the mask length (i.e. 24)
  Returns:
    a power of 2       

=cut

sub numhosts {
    ## include the network and broadcast address in this count.
    ## will return a power of 2.
    my ($class, $x) = @_;
    $class->isa_class_method('numhosts');
    return 2**(32-$x);
}

##################################################################

=head2 numhosts_v6 - Number of hosts (/128s) in a v6 block. 


  Arguments:
    x: the mask length (i.e. 64)
  Returns:
    a power of 2       

=cut

sub numhosts_v6 {
    my ($class, $x) = @_;
    $class->isa_class_method('numhosts');
    return Math::BigInt->new(2)->bpow(128-$x);
}

##################################################################

=head2 shorten - Hide the unimportant octets from an ip address, based on the subnet

  Arguments:
    Hash with following keys
    ipaddr   a string with the ip address (i.e. 192.0.0.34)
    mask     the network mask (i.e. 16)

 Returns:
    String with just the host parts of the ip address (i.e. 0.34)

  Note: No support for IPv6 yet.

=cut

sub shorten {
    my ($class, %args) = @_;
    $class->isa_class_method('shorten');

    my ($ipaddr, $mask) = ($args{ipaddr}, $args{mask});

    # this code hides the insignificant (unchanging) octets from the ip address based on the subnet
    if( $mask <= 7 ) {
        # no insignificant octets (128.223.112.0)
        $ipaddr = $ipaddr;
    } elsif( $mask <= 15 ) {
        # first octet is insignificant (a.223.112.0)
        $ipaddr = substr($ipaddr, index($ipaddr,".")+1);
    } elsif( $mask <= 23 ) {
        # second octet is insignificant (a.a.112.0)
        $ipaddr = substr($ipaddr, index($ipaddr,".",index($ipaddr,".")+1)+1);
    } else {
        # mask is 24 or bigger, show the entire ip address (would be a.a.a.0, show 128.223.112.0)
        $ipaddr = $ipaddr;
    }

    return $ipaddr;
}

##################################################################

=head2 subnetmask - Mask length of a subnet that can hold $x hosts

  Arguments:
    An integer power of 2
  Returns:
    integer, 0-32
  Examples:
    my $mask = Ipblock->subnetmask(256)    

=cut

sub subnetmask {
    my ($class, $x) = @_;
    $class->isa_class_method('subnetmask');

    return 32 - (log($x)/log(2));
}

##################################################################

=head2 subnetmask_v6 - IPv6 version of subnetmask

  Arguments:
    An integer power of 2
  Returns:
    integer, 0-128

=cut

sub subnetmask_v6 {
    my ($class, $x) = @_;
    $class->isa_class_method('subnetmask_v6');

    return 128 - (log($x)/log(2));
}


##################################################################

=head2 fast_update - Faster updates for specific cases

    This method will traverse a list of hashes containing an IP address
    and other Ipblock values.  If a record does not exist with that address,
    it is created and both timestamps ('first_seen' and 'last_seen') are 
    instantiated, together with other fields.
    If the address already exists, only the 'last_seen' timestamp is
    updated.

    Meant to be used by processes that insert/update large amounts of 
    objects.  We use direct SQL commands for improved speed.

  Arguments: 
    Hash ref keyed by ip address containing a hash with following keys:
    timestamp
    prefix
    version
    status 
  Returns:   
    True if successul
  Examples:
    Ipblock->fast_update(\%ips);

=cut

sub fast_update{
    my ($class, $ips) = @_;
    $class->isa_class_method('fast_update');

    my $start = time;
    $logger->debug(sub{"Ipblock::fast_update: Updating IP addresses in DB" });
    my $dbh = $class->db_Main;

    # We use the "upsert" trick described in
    # http://stackoverflow.com/a/6527838/420431
    # to avoid handling exceptions.
    # Both UPDATE and INSERT statements are constructed
    # in such a way so they both do not fail,
    # unless there is a race, in which case the transaction might fail,
    # but this is totally fine, since timestamp will be pretty fresh
    # anyway.
    my $sth1 = $dbh->prepare_cached(
    	"UPDATE ipblock SET last_seen=? WHERE addr=?");
	
    my $sth2 = $dbh->prepare_cached("INSERT INTO ipblock 
	(addr,status,first_seen,last_seen)
	SELECT ?, ?, ?, ?
	WHERE NOT EXISTS (
		SELECT 1 FROM ipblock WHERE addr=?)");
	
    # Now walk our list
    foreach my $address ( keys %$ips ){
	my $attrs = $ips->{$address};
	my $addr = "$address/$attrs->{prefix}";

	eval {
	    $dbh->begin_work;
	    $sth1->execute($attrs->{timestamp}, $addr);
	    $sth2->execute($addr,
			   $attrs->{status},
			   $attrs->{timestamp},
			   $attrs->{timestamp},
			   $addr);
	    $dbh->commit;
	};
	if (my $e = $@) {
	    $logger->error($e);
	}
    }
    
    my $end = time;
    $logger->debug(sub{ sprintf("Ipblock::fast_update: Done Updating: %d addresses in %s",
				scalar(keys %$ips), $class->sec2dhms($end-$start)) });
    return 1;
}


##################################################################

=head2 get_maxed_out_subnets - 

  Arguments:
    version (optional)
  Returns:
    Array of arrayrefs containing the subnet object and the percentage of free addresses
  Examples:
    my @maxed_out = Ipblock->get_maxed_out_subnets();

=cut

sub get_maxed_out_subnets {
    my ($self, %args) = @_;
    $self->isa_class_method('get_maxed_out_subnets');

    my $threshold = Netdot->config->get('SUBNET_USAGE_MINPERCENT') 
	|| $self->throw_user("Ipblock::get_maxed_out_subnets: SUBNET_USAGE_MINPERCENT is not defined in config");

    my (@phrases, @values);
    push @phrases, "status in (
	select id from ipblockstatus where name = 'Subnet')";
    if ($args{version}) {
	push @phrases, "family(addr) = ?";
	push @values, $args{version};
    }
    # Ignore point-to-point subnets XXX but what about IPv6 point-to-point?
    push @phrases, "not (family(addr) = 4 and masklen(addr) >= 30)";
    my @subnets = $self->retrieve_from_sql(
	join(" AND ", @phrases) . " order by addr",
	@values);

    my @result;
    for my $subnet (@subnets) {
	my $total        = $subnet->num_addr;
	my $used         = $subnet->num_children;
	my $free         = $total - $used;
	my $percent_free = ($free*100/$total);
	
	if ( $percent_free <= $threshold ){
	    push @result, [$subnet, $percent_free];
	}
    }
    return @result;
}

################################################################

=head2 add_range - Add or update a range of addresses
    
  Arguments: 
    Hash with following keys:
      start       - First IP in range
      end         - Last IP in range
      status      - Ipblock status
      gen_dns     - Boolean.  Auto generate A/AAAA and PTR records (optional)
      name_prefix - String to prepend to host part of IP address (optional)
      name_suffix - String to append to host part of IP address (optional)
      fzone       - Forward Zone id for DNS records (optional)
  Returns:   
    Array of Ipblock objects
  Examples:

=cut

sub add_range{
    my ($self, %argv) = @_;
    $self->isa_object_method('add_range');

    $self->throw_user("Missing required argument: status")
	unless $argv{status};

    $self->throw_user("Please enable DHCP on this subnet before " .
                       "attempting to create dynamic addresses")
	if ( $argv{status} eq 'Dynamic' && !$self->dhcp_scopes );
    
    my $ipstart  = NetAddr::IP->new($argv{start}, $self->prefix);
    my $ipend    = NetAddr::IP->new($argv{end},   $self->prefix);
    unless ( $ipstart && $ipend && ($ipstart <= $ipend) ){
	$self->throw_user("Invalid range: $argv{start} - $argv{end}");
    }
    my $np = $self->netaddr();
    unless ( $ipstart->within($np) && $ipend->within($np) ){
	$self->throw_user("Start and/or end IPs not within this subnet: ".$self->get_label);
    }
    my $prefix  = ($self->version == 4)? 32 : 128;

    my @newips;
    my %args = (
	status         => $argv{status},
	validate       => 0, # Make it faster
	no_update_tree => 1, # not necessary because we're passing parent id
	);
    $args{used_by}     = $argv{used_by}     if $argv{used_by};
    $args{description} = $argv{description} if $argv{description};
    # Below we make a copies of the args hash because
    # passing by reference causes it to be modified by insert/update
    # and that breaks the next cycle
    for ( my($ip) = $ipstart->copy; $ip <= $ipend; $ip++ ){
	if ( my $ipb = Ipblock->search(address=>$ip->ip, prefix=>$prefix)->first ){
	    my %uargs = %args;
	    $ipb->update(\%uargs);
	    push @newips, $ipb;
	}else{
	    my %iargs = %args;
	    $iargs{address} = $ip->ip;
	    $iargs{prefix}  = $prefix;
	    push @newips, Ipblock->insert(\%iargs);
	}
	# In theory, we should not need this, but there is a strange
	# behavior in NetAddr::IP in which the for loop will become infinite
	# if $ipend is the broadcast in the subnet.
	last if $ip == $ipstart->broadcast;
    }
    #########################################
    # Call the plugin that generates DNS records
    if ( $argv{gen_dns} ){
	if ( $argv{status} ne 'Dynamic' && $argv{status} ne 'Static' ){
	    $self->throw_user("DNS records can only be auto-generated for Dynamic or Static IPs");
	}
	my $fzone = Zone->retrieve($argv{fzone}) || $self->forward_zone;
	$logger->info("Ipblock::add_range: Generating DNS records: $argv{start} - $argv{end}");
	$range_dns_plugin->generate_records(prefix=>$argv{name_prefix}, 
					    suffix=>$argv{name_suffix}, 
					    ip_list=>\@newips,
					    fzone=>$fzone);
    }
    
    $logger->info("Ipblock::add_range: Did $argv{status} range: $argv{start} - $argv{end}");    
    return \@newips;
}

################################################################

=head2 remove_range - Remove a range of addresses
    
  Arguments: 
    Hash with following keys:
      start   - First IP in range
      end     - Last IP in range
  Returns:   
    True
  Examples:
    $ipb->remove_range(start=>$addr1, end=>addr2);
=cut

sub remove_range{
    my ($self, %argv) = @_;
    $self->isa_object_method('remove_range');

    my $ipstart  = NetAddr::IP->new($argv{start}, $self->prefix);
    my $ipend    = NetAddr::IP->new($argv{end},   $self->prefix);
    unless ( $ipstart && $ipend && ($ipstart <= $ipend) ){
	$self->throw_user("Invalid range: $argv{start} - $argv{end}");
    }
    my $np = $self->netaddr();
    unless ( $ipstart->within($np) && $ipend->within($np) ){
	$self->throw_user("Start and/or end IPs not within this subnet: ".$self->get_label);
    }
    my $prefix  = ($self->version == 4)? 32 : 128;
    for ( my($ip) = $ipstart->copy; $ip <= $ipend; $ip++ ){
	my $ipb = Ipblock->search(address=>$ip->ip, prefix=>$prefix)->first;
	$ipb->delete() if $ipb;
	# See add_range() about this next line
	last if $ip == $ipstart->broadcast;
    }
    $logger->info("Ipblock::remove_range: done with $argv{start} - $argv{end}");
    1;    
}

##################################################################

=head2 matches_cidr - Does the given string match an IPv4 or IPv6 CIDR address

 Arguments: 
    string
 Returns:   
    Array containing address and prefix length, or 0 if no match
 Examples:
    Ipblock->matches_cidr('192.168.1.0/16');

=cut

sub matches_cidr {
    my ($class, $string) = @_;

    if ( $string =~ /^(.+)\/(\d+)$/ ){
	my ($addr, $prefix) = ($1, $2);
	return 0 if $prefix > 128;
	if ($prefix > 32) {
	    if ( $class->matches_v6($addr) ){
		return ($addr, $prefix);
	    }
	} else {
	    if ( $class->matches_ip($addr) ){
		return ($addr, $prefix);
	    }
	}
    }
    return 0;
}

##################################################################

=head2 matches_ip - Does the given string match an IPv4 or IPv6 address

 Arguments: 
    string
 Returns:   
    1 or 0
 Examples:
    Ipblock->matches_ip('192.168.1.0');

=cut

sub matches_ip {
    my ($class, $string) = @_;

    if ( defined $string && ($class->matches_v4($string) || 
			     $class->matches_v6($string)) ){
	return 1;
    }
    return 0;
}


##################################################################

=head2 matches_v4 - Does the given string match an IPv4 address

 Arguments: 
    string
 Returns:   
    1 or 0
 Examples:
    Ipblock->matches_v4('192.168.1.0');

=cut

sub matches_v4 {
    my ($class, $string) = @_;

    if ( defined $string && $string =~ /^$IPV4$/o ) {
	return 1;
    }
    return 0;
}
##################################################################

=head2 matches_v6 - Does the given string match an IPv6 address

 Arguments: 
    string
 Returns:   
    1 or 0
 Examples:
    Ipblock->matches_v6('192.168.1.0');

=cut

sub matches_v6 {
    my ($class, $string) = @_;

    if ( defined $string && $string =~ /^$IPV6$/o ) {
	return 1;
    }
    return 0;
}

############################################################################

=head2 - objectify - Convert to object as needed

  Args: 
    id, address or object
  Returns: 
    Ipblock object
  Examples:
    my $ipb = Ipblock->objectify($zonestr);

=cut

sub objectify{
    my ($class, $b) = @_;
    if ( (ref($b) =~ /Ipblock/) ){
	return $b;
    }elsif ( $b =~ /\D/ ){
	return Ipblock->search(address=>$b)->first;
    }else{
	# Must be an ID
	return Ipblock->retrieve($b);
    }
}

=head1 INSTANCE METHODS
=cut

##################################################################

=head2 address_numeric - Return IP address in decimal

    Addresses are stored in decimal format in the DB, and converted
    automatically to and from their string representations by triggers.
    Sometimes, it is desirable to work with the decimal format of the
    address.  We need to talk directly to the DB to override the triggers.

  Arguments:
    None
  Returns:
    decimal integer
  Examples:
    my $number = $ipblock->address_numeric();

=cut

sub address_numeric {
    my $self = shift;
    $self->isa_object_method('address_numeric');
    return ($self->netaddr->numeric)[0];
}

##################################################################

=head2 cidr - Return CIDR version of the address

    Returns the address in CIDR notation:
           
               192.168.0.1/32

  Arguments:
    None
  Returns:
    string
  Examples:
    print $ipblock->cidr();

=cut

sub cidr {
    my $self = shift;
    return $self->addr;
}

##################################################################

=head2 full_address

    Returns the address part in FULL notation for IPv6. 
    For IPv4, it returns the standard dotted-quad string.

  Arguments:
    None
  Returns:
    string
  Examples:
    print $ipblock->full_address();

=cut

sub full_address {
    my $self = shift;
    $self->isa_object_method('full_address');
    if ( $self->version == 6 ){
	return $self->netaddr->full();
    }else{
	return $self->address;
    }
}

##################################################################

=head2 get_label - Override get_label method

    Returns the address in CIDR notation if it is a net address:
    
      192.168.0.0/24

    or a plain dotted-quad if it is a host address:
    
      192.168.0.1

  Arguments:
    None
  Returns:
    string
  Examples:
    print $ipblock->get_label();

=cut

sub get_label {
    my $self = shift;
    return $self->address if $self->is_address;
    return $self->cidr;
}

##################################################################

=head2 is_address - Is this a host address?  

    Host addresses are v4 blocks with a /32 prefix or v6 blocks with a /128 prefix
    
 Arguments: 
    None
 Returns:   
    1 if block is an address, 0 otherwise

=cut

sub is_address {
    my $self = shift;
    $self->isa_object_method('is_address');

    return unless ($self->version && $self->prefix);

    if ( ($self->version == 4 && $self->prefix == 32) 
	 || ($self->version == 6 && $self->prefix == 128) ){
	return 1; 
    }else{
	return 0;
    }
}

##################################################################

=head2 update - Update an Ipblock object in DB

    Modify given fields of an Ipblock and (optionally) all its descendants.

    If recursive flag is on, passed fields must not:
       - be subject to validation, 
       - require that the address space tree be rebuilt 
       - be specific to one block

  Arguments:
    hashref of key/value pairs
  Modified:
    status           object, id or name of IpblockStatus
    validate(flag)   Optionally skip validation step
    recursive(flag)  Update all descendants
  Returns: 
    When recursive, true if successsful. Otherwise, see Class::DBI update()
  Examples:
    $ipblock->update({field1=>value1, field2=>value2, recursive=>1});

=cut

sub update {
    my ($self, $argv) = @_;
    $self->isa_object_method('update');
    my $class = ref($self);

    # Extract non-column options from $argv
    my $validate  = 1;
    if ( defined $argv->{validate} ){
	$validate = $argv->{validate};
	delete $argv->{validate};
    }

    my $no_update_tree = $argv->{no_update_tree};
    delete $argv->{no_update_tree};
    $validate = 0 if $no_update_tree;  # updated tree is a requisite for validation

    my $recursive = delete $argv->{recursive};

    # We need at least these args before proceeding
    # If not passed, use current values
    $argv->{status} ||= $self->status;
    $argv->{prefix} = $self->prefix unless defined $argv->{prefix};

    if ( defined $argv->{address} && defined $argv->{prefix} ){
	my $ip = $class->_prevalidate($argv->{address}, $argv->{prefix});
	if ( my $tmp = $class->search(address => $ip->ip,
				      prefix  => $ip->masklen)->first ){
	    $self->throw_user("Block ".$argv->{address}."/".$argv->{prefix}." already exists in db")
		if ( $tmp->id != $self->id );
	}
    }

    my %state = %$argv;
    if ($argv->{address}) {
	$state{addr} = "$argv->{address}/$argv->{prefix}";
    } else {
	$state{addr} = $self->address . "/$argv->{prefix}";
    }
    delete $state{address};
    delete $state{prefix};
    $state{status} = $self->_get_status_id($argv->{status});

    # We might need to discard changes.
    # Class::DBI's 'discard_changes' method won't work
    # here because object is changed in the DB
    # (and not in memory) when IP tree is rebuilt.
    #
    # Notice that this would be the perfect place to use DB transactions
    # but the way we do transactions, they cannot be nested, and this
    # method is pretty low level

    my %bak    = $self->get_state();
    my $result = $self->SUPER::update(\%state);

    # This makes sure we have the latest values
    $self = $class->retrieve($self->id);

    # Now check for rules
    # We do it after updating and rebuilding the tree because 
    # it makes things much simpler. Workarounds welcome.
    if ( $validate && ($argv->{address} || $argv->{prefix} || $argv->{status}) ){
	# If this fails, We need to roll back the object before bailing out
	eval { 
	    $self->_validate($argv) ;
	};
	if ( my $e = $@ ){
	    # Go back to where we were
	    $self->SUPER::update( \%bak );
	    $e->rethrow();
	}
    }

    # Update DHCP scope if needed
    if ( $self->dhcp_scopes ){
	if ( $self->addr ne $bak{addr} ){
	    my $scope = ($self->dhcp_scopes)[0];
	    $scope->update({ipblock=>$self});
	}
	if ( $bak{status} != $self->status ){
	    if ( $self->status->name ne 'Subnet' ){
		$self->throw_user("Subnet cannot change status while DHCP scope exists");
	    }
	}
    }

    # Update PTR records if needed
    if ( $self->addr ne $bak{addr} ){
	my $name = RRPTR->get_name(ipblock=>$self);
	foreach my $pr ( $self->ptr_records ){
	    my $rr = $pr->rr;
	    my $domain = $rr->zone->name;
	    $name =~ s/\.$domain\.?$//i;
	    $rr->update({name=>$name});
	}
    }

    # Generate hostaudit entry if needed
    if ( $self->parent && $self->parent->dhcp_scopes
	 && ($bak{status}->id != $state{status}) ){
	my $dyn_id = IpblockStatus->search(name=>'Dynamic')->first->id;
	if ( $dyn_id == $bak{status}->id || $dyn_id == $state{status} ){
	    my %args;
	    $args{operation} = 'update';
	    $args{fields} = ('status');
	    $args{values} = ($state{status});
	    $self->_host_audit(%args);
	}
    }
	
    if ( $recursive ){
	my %data;
	# Only these fields are allowed
	foreach my $key ( qw(owner used_by description) ){
	    $data{$key} = $argv->{$key} if exists $argv->{$key};
	}
	if ( %data ){
	    foreach my $d ( @{ $self->get_descendants } ){
		$d->SUPER::update(\%data) ;
	    }
	}
    }

    # If changing into a subnet, reserve addresses if needed
    if ( !$self->is_address && $bak{status} != $self->status ){
	if ( $self->status->name eq 'Subnet' ){
	    $self->reserve_first_n();
	}
    }

    return $result;
}



##################################################################

=head2 delete - Delete Ipblock object

    We override delete to allow deleting children recursively as an option.
    
  Arguments: 
    recursive      - Remove blocks recursively (default is false)
    no_update_tree - Do not update IP tree
   Returns:
    True if successful
  Examples:
    $ipblock->delete(recursive=>1);

=cut

sub delete {
    my ($self, %args) = @_;
    $self->isa_object_method('delete');
    my $class = ref($self);
     
    my %bak = $self->get_state();

    if ( $args{recursive} ){
	foreach my $ch ( $self->children ){
	    $ch->delete(recursive=>1);
	}
    }    

    # Generate hostaudit entry if needed
    if ( blessed($self->parent) && $self->parent->dhcp_scopes ){
	my $dyn_id = IpblockStatus->search(name=>'Dynamic')->first->id;
	if ( $dyn_id == $bak{status}->id ){
	    my %args;
	    $args{operation} = 'delete';
	    $args{fields} = 'all';
	    $args{values} = $self->get_label;
	    $self->_host_audit(%args);
	}
    }

    $self->SUPER::delete();

    return 1;
}
##################################################################

=head2 get_ancestors - Get parents recursively
    
 Arguments: 
    None
 Returns:   
    Array of ancestor Ipblock objects, in order
  Examples:
    my @ancestors = $ip->get_ancestors();

=cut

sub get_ancestors {
    my $self = shift;
    $self->isa_object_method('get_ancestors');

    my %where;

    $where{addr} = { '>>=', $self->addr };
    $where{id}   = { '!=', $self->id };  # skip self from the resultset

    return ref($self)->search_where(\%where, { order_by => "addr DESC" });
}

##################################################################

=head2 get_descendants


 Arguments: 
    Hash with following keys:
      no_addresses  - Do not include end-node addresses
 Returns:   
    Arrayref of Ipblock objects
  Examples:
    my $desc = $block->get_descendants();

=cut

sub get_descendants {
    my ($self, %argv) = @_;
    $self->isa_object_method('get_descendants');

    my %where;

    $where{addr} = { '<<=', $self->addr };
    $where{id}   = { '!=', $self->id };  # skip self from the resultset
    if ($argv{no_addresses}) {
	$where{'masklen(addr)'} = { '!=', $self->version == 4 ? 32 : 128 };
    }

    return [ref($self)->search_where(\%where, { order_by => "addr" })];
}

##################################################################

=head2 num_addr - Return the number of usable addresses in a subnet

 Arguments:
    None
 Returns:
    Integer
  Examples:

=cut

sub num_addr {
    my ($self) = @_;
    $self->isa_object_method('num_addr');
    my $class = ref($self);
    
    my $addr = $self->netaddr;
    if ( $addr->version == 4 ) {
	my $num = $class->numhosts($addr->masklen);
	if ( $addr->masklen < 31 && $self->status->name eq 'Subnet' ){
	    # Subtract network and broadcast addresses
	    $num = $num - 2;
	}
	return $num;
    }elsif ( $addr->version == 6 ) {
	# Notice that the first (subnet-router anycast) and last address 
	# are valid in IPv6
        return $class->numhosts_v6($addr->masklen);
    }
}

##################################################################

=head2 num_children - Count number of children

  Arguments:
    None
  Returns:
    Integer

=cut

sub num_children {
    my ($self) = @_;
    $self->isa_object_method('num_children');

    my $dbh = $self->db_Main;
    my ($num) = $dbh->selectrow_array("SELECT COUNT(id) FROM ipblock
				      WHERE ipblock_parent(id)=?", {},
				      $self->id);
    return $num;
}


##################################################################

=head2 address_usage -  Returns the number of hosts in a given container or subnet

  Arguments:
    None
  Returns:
    integer
  Examples:
    my $count = $ipblock->address_usage();

=cut

sub address_usage {
    my ($self) = @_;
    $self->isa_object_method('address_usage');

    my $count  = 0;
    my $q;
    my $dbh = $self->db_Main;
    eval {
	$q = $dbh->prepare_cached("SELECT masklen(ipblock.addr), family(ipblock.addr), ipblockstatus.name 
                                   FROM   ipblock, ipblockstatus 
                                   WHERE  ipblock.status=ipblockstatus.id 
                                     AND  ? >>= addr");
	
	$q->execute("".$self->netaddr);
    };
    if ( my $e = $@ ){
	$self->throw_fatal( $e );
    }
    
    while ( my ($prefix, $version, $status) = $q->fetchrow_array() ) {
        if( ( $version == 4 && $prefix == 32 ) || ( $version == 6 && $prefix == 128 ) ) {
	    next if $status eq 'Available';
            $count++;
        }
    }

    return $count;
}

##################################################################

=head2 free_space - The free space in this ipblock

  Arguments:
    Maximum block size to partition space into
  Returns:
    an array (possibly empty) of Netaddr::IP objects that fill in all the
    un-subnetted nooks and crannies of this IPblock
  Examples:
    my @freespace = sort $network->free_space;
=cut

sub free_space {
    my ($self, $divide) = @_;
    $self->isa_object_method('free_space');
    my $class = ref($self);

    sub _find_first_one {
        my $num = shift;
        if ($num & 1 || $num == 0) { 
            return 0; 
        } else { 
            return 1 + &_find_first_one($num >> 1); 
        }
    }

    sub _fill { 
        # Fill from the given address to the beginning of the given netblock
        # The block will INCLUDE the first address and EXCLUDE the final block
        my ($class, $from, $to, $divide, $version) = @_;

        if ( $from->within($to) || $from->numeric >= $to->numeric ) {  
            # Base case
            return ();
        }
        
        # The first argument needs to be an address and not a subnet.
        my $curr_addr = $from->numeric;
        my $max_masklen = $from->masklen;
        my $numbits = &_find_first_one($curr_addr);

        my $mask = $max_masklen - $numbits;
        $mask = $divide if ( $divide && $divide =~ /\d+/ && $divide > $mask && 
			     ( ( $from->version == 4 && $divide <= 32 ) 
			       || ( $from->version == 6 && $divide <= 128 ) ) );

        my $subnet = $class->netaddr(address=>$curr_addr, prefix=>$mask, 
				     version=>$version);
        while ( $subnet->contains($to) ) {
            $subnet = $class->netaddr(address=>$curr_addr, prefix=>++$mask, 
				      version=>$version);
        }
	
        my $newfrom = $class->netaddr(
	    address=>$subnet->broadcast->numeric + 1,
	    prefix=>$max_masklen,
	    version=>$version,
            );
	
        return ($subnet, &_fill($class, $newfrom, $to, $divide, $version));
    }

    my @kids = map { $_->netaddr } $self->children;
    my $curr = $self->netaddr->numeric;
    my @freespace = ();
    foreach my $kid (sort { $a->numeric <=> $b->numeric } @kids) {
	unless ( $kid->numeric >= $curr ){
	    #$class->build_tree($self->version);
	    next;
	}
        my $curr_nip = $class->netaddr(address=>$curr, version=>$self->version);
	if ( !$kid->contains($curr_nip) ){
	    foreach my $space (&_fill($class, $curr_nip, $kid, $divide, $self->version)) {
		push @freespace, $space;
	    }
	}
        $curr = $kid->broadcast->numeric + 1;
    }

    my $end = $class->netaddr(address=>$self->netaddr->broadcast->numeric + 1, version=>$self->version);
    my $curr_nip = $class->netaddr(address=>$curr, version=>$self->version);
    map { push @freespace, $_ } &_fill($class, $curr_nip, $end, $divide, $self->version);

    return @freespace;
}

##################################################################

=head2 subnet_usage - Number of hosts covered by subnets in a container

  Arguments:
    None
  Returns:
    integer
  Examples:

=cut

sub subnet_usage {
    my $self = shift;
    $self->isa_object_method('subnet_usage');
    my $class = ref($self);

    $self->throw_user("Call subnet_usage only for Container blocks")
	if ($self->status->name ne 'Container');

    my $count = new Math::BigInt(0);
    my $dbh   = $self->db_Main;
    my $q;
    eval {
	# must not be a host, and must be "reserved" or "subnet" to count towards usage
	$q = $dbh->prepare_cached("
	    SELECT family(addr), masklen(addr)
	    FROM ipblock, ipblockstatus
	    WHERE
		ipblock.status=ipblockstatus.id AND
		? >>= addr AND
		NOT (family(addr) = 4 AND masklen(addr) = 32) AND
		NOT (family(addr) = 6 AND masklen(addr) = 128) AND
		(ipblockstatus.name = 'Reserved' OR
		 ipblockstatus.name = 'Subnet')
	");
	$q->execute($self->addr);
    };
    if ( my $e = $@ ){
	$self->throw_fatal( $e );
    }
    while ( my ($version, $prefix) = $q->fetchrow_array() ) {
	if ( $version == 4 ) {
	    $count += $class->numhosts($prefix);
	} elsif ( $version == 6 ) {
	    $count += $class->numhosts_v6($prefix);
	}
    }
    return $count;
}

############################################################################

=head2 update_a_records -  Update DNS A record(s) for this ip 

    Creates or updates DNS records based on the output of configured plugin,
    which can, for example, derive the names from device/interface information.
    
  Arguments:
    Hash with following keys:
       hostname_ips   - arrayref of ip addresses to which main hostname resolves to
       num_ips        - Number of IPs in Device
  Returns:
    True if successful
  Example:
    $self->update_a_records(hostname_ips=>\@ips, num_ips=>$num);

=cut

sub update_a_records {
    my ($self, %argv) = @_;
    $self->isa_object_method('update_a_records');
    
    $self->throw_fatal("Ipblock::update_a_records: Missing required arguments")
	unless ( $argv{hostname_ips} && $argv{num_ips} );
    
    my %hostnameips;
    map { $hostnameips{$_}++ } @{$argv{hostname_ips}};

    unless ( $self->interface && $self->interface->device ){
	# No reason to go further
	$self->throw_fatal(sprintf('update_a_records: Address %s not associated with any Device', 
			   $self->address));
    } 

    unless ( $self->interface->auto_dns ){
	$logger->debug(sprintf("Interface %s configured for no auto DNS", 
			      $self->interface->get_label));
	return;
    }
    
    my $device = $self->interface->device;
    my $host = $device->fqdn;
    
    # This shouldn't happen
    $self->throw_fatal( sprintf("update_a_records: Device id %d is missing its name!", $device->id) )
	unless $device->name;

    # Only generate names for IP blocks that are mapped to a zone
    my $zone;
    unless ( $zone = $self->forward_zone ){
	$logger->debug(sprintf("%s: Cannot determine forward DNS zone for IP: %s", 
			       $host, $self->get_label));
	return;
	
    }

    # Determine what DNS name this IP will have.
    # We delegate this logic to an external plugin to
    # give admin more flexibility
    my $name = $ip_name_plugin->get_name( $self );

    my @a_records = $self->a_records;

    my %rrstate = (name=>$name, zone=>$zone, auto_update=>1);

    if ( ! @a_records  ){
	# No A records exist for this IP yet.

	# Is this the only ip in this device,
	# or is this the address associated with the hostname?
	if ( exists $hostnameips{$self->address} ){

	    # We should already have an RR created (via Device::assign_name)
	    # Create the A record to link that RR with this Ipobject
	    RRADDR->insert( {rr => $device->name, ipblock => $self} );
	    $logger->info(sprintf("%s: Inserted DNS A record for main device IP %s: %s", 
				  $host, $self->address, $device->name->name));
	}else{
	    # This ip is not associated with the Device name.
	    # Insert and/or assign necessary records
	    my $rr;
	    if ( $rr = RR->search(name=>$name, zone=>$zone)->first ){
		$logger->debug(sub{ sprintf("Ipblock::update_a_records: %s: Name %s: %s already exists.", 
					    $host, $self->address, $name) });
	    }else{
		# Create name first
		$rr = RR->insert(\%rrstate);
	    }
	    # And now A record
	    RRADDR->insert({rr => $rr, ipblock => $self});
	    $logger->info( sprintf("%s: Inserted DNS A record for %s: %s", 
				   $host, $self->address, $name) );
	}
    }else{ 
	# "A" records exist.  Update names
	if ( (scalar @a_records) > 1 ){
	    # There's more than one A record for this IP
	    # To avoid confusion, don't update and log.
	    $logger->warn(sprintf("%s: IP %s has more than one A record. Will not update name.", 
				  $host, $self->address));
	}else{
	    my $ar = $a_records[0];
	    my $rr = $ar->rr;

	    # User might not want this updated
	    if ( $rr->auto_update ){

		# If this is the only IP, or the snmp_target IP, make sure that it uses 
		# the same record that the device uses as its main name
		if ( $argv{num_ips} == 1 ||
		     ($self->interface->device->snmp_target &&
		      $self->interface->device->snmp_target->id == $self->id) ){
		    
		    if ( $rr->id != $self->interface->device->name->id ){
			$ar->delete;
			RRADDR->insert({rr=>$device->name, ipblock=>$self});
			$logger->info(sprintf("%s: Updated DNS A record for main device IP %s: %s", 
					      $host, $self->address, $device->name->name));
		    }
		}else{
		    # We won't update the RR for the IP that the 
		    # device name points to
		    if ( !exists $hostnameips{$self->address} ){
			# Check if the name already exists
			my $other;
			if ( $other = RR->search(name=>$name, zone=>$zone)->first ){
			    if ( $other->id != $rr->id ){
				# This means we need to assign the other
				# name to this IP, not update the current name
				$ar->update({rr=>$other});
				$logger->debug(sub{ sprintf("%s: Assigned existing name %s to %s", 
							    $host, $name, $self->address)} );
				
				# And get rid of the old name
				$rr->delete() unless $rr->a_records;
			    }
			}else{
			    # The desired name does not exist
			    # Now, is pointing to the main name?
			    if ( $rr->id == $device->name->id ) {
				# In that case we have to create a different name
				my $newrr = RR->insert(\%rrstate);
				
				# And link it with this IP
				$ar->update({rr=>$newrr});
				$logger->info( sprintf("%s: Updated DNS record for %s: %s", 
						       $host, $self->address, $name) );
			    }else{
				# Just update the current name, then
				$rr->update(\%rrstate);
				$logger->debug(sub{ sprintf("%s: Updated DNS record for %s: %s", 
							    $host, $self->address, $name) });
			    }
			}
		    }
		}
	    }
	}
    }

    return 1;
}

#################################################################

=head2 ip2int - Convert IP(v4/v6) address string into its decimal value

 Arguments: 
    address string
 Returns:   
    integer (decimal value of IP address)
  Examples:
    my $integer_addr = Ipblock->ip2int('192.168.0.1');

=cut

sub ip2int {
    my ($self, $address) = @_;
    my $ipobj;
    
    # Transform RFC2317 format to a real IP
    if ( $address =~/^(.+)-(\d+)/ ) {
	$address = $1;
    }

    unless ( $ipobj = NetAddr::IP->new($address) ){
	$self->throw_user("Invalid IP address: $address");
    }
    return ($ipobj->numeric)[0];
}


#################################################################

=head2 validate - Basic validation of IP address

 Arguments: 
    address
    prefix (optional)
 Returns:   
    True or False
  Examples:
    if ( Ipblock->validate($address) ){ } 

=cut

sub validate {
    my ($self, $address, $prefix) = @_;
    
    # Transform RFC2317 format to a real ip
    if ( $address =~/^(.+)-(\d+)/ ) {
	$address = $1;
    }
    
    eval {
	$self->_prevalidate($address, $prefix);
    };
    if ( my $e = $@ ){
	return 0;
    }
    return 1;
}

##################################################################

=head2 get_devices - Get all devices with IPs within this block

  Arguments:
    None
  Returns: 
    Arrayref of device objects
  Examples:
    my $devs = $subnet->get_devices();

=cut

sub get_devices {
    my ($self) = @_;
    $self->isa_object_method('get_devices');
    
    my %devs;
    foreach my $ch ( $self->children ){
	if ( $ch->is_address ){
	    if ( $ch->interface && $ch->interface->device ){
		my $dev = $ch->interface->device;
		$devs{$dev->id} = $dev;
	    }
	}else{
	    my $ldevs = $ch->get_devices();
	    foreach my $dev ( @$ldevs ){
		$devs{$dev->id} = $dev;
	    }
	}
    }
    my @devs = values %devs;
    return \@devs;
}


################################################################

=head2 get_last_n_arp - Get last N ARP entries

  Arguments: 
    limit  - Return N last entries (default: 10)
  Returns:   
    Array ref of timestamps, PhysAddr IDs and Interface IDs
  Examples:
    print $ip->get_last_n_arp(10);

=cut

sub get_last_n_arp {
    my ($self, $limit) = @_;
    $self->isa_object_method('get_last_n_arp');
	
    my $dbh = $self->db_Main();
    my $id = $self->id;
    my $q1 = "SELECT   arp.tstamp
              FROM     interface i, arpcacheentry arpe, arpcache arp, ipblock ip
              WHERE    ip.id=$id
                AND    arpe.interface=i.id 
                AND    arpe.ipaddr=ip.id 
                AND    arpe.arpcache=arp.id 
              GROUP BY arp.tstamp 
              ORDER BY arp.tstamp DESC
              LIMIT $limit";

    my @tstamps = @{ $dbh->selectall_arrayref($q1) };
    return unless @tstamps;
    my $tstamps = join ',', map { "'$_'" } map { $_->[0] } @tstamps;

    my $q2 = "SELECT   i.id, p.id, arp.tstamp
              FROM     physaddr p, interface i, arpcacheentry arpe, arpcache arp, ipblock ip
              WHERE    ip.id=$id 
                AND    arpe.physaddr=p.id 
                AND    arpe.interface=i.id 
                AND    arpe.ipaddr=ip.id 
                AND    arpe.arpcache=arp.id 
                AND    arp.tstamp IN($tstamps)
              ORDER BY arp.tstamp DESC";

    return $dbh->selectall_arrayref($q2);
}

################################################################

=head2 get_last_arp_mac - Get latest MAC using this IP from ARP

  Arguments: 
    None
  Returns:   
    PhysAddr object if successful
  Examples:
    my $mac = $ipb->get_last_arp_mac();

=cut

sub get_last_arp_mac {
    my ($self) = @_;
    $self->isa_object_method('get_last_arp_mac');
    
    if ( my $arp = $self->get_last_n_arp(1) ){
        my $row = shift @$arp;
	my ($iid, $macid, $tstamp) = @$row;
	my $mac = PhysAddr->retrieve($macid);
	return $mac if defined $mac;
    }
}

################################################################

=head2 shared_network_subnets

    Determine if this subnet shares a physical link with another
    subnet based on router interfaces with multiple subnet addresses.

  Arguments: 
    None
  Returns:   
    Array of Ipblock objects or undef if not sharing a link
  Examples:
    my @shared = $subnet->shared_network_subnets();
=cut

sub shared_network_subnets{
    my ($self, %argv) = @_;
    $self->isa_object_method('shared_network_subnets');

    my $phrase = "id != ? and id in
	(select ipblock_parent(id) from ipblock where interface in
	    (select  distinct(interface) from ipblock where
		ipblock_parent(id) = ? and
		interface is not null and
		interface != 0))
	and family(addr) = ? and
	status in (select id from ipblockstatus where name = 'Subnet')";

    return ref($self)->retrieve_from_sql($phrase,
    	$self->id, $self->id, $self->version);
}

################################################################

=head2 enable_dhcp
    
    Create a subnet dhcp scope and assign given attributes.
    This method will create a shared-network scope if necessary.

  Arguments: 
    Hash containing the following key/value pairs:
      container       - Container (probably global) Scope
      attributes      - Optional.  This must be a hashref with:
                          key   = attribute name, 
                          value = attribute value
      active          - Whether it should be exported or not
 
  Returns:   
    Scope object (subnet or shared-network)
  Examples:
    $subnet->enable_dhcp(%options);

=cut

sub enable_dhcp{
    my ($self, %argv) = @_;
    $self->isa_object_method('enable_dhcp');
    
    $self->throw_user("Missing required arguments: container")
	unless (defined $argv{container});

    $self->throw_user("Trying to enable DHCP on a non-subnet block")
	if ( $self->status->name ne 'Subnet' );
    
    my %args = (container  => $argv{container},
		active     => $argv{active},
		attributes => $argv{attributes},
		type       =>'subnet', 
		ipblock    => $self,
	);
    my $scope = DhcpScope->insert(\%args);

    if ( my @shared = $self->shared_network_subnets ){
	# Create or update a shared-network scope

	my %shared_subnets;
	my %to_delete;
	my %shared_attributes;
	
	foreach my $s ( @shared ){
	    if ( my $o_scope = $s->dhcp_scopes->first ){
		# We'll only deal with the other subnet if dhcp 
		# is enabled within the same global scope
		if ( $o_scope->type->name eq 'subnet' && 
		     $o_scope->get_global->id == $scope->get_global->id ){
		    $shared_subnets{$s->id} = $s;
		    my $o_container = $o_scope->container;
		    if ( $o_container->type->name eq 'shared-network' ){
			# This subnet is already within a shared-network scope
			# We'll try to keep its attributes to add to a new scope
			# then we'll delete the current shared-network
			map { $shared_attributes{$_->name->name} = 
				  $_->value } $o_container->attributes;
			$to_delete{$o_container->id} = $o_container;
		    }
		}
	    }
	}
	if ( my @shared_subnets = values(%shared_subnets) ){
	    
	    push @shared_subnets, $self;
	    
	    # Create the shared-network scope
	    my $sn_scope;
	    $sn_scope = DhcpScope->insert({type       => 'shared-network',
					   subnets    => \@shared_subnets,
					   attributes => \%shared_attributes,
					   container  => $argv{container}});
	    $scope = $sn_scope;
	    
	    # Finally, delete the old shared-networks
	    foreach my $sn ( values %to_delete ){
		$sn->delete();
	    }
	}
    }
    return $scope;
}

################################################################

=head2 get_dynamic_ranges - List of dynamic ip address ranges for a given subnet
    
    Used by DHCPD configs

  Arguments: 
    None
  Returns:   
    Array of strings (e.g. "192.168.0.10 192.168.0.20")
  Examples:
    my @ranges = $subnet->get_dynamic_ranges();
=cut

sub get_dynamic_ranges {
    my ($self) = @_;
    $self->isa_object_method('get_dynamic_ranges');
    
    $self->throw_fatal("Ipblock::get_dynamic_ranges: Invalid call to this method on a non-subnet")
	if ( $self->status->name ne 'Subnet' );
    
    my $id        = $self->id;
    my $version   = $self->version;
    my $dbh = $self->db_Main;
    my $rows = $dbh->selectall_arrayref("
                SELECT   host(ipblock.addr)
                 FROM    ipblock,ipblockstatus
                WHERE    ipblock.parent=$id 
                     AND ipblock.status=ipblockstatus.id
                     AND ipblockstatus.name='Dynamic'
                ORDER BY ipblock.addr
	");
    my @ips = map { $_->[0] } @$rows;

    my @ranges;
    my ($start, $end, $pos);
    $start = shift @ips;
    $end   = $start;
    foreach my $address ( @ips ){
	if ( $address != $end+1 ){
	    my $sa = Ipblock->int2ip($start, $version);
	    my $ea = Ipblock->int2ip($end, $version);
	    push @ranges, "$sa $ea";
	    $start = $address;
	}
	$end = $address;
    }
    if ( $start && $end ){
	my $sa = Ipblock->int2ip($start, $version);
	my $ea = Ipblock->int2ip($end, $version);
	push @ranges, "$sa $ea";
    }

    return @ranges if scalar @ranges;
    return;
}

################################################################

=head2 dns_zones - Get DNS zones related to this block
    
    If this block does not have zones assigned via the SubnetZone
    join table, this method checks this block's ancestors
    and returns the first set of matching zones

  Arguments: 
    None
  Returns:   
    Array of Zone objects
  Examples:
    my @zones = $ipblock->dns_zones;
=cut

sub dns_zones {
    my ($self) = @_;
    $self->isa_object_method('dns_zones');
    my @szones = $self->zones;
    unless ( @szones ){
	foreach my $p ( $self->get_ancestors ){
	    if ( @szones = $p->zones ){
		last;
	    }
	}
    }
    if ( @szones ){
	return map { $_->zone } @szones;
    }
    return;
}

################################################################

=head2 forward_zone - Find the forward zone for this ip or block
    
  Arguments: 
    None
  Returns:   
    Zone object or array of zone objects, depending on context
  Examples:
    my $zone = $ipb->forward_zone();
    my @zones = $ibp->forward_zone();
=cut

sub forward_zone {
    my ($self) = @_;
    $self->isa_object_method('forward_zone');

    my @list;
    if ( my @zones = $self->dns_zones ){
	foreach my $z ( @zones ){
	    if ( $z->name !~ /\.arpa$|\.int$/ ){
		push @list, $z;
	    }
	}
    }
    wantarray ? ( @list ) : $list[0];
}

################################################################

=head2 reverse_zone - Find the in-addr.arpa zone for this ip or block
    
  Arguments: 
    None
  Returns:   
    Zone object
  Examples:
    my $r_zone = $ipb->reverse_zone();
=cut

sub reverse_zone {
    my ($self) = @_;
    $self->isa_object_method('reverse_zone');

    my $rname = RRPTR->get_name(ipblock=>$self);
    my @zones = Zone->search(name=>$rname);
    return $zones[0];
}

############################################################################

=head2 - get_dot_arpa_names

    Return the corresponding in-addr.arpa or ip6.arpa zone names 
    Supports RFC2317 (Classless IN-ADDR.ARPA delegation) notation

  Args: 
    delim (optional) - Delimiter to separate address and mask in RFC2317 cases
  Returns: 
    Array of strings
  Examples:
    my $name = $block->get_dot_arpa_names()

=cut

sub get_dot_arpa_names {
    my ($self, %argv) = @_;
    $self->isa_object_method('get_dot_arpa_names');
    my $delim = $argv{delim} || '-';
    my @names;
    if ( $self->version == 4 ){
	if ( 0 < $self->prefix && $self->prefix <= 8 ){
	    my @subnets = $self->netaddr->split(8);
	    foreach my $subnet ( @subnets ){
		push @names, (split(/\./, $subnet->addr))[0];
	    }

	}elsif ( $self->prefix <= 16 ){
	    my @subnets = $self->netaddr->split(16);
	    foreach my $subnet ( @subnets ){
		push @names, join('.', reverse((split(/\./, $subnet->addr))[0..1]));
	    }	    

	}elsif ( $self->prefix <= 24 ){
	    my @subnets = $self->netaddr->split(24);
	    foreach my $subnet ( @subnets ){
		push @names, join('.', reverse((split(/\./, $subnet->addr))[0..2]));
	    }	    

	}elsif ( $self->prefix < 32 ){
	    # RFC 2317 case
	    my @octets = split('\.', $self->address);
	    push @names, $octets[3].$delim.$self->prefix.".$octets[2].$octets[1].$octets[0]";

	}else {
	    $self->throw_user('Unexpected prefix length:'.$self->prefix);
	}
	map { $_ .= '.in-addr.arpa' } @names;

    }elsif ( $self->version == 6 ){
	if ( my $rem = $self->prefix % 4 ){
	    # prefix is not a multiple of four
	    my $split_size = $self->prefix - $rem + 4;
	    my @subnets = $self->netaddr->split($split_size);
	    foreach my $subnet ( @subnets ){
		push @names, &_get_v6_arpa($subnet);
	    }
	}else{
	    push @names, &_get_v6_arpa($self->netaddr);
	}
    }

    sub _get_v6_arpa {
	my ($netaddr) = @_;
	my $name = $netaddr->full();
	$name =~ s/://g;
	my @nibbles = split(//, $name);
	@nibbles = @nibbles[0..($netaddr->masklen/4)-1];
	$name = join('.', reverse @nibbles);
	return lc("$name.ip6.arpa");
    }
    return @names;
}

##################################################################

=head2 get_host_addrs - Get host addresses for a given block

  Note: This returns the list of possible host addresses in any 
    given IP block, not from the database.

  Arguments:
    Subnet address in CIDR notation (not required if called on an object)
  Returns: 
    Arrayref of host addresses (strings)
  Examples:
    Class method:
      my $hosts = Ipblock->get_host_addrs( $address );
    Instance method:
      my $hosts = $subnet->get_host_addrs();

=cut

sub get_host_addrs {
    my ($self) = shift;
    my $class = ref($self);
    my $subnet;
    my $nip;
    if ( $class ){
	$subnet = $self->cidr;
	$nip = $self->netaddr;
    }else{
	$class = $self;
	$subnet = shift;
	my ($address, $prefix) = split /\//, $subnet;
	$nip = Ipblock->netaddr(address=>$address, prefix=>$prefix) or
	    $self->throw_fatal("Invalid Subnet: $subnet");
    }
        
    # Populating an array with all addresses in most IPv6 blocks
    # will likely break
    if ( $nip->version != 4 ){
	$class->throw_user('This method only supports IPv4 blocks');
    }
    my $hosts = $nip->hostenumref();

    # Remove the prefix.  We just want the addresses
    map { $_ =~ s/(.*)\/\d{2}/$1/ } @$hosts;

    return $hosts;
}

################################################################

=head2 get_next_free - Get next free address in this subnet

  Arguments: 
    Hash with following keys:
      strategy (first|last)
  Returns:   
    Address string or undef if none available
  Examples:
    my $address = $subnet->get_next_free()
=cut

sub get_next_free {
    my ($self, %argv) = @_;
    $self->isa_object_method('get_next_free');
    my $class = ref($self);
    $self->throw_user('Invalid call to this method on a non-subnet')
	unless ( $self->status->name eq 'Subnet' );

    # Build hash with address and status for fast lookup
    my %used;
    foreach my $kid ( $self->children ){
	$used{$kid->netaddr->ip} = $kid->status->name;
    }

    my $strategy = $argv{strategy} || Netdot->config->get('IP_ALLOCATION_STRATEGY');

    my $s = $self->netaddr;

    my ($addr, $limit, $increment);

    if ( $strategy eq 'first' ){
	$addr      = $s->first;
	$limit     = $s->last;
	$increment = 1;
    }elsif ( $strategy eq 'last' ){
	$addr      = $s->last;
	$limit     = $s->first;
	$increment = -1;
    }else{
	$self->throw_fatal("Ipblock::get_next_free: Invalid strategy: $strategy");
    }

    while ($addr != $limit) {
	my $ip = $addr->ip;
	$addr += $increment;
	return $ip unless $used{$ip};
	next if $used{$ip} ne 'Available';
	my $existing = Ipblock->search(address => $ip)->first;
	return $ip unless $existing;
	if ($existing->a_records || $existing->dhcp_scopes) {
	    $existing->SUPER::update({status => 'Static'});
	    next;
	}
	return $ip;
    }
}

##################################################################

=head2 get_addresses_by - Different sorts for ipblock_list page

   Arguments: 
     sort field (Address|Name|Status|Used by|Description|Last Seen)
  Returns:   
    array of Ipblocks
  Examples:
    my @rows = $subnet->get_addresses_by('Description')

=cut

sub get_addresses_by {
    my ($self, $sort) = @_;
    $self->isa_object_method('get_addresses_by');
    $self->throw_fatal("Ipblock::get_addresses_by: Invalid call to this method for a non-subnet")
	unless ( $self->status && $self->status->name eq 'Subnet' );
    
    $sort ||= 'Address';
    my %sort2field = ('Address'     => 'ipblock.addr',
		      'Name'        => 'rr.name',
		      'Status'      => 'ipblockstatus.name',
		      'Used by'     => 'entity.name',
		      'Description' => 'ipblock.description',
		      'Last Seen'   => 'ipblock.last_seen',
	);
    unless ( exists $sort2field{$sort} ){
	$self->throw_fatal("Ipblock::get_addresses_by: Invalid sort string");
    }
    my $id = $self->id;
    my $query = "    
    SELECT    ipblock.id
    FROM      ipblockstatus, ipblock 
    LEFT JOIN (rraddr CROSS JOIN rr) ON (rraddr.ipblock=ipblock.id AND rraddr.rr=rr.id)
    LEFT JOIN entity ON (ipblock.used_by=entity.id)
    WHERE     ipblock_parent(ipblock.id)=$id
      AND     ipblock.status=ipblockstatus.id ";
    if ( ($self->version == 6) && ($self->config->get('IPV6_HIDE_DISCOVERED')) ) {
       $query.=" AND     ipblockstatus.name != \"Discovered\" ";
    }
    $query .= "ORDER BY  $sort2field{$sort}";

    my $dbh  = $self->db_Main();
    my $rows = $dbh->selectall_arrayref($query);
    return map { Ipblock->retrieve($_->[0]) } @$rows;
}

##################################################################

=head2 netaddr
    
    Create NetAddr::IP object

  Arguments:
    address & prefix, unless called as instance method
    prefix will default to host prefix if not specified
  Returns:
    NetAddr::IP object
  Examples:
    print $ipblock->netaddr->broadcast();
    print Ipblock->netaddr(address=>$ip, prefix=>$prefix)->addr;
=cut

sub netaddr {
    my ($self, %argv) = @_ ;
    if ( ref($self) ){
	# instance method
	return new NetAddr::IP($self->addr);
    }else{
	# class method
	if ( my $addr = $argv{address} ){
	    if ( $addr =~ /\D/o ){
		# address is a string
		return NetAddr::IP->new($addr, $argv{prefix});
	    }else{
		# Need version
		$self->throw_fatal("Integer argument requires IP version")
		    unless $argv{version};
		if ( $argv{version} == 4 ){
		    return NetAddr::IP->new($addr, $argv{prefix});
		}elsif ( $argv{version} == 6 ){
		    my $big = new Math::BigInt($addr);
		    return NetAddr::IP->new6($big, $argv{prefix});
		} else {
		    $self->throw_fatal("Invalid protocol version: $argv{version}");
		}
	    }
	}else{
	    $self->throw_fatal("Ipblock::netaddr: Missing required argument: address");
	}
    }
}

##################################################################

=head2 highest_ip
    
    Return highest IP address from a list of IP addresses

  Arguments:
    list of IP addresses
  Returns:
    an IP address
  Examples:
    my $ip = Ipblock->highest_ip("10.0.0.1", "192.168.1.1", "8.8.8.8");
    # "192.168.1.1"
=cut

sub highest_ip {
    my ($self, @ips) = @_;
    $self->isa_class_method('highest_ip');

    @ips = sort { $b cmp $a } map { Ipblock->netaddr(address => $_) } @ips;
    return $ips[0]->ip if @ips;
}

##################################################################

=head2 version - Return IP protocol version

  Arguments: 
     none
  Returns:   
    4 or 6
  Examples:
    if ($addr->version == 4) { ... }

=cut

sub version {
    my $self = shift;
    $self->isa_object_method('version');
    return $self->netaddr->version;
}

##################################################################

=head2 prefix - Return IP masklen

  Arguments: 
     none
  Returns:   
    0..32 for IPv4, 0..128 for IPv6 addresses
  Examples:
    if ($ipb->prefix == 32) { ... }

=cut

sub prefix {
    my $self = shift;
    $self->isa_object_method('prefix');
    return $self->netaddr->masklen;
}

=head2 address - Return IP address portion

  Arguments: 
     none
  Returns:   
    IP address in a string form
  Examples:
    if ($addr->address == "127.0.0.1") { ... }

=cut

sub address {
    my $self = shift;
    $self->isa_object_method('address');
    return $self->netaddr->ip;
}

=head2 parent - Return parent

  Arguments: 
     none
  Returns:   
    Another Ipblock or undef
  Examples:
    print $ipb->parent->addr, "\n";

=cut

sub parent {
    my $self = shift;
    $self->isa_object_method('parent');

    my $phrase = "id in (select ipblock_parent(?))";
    return ref($self)->retrieve_from_sql($phrase, $self->id)->first;
}

=head2 children - Return immediate children (blocks contained within this block)

  Arguments: 
     none
  Returns:   
    A collection of Ipblocks, possible empty
  Examples:
    for my $kid ($ipb->children) { ... }

=cut

sub children {
    my $self = shift;
    $self->isa_object_method('children');

    my $phrase = "ipblock_parent(id) = ? order by addr";
    return ref($self)->retrieve_from_sql($phrase, $self->id);
}


##################################################################
#
# Private Methods
#
##################################################################


##################################################################
# _prevalidate - Validate block before creating and updating
#
#     These checks are based on basic IP addressing rules
#
#   Arguments:
#     address
#     prefix    prefix can be null.  NetAddr::IP will assume it is a host (/32 or /128)
#   Returns:
#     NetAddr::IP object or 0 if failure

sub _prevalidate {
    my ($class, $address, $prefix) = @_;
    $class->isa_class_method('_prevalidate');

    $class->throw_fatal("Ipblock::_prevalidate: Missing required arguments: address")
	unless $address;

    unless ( $class->matches_ip($address) ) {
	$class->throw_user("IP: $address appears to be invalid");
    }

    if ( $address eq '0.0.0.0' || $address eq '::' ){
	$class->throw_user("The unspecified IP: $address is not valid");
    }

    my $ip = NetAddr::IP->new($address, $prefix);
    my $str = ( $address && $prefix ) ? (join('/', $address, $prefix)) : $address;
    if ( !$ip || $ip->numeric == 0 ){
	$class->throw_user("Invalid IP: $str");
    }

    # Make sure that what we're working with the base address
    # of the block, and not an address within the block
    unless( $ip->network == $ip ){
	$class->throw_user("IP: $str is not base address of block");
    }
    return $ip;
}

##################################################################
# _validate - Validate block when creating and updating
#
#     This method assumes the block has already been inserted in the DB 
#     (and the binary tree has been updated).  This facilitates the checks.
#     These checks are more specific to the way Netdot manages the address space.
#
#   Arguments:
#     Hash ref of arguments passed to insert/set
#   Returns:
#     True if Ipblock is valid.  Throws exception if not.
#   Examples:
#     $ipblock->_validate();


sub _validate {
    my ($self, $args) = @_;
    $self->isa_object_method('_validate');
    $logger->debug(sub{"Ipblock::_validate: Checking " . $self->get_label });
		   
    my $statusname = $self->status->name || "unknown";
    $logger->debug("Ipblock::_validate: " . $self->get_label . " has status: $statusname");

    my ($pstatus, $parent);
    if ( ($parent = $self->parent) && $parent->id ){
	$logger->debug("Ipblock::_validate: " . $self->get_label . " parent is ", $parent->get_label);
	
	if ( $parent->status && ($pstatus = $parent->status->name)) {
	    if ( $self->is_address() ){
		if ( $pstatus eq "Reserved" ){
		    $self->throw_user($self->get_label.": Address allocations not allowed under Reserved blocks");
		}elsif ( $pstatus eq 'Subnet' && $self->version == 4 && $parent->prefix != 31 ){
		    if ( $self->address eq $parent->address ){
			$self->throw_user(sprintf("IP cannot have same address as its subnet: %s == %s", 
						  $self->address, $parent->address));
		    }
		}
	    }else{
		if ( $pstatus ne "Container" ){
		    $self->throw_user(sprintf("Block allocations only allowed under Container blocks: %s within %s",
					      $self->get_label, $parent->get_label));
		}	    
	    }
	}
    }else{
	$logger->debug("Ipblock::_validate: " . $self->get_label . " does not have parent");
    }
    if ( $statusname eq "Subnet" ){
	# We only want addresses inside a subnet. 
	foreach my $ch ( $self->children ){
	    unless ( $ch->is_address() ){
		my $err = sprintf("%s %s cannot exist within Subnet %s", 
				  $ch->status->name, $ch->get_label, $self->get_label);
		$self->throw_user($err);
	    }
	}
    }elsif ( $statusname eq "Reserved" ){
	if ( $self->children ){
	    $self->throw_user($self->get_label.": Reserved blocks can't contain other blocks");
	}
    }elsif ( $statusname eq "Dynamic" ) {
	unless ( $self->is_address($self) ){
	    $self->throw_user($self->get_label.": Only addresses can be set to Dynamic");
	}
	unless ( $pstatus eq "Subnet" ){
	    $self->throw_user($self->get_label.": Dynamic addresses must be within Subnet blocks");
	}
	unless ( $parent->dhcp_scopes ){
	    $self->throw_user($self->get_label.": You need to enable DHCP in this subnet before adding any dynamic addresses");
	}

    }elsif ( $statusname eq "Static" ) {
	unless ( $self->is_address($self) ){
	    $self->throw_user($self->get_label.": Only addresses can be set to Static");
	}

    }elsif ( $statusname eq "Available" ) {
	unless ( $self->is_address($self) ){
	    $self->throw_user($self->get_label.": Only addresses can be set to Available");
	}
	if ( $self->a_records || $self->dhcp_scopes ){
	    $self->throw_user($self->get_label.": Available addresses cannot have A records or DHCP scopes");
	}
    }

    if ( $args->{monitored} ){
	unless ( $self->is_address($self) ){
	    $self->throw_user($self->get_label.": The monitored flag is only for addresses.");
	}	
    }

    if ( my $rir = $args->{rir} ){
	my $valid_rirs = $self->config->get('VALID_RIRS');
	unless ( exists $valid_rirs->{$rir} ){
	    $self->throw_user("Invalid RIR: $rir");
	}
    }

    return 1;
}

#################################################################
# Determine Status.  It can be either a name
# or a IpblockStatus id
# 
sub _get_status_id {
    my ($self, $arg) = @_;
    $self->throw_fatal("_get_status_id: Missing required argument")
	unless $arg;
    my $id;
    if ( ref($arg) && ref($arg) =~ /IpblockStatus/ ){
	# An object
	$id = $arg->id;
    }elsif ( $arg =~ /\d+/ ){
	# An ID
	$id = $arg;
    }elsif ( $arg =~ /\D+/ ){
	# A name
	my $stobj;
 	unless ( $stobj = IpblockStatus->search(name=>$arg)->first ){
 	    $self->throw_fatal("Status $arg not known");
 	}
 	$id = $stobj->id;
    }
    return $id;
}



##################################################################
# Short way to retrieve all the ip addresses from a device
# 
# Apparently one can't bind the "ORDER BY" parameter :-(
#
# usage: 
#   Ipblock->search_devipsbyaddr($dev)

__PACKAGE__->set_sql(devipsbyaddr => qq{
    SELECT device.id, interface.id, interface.name, interface.device, ipblock.id, ipblock.interface, host(ipblock.addr)
	FROM ipblock, interface, device
	WHERE interface.id = ipblock.interface AND
	device.id = interface.device AND
	device.id = ?
	ORDER BY ipblock.addr
    });

# usage:
#   Ipblock->search_devipsbyint($dev)

__PACKAGE__->set_sql(devipsbyint => qq{
    SELECT device.id, interface.id, interface.name, interface.device, ipblock.id, ipblock.interface, host(ipblock.addr)
	FROM ipblock, interface, device
	WHERE interface.id = ipblock.interface AND
	device.id = interface.device AND
	device.id = ?
	ORDER BY interface.name
    });


=head1 AUTHORS

Carlos Vicente, C<< <cvicente at ns.uoregon.edu> >> with contributions from Nathan Collins and Aaron Parecki.

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

# Make sure to return 1
1;
