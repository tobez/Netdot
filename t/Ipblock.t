use strict;
use Test::More;
use Test::Fatal;
use lib "lib";
use lib "t";
use test_helpers;

BEGIN { use_ok('Netdot::Model::Ipblock'); }

test_helpers::disable_logging();
test_helpers::settable_config();

Ipblock->config->set(SUBNET_USAGE_MINPERCENT => undef);
Ipblock->config->set(DEVICE_IP_NAME_PLUGIN => "Netdot::Model::Plugins::DeviceIpNamesByInt");

like(exception {
     my $x = Ipblock->get_maxed_out_subnets;
}, qr/is not defined in config/, 'bad config for get_maxed_out_subnets');

Ipblock->config->set("SUBNET_USAGE_MINPERCENT", 5);

for my $reserved (0, 5) {
# incorrect indentation kept here because it makes more sense

Ipblock->config->set("SUBNET_AUTO_RESERVE", $reserved);
is(Ipblock->config->get('SUBNET_AUTO_RESERVE'), $reserved, "FURTHER TESTS WITH SUBNET_AUTO_RESERVE OF $reserved");

like(exception {
	my $x = Ipblock->insert;
}, qr/Missing required arguments/, 'bad insert 1');

my $container = Ipblock->insert({
    address => "192.0.2.0",
    prefix  => '24',
    version => 4,
    status  => 'Container',
});
is($container->is_address, 0, '!container.is_address');
is($container->status->name, 'Container', 'insert container');
is($container->parent, undef, "container does not have a parent");
is(scalar($container->children), 0, "container does not have children");

my $subnet = Ipblock->insert({
    address => "192.0.2.0",
    prefix  => '25',
    version => 4,
    status  => 'Subnet',
});
is($subnet->is_address, 0, '!subnet.is_address');
is($subnet->status->name, 'Subnet', 'insert subnet');
is($subnet->parent, $container, 'subnet.parent = container');
is($container->parent, undef, "container still does not have a parent");
is(scalar($container->children), 1, "container now has 1 kid");
is($container->children->first, $subnet, "container.children.first = subnet");
is(scalar($subnet->children), $reserved, "subnet does not have interesting children");

my @unused_v4 = Ipblock->get_unused_subnets(version => 4);
if (!$reserved) {
	ok(scalar(grep { $subnet->id eq $_->id } @unused_v4), "1: newly inserted subnet is unused");
} else {
	ok(!scalar(grep { $subnet->id eq $_->id } @unused_v4), "1: newly inserted subnet is NOT unused because of reservations");
}
@unused_v4 = Ipblock->get_unused_subnets();
if (!$reserved) {
	ok(scalar(grep { $subnet->id eq $_->id } @unused_v4), "2: newly inserted subnet is unused");
} else {
	ok(!scalar(grep { $subnet->id eq $_->id } @unused_v4), "2: newly inserted subnet is NOT unused because of reservations");
}

my $address = Ipblock->insert({
    address => "192.0.2.10",
    prefix  => '32',
    version => 4,					 
    status  => 'Static',
});
is($address->is_address, 1, 'address.is_address');
is($address->status->name, 'Static', 'insert address');
is($container->parent, undef, "container does not and never will have a parent");
is(scalar($container->children), 1, "container still has 1 kid");
is($container->children->first, $subnet, "container.children.first = subnet");
is($address->parent, $subnet, 'address.parent = subnet');
is(scalar($subnet->children), 1 + $reserved, "subnet now has interesting children");
is(($subnet->children)[$reserved], $address, "container.children.last = address");

my $desc = $container->get_descendants;
is(scalar @$desc, 2+$reserved, "container.get_descendants: correct count");
is($desc->[0], $subnet, "container.get_descendants: includes subnet");
is($desc->[-1], $address, "container.get_descendants: includes address");

$desc = $subnet->get_descendants;
is(scalar @$desc, 1+$reserved, "subnet.get_descendants: correct count");
is($desc->[-1], $address, "subnet.get_descendants: includes address");

$desc = $container->get_descendants(no_addresses => 1);
is(scalar @$desc, 1, "container.get_descendants(no addresses): correct count");
is($desc->[0], $subnet, "container.get_descendants(no addresses): includes subnet");

$desc = $subnet->get_descendants(no_addresses => 1);
is(scalar @$desc, 0, "subnet.get_descendants(no addresses): correct count of zero");

is($address->address, '192.0.2.10', 'address method');
is($address->address_numeric, '3221225994', 'address_numeric method');
is($address->prefix, 32, 'prefix method');
is($address->version, 4, 'version method');

is($subnet->num_addr(), 126, 'num_addr subnet');
is($address->num_addr(), 1, 'num_addr host');
is($container->num_addr(), 256, 'num_addr container');
is($subnet->address_usage(), 1 + $reserved, 'address_usage');

is($container->subnet_usage(), '128', 'subnet_usage');
like(exception { $subnet->subnet_usage() },
     qr/only for Container blocks/,
     'subnet_usage on a non-container');

is($address->get_label(), '192.0.2.10', 'address label');
is($subnet->get_label(), '192.0.2.0/25', 'subnet label');

is(Ipblock->search(address=>'192.0.2.0', prefix=>'25')->first, $subnet, 'search address+prefix' );
is(Ipblock->search(address=>'192.0.2.0', prefix=>'25', { order_by => 'addr' })->first, $subnet, 'search address+prefix with options' );
is(Ipblock->search(address=>'192.0.2.0/25')->first, $subnet, 'search address/prefix' );
is(Ipblock->search(addr=>'192.0.2.0/25')->first, $subnet, 'search addr in cidr form' );
is(Ipblock->search(address=>'192.0.2.0/25', status => "Subnet")->first, $subnet, 'search with good status' );
is(scalar(Ipblock->search(address=>'192.0.2.0/25', status => "Static")), 0, 'search with bad status' );
like(exception { Ipblock->search(address=>'192.0.2.0/25', status => "Muha") }, qr/Status Muha not known/, 'search with horrible status' );
like(exception { Ipblock->search(address=>'muha') }, qr/does not match valid IP/, 'search bad address' );

is(scalar(Ipblock->search_like(address=>'192.0')), 3 + $reserved, 'search_like' );
is(scalar(Ipblock->search_like(address=>'192.0', { order_by => 'id' })), 3 + $reserved, 'search_like with opts' );
is(scalar(Ipblock->search_like(address=>'192.0', { non => 'sensical' })), 3 + $reserved, 'search_like with opts 2' );
is(scalar(Ipblock->search_like(address=>'192.0/32')), 1 + $reserved, 'search_like with host prefix' );
ok(scalar(Ipblock->search_like(address=>'192')), 'search_like LIKE' );
is((Ipblock->search_like(address=>'192.0/25'))[0], $subnet, 'search_like with subnet prefix' );

$subnet->update({description=>'test subnet'});
is(((Ipblock->keyword_search('test subnet'))[0])->id, $subnet->id, 'keyword_search');

my $descr = 'test blocks';
$container->update({description=>$descr, recursive=>1});
is($container->description, $descr, 'update_recursive container description');
my $subnet_id = $subnet->id;
undef($subnet);
$subnet = Ipblock->retrieve($subnet_id);
is($subnet->description, $descr, 'update_recursive subnet description');
my $address_id = $address->id;
undef($address);
$address = Ipblock->retrieve($address_id);
is($address->description, $descr, 'update_recursive address description');

my @ancestors = $address->get_ancestors();
is($ancestors[0], $subnet, 'get_ancestors');
is($ancestors[1], $container, 'get_ancestors');
 
my ($s,$p) = Ipblock->get_subnet_addr( address => $address->address,
				       prefix  => 25 );
is($s, $subnet->address, 'get_subnet_addr address ok');
is($p, 25, 'get_subnet_addr prefix ok');
$s = Ipblock->get_subnet_addr( address => $address->address,
				       prefix  => 25 );
is($s, $subnet->address, 'scalar(get_subnet_addr) address ok');
like(exception {
	my $x = Ipblock->get_subnet_addr(address=>'muha', prefix => 88);
}, qr/Invalid IP/, 'bad get_subnet_addr');

ok(Ipblock->within('127.0.0.1', '127.0.0.0/8'), "127.0.0.1 is within 127.0.0.0/8");
ok(!Ipblock->within('192.168.0.1', '127.0.0.0/8'), "192.168.0.1 is NOT within 127.0.0.0/8");
like(exception {
	my $x = Ipblock->within();
}, qr/Missing required arguments/, 'bad within 1');
like(exception {
	my $x = Ipblock->within("adr");
}, qr/Missing required arguments/, 'bad within 2');
like(exception {
	my $x = Ipblock->within("", "block");
}, qr/Missing required arguments/, 'bad within 3');
like(exception {
	my $x = Ipblock->within(1, "block");
}, qr/not a valid CIDR/, 'bad within 4');
like(exception {
	my $x = Ipblock->within("this is a bad IP", "127.0.0.0/8");
}, qr/bad address/, 'bad within 5');
like(exception {
	my $x = Ipblock->within("127.0.0.1", "this is a bad/network");
}, qr/bad block/, 'bad within 6');

my $hosts = Ipblock->get_host_addrs( $subnet->address ."/". $subnet->prefix );
is($hosts->[0], '192.0.2.1', 'get_host_addrs');

ok( Ipblock->is_loopback('127.0.0.1'), 'is_loopback_v4');
ok(!Ipblock->is_loopback('192.168.10.1'), '!is_loopback_v4');
ok( Ipblock->is_loopback('::1'), 'is_loopback_v6');
ok(!Ipblock->is_loopback('2001:2010::1'), '!is_loopback_v6');
ok(!$address->is_loopback, 'is_loopback as an instance method');
like(exception {
	my $x = Ipblock->is_loopback;
}, qr/Missing required arguments/, 'bad is_loopback 1');
like(exception {
	my $x = Ipblock->is_loopback("notandaddress");
}, qr/Invalid IP/, 'bad is_loopback 2');
like(exception {
	my $x = Ipblock->is_loopback("notandaddress", "notaprefix");
}, qr/Invalid IP/, 'bad is_loopback 3');

ok( Ipblock->is_multicast('239.255.0.1'), 'is_multicast_v4');
ok(!Ipblock->is_multicast('127.0.0.1'), '!is_multicast_v4');
ok( Ipblock->is_multicast('FF02::1'), 'is_multicast_v6');
ok(!Ipblock->is_multicast('::1'), '!is_multicast_v6');
ok(!$address->is_multicast, 'is_multicast as an instance method');
like(exception {
	my $x = Ipblock->is_multicast;
}, qr/Missing required arguments/, 'bad is_multicast 1');
like(exception {
	my $x = Ipblock->is_multicast("notandaddress");
}, qr/Invalid IP/, 'bad is_multicast 2');
like(exception {
	my $x = Ipblock->is_multicast("notandaddress", "notaprefix");
}, qr/Invalid IP/, 'bad is_multicast 3');

ok( Ipblock->is_link_local('fe80:abcd::1234'), 'is_link_local');
ok(!Ipblock->is_link_local('::1'), '!is_link_local');
ok(!$address->is_link_local, 'is_link_local as an instance method');
like(exception {
	my $x = Ipblock->is_link_local;
}, qr/Missing required arguments/, 'bad is_link_local 1');
like(exception {
	my $x = Ipblock->is_link_local("notandaddress");
}, qr/Invalid IP/, 'bad is_link_local 2');
like(exception {
	my $x = Ipblock->is_link_local("notandaddress", "notaprefix");
}, qr/Invalid IP/, 'bad is_link_local 3');

is(Ipblock->get_covering_block(address=>'192.0.2.8', prefix=>'32'), $subnet,
   'get_covering_block');
is(Ipblock->get_covering_block(address=>'192.0.2.10', prefix=>'32'), $address,
   'get_covering_block - self'); # XXX not sure this is how get_covering_block() should behave
like(exception {
     my $x = Ipblock->get_covering_block();
}, qr/issing required arguments/, 'bad get_covering_block 1');
is(Ipblock->get_covering_block(address=>'192.0.2.8'), $subnet,
   'get_covering_block no prefix');
is(Ipblock->get_covering_block(address=>'not an address', prefix=>'not a prefix'), undef,
   'get_covering_block invalid address');  # XXX why it does not die?


is(Ipblock->numhosts(24), 256, 'numhosts');

{
    use bigint;
    is(Ipblock->numhosts_v6(64), 18446744073709551616, 'numhosts_v6');
}
is(Ipblock->shorten(ipaddr=>'192.0.0.34',mask=>'16'), '0.34', 'shorten');
is(Ipblock->shorten(ipaddr=>'192.0.0.34',mask=>'1'), '192.0.0.34', 'shorten <=7');
is(Ipblock->shorten(ipaddr=>'192.0.0.34',mask=>'10'), '0.0.34', 'shorten <=15');
is(Ipblock->shorten(ipaddr=>'192.0.0.34',mask=>'28'), '192.0.0.34', 'shorten >= 24');

is(Ipblock->subnetmask(256), 24, 'subnetmask');

is(Ipblock->subnetmask_v6(4), 126, 'subnetmask_v6');

is($subnet->get_next_free(strategy=>'first'), '192.0.2.' . (1+$reserved), 'get_next_free(first)');
is($subnet->get_next_free(strategy=>'last'), '192.0.2.126', 'get_next_free(last)');
# XXX throws_ok invalid strategy

is(($subnet->get_dot_arpa_names)[0], '0-25.2.0.192.in-addr.arpa', 'get_dot_arpa_names_v4_25');

my $ip_status = (IpblockStatus->search(name=>'Discovered'))[0];
ok($ip_status, "can get ip status");
Ipblock->fast_update({
	"192.0.2.10" => {
		prefix    => 32,
		version   => 4,
		status    => $ip_status,
		timestamp => Ipblock->timestamp,
	},
});
is(Ipblock->search(address=>'192.0.2.10')->first->status->name, "Static",
	'fast update 1: does not change existing things');
is(Ipblock->search(address=>'192.0.2.11')->first, undef,
	'fast update 1: does not add things not asked');

Ipblock->fast_update({
	"192.0.2.11" => {
		prefix    => 32,
		version   => 4,
		status    => $ip_status,
		timestamp => Ipblock->timestamp,
	},
});
is(Ipblock->search(address=>'192.0.2.11')->first->status->name, "Discovered",
	'fast update 2: inserts new things');
is(Ipblock->search(address=>'192.0.2.12')->first, undef,
	'fast update 2: does not add things not asked');

Ipblock->fast_update({
	"192.0.2.10" => {
		prefix    => 32,
		version   => 4,
		status    => $ip_status,
		timestamp => Ipblock->timestamp,
	},
	"192.0.2.11" => {
		prefix    => 32,
		version   => 4,
		status    => $ip_status,
		timestamp => Ipblock->timestamp,
	},
	"192.0.2.12" => {
		prefix    => 32,
		version   => 4,
		status    => $ip_status,
		timestamp => Ipblock->timestamp,
	},
});
is(Ipblock->search(address=>'192.0.2.10')->first->status->name, "Static",
	'fast update 3: does not change existing things');
is(Ipblock->search(address=>'192.0.2.12')->first->status->name, "Discovered",
	'fast update 3: inserts new things');
is(Ipblock->search(address=>'192.0.2.13')->first, undef,
	'fast update 3: does not add things not asked');

my $subnet2 = Ipblock->insert({
    address => "192.0.2.160",
    prefix  => '27',
    version => 4,
    status  => 'Subnet',
});
is(($subnet2->get_dot_arpa_names)[0], '160-27.2.0.192.in-addr.arpa', 'get_dot_arpa_names_v4_27');

is(scalar Ipblock->get_maxed_out_subnets(), 0, "get_maxed_out_subnets(): nothing");
is(scalar Ipblock->get_maxed_out_subnets(version => 6), 0, "get_maxed_out_subnets(6): nothing");
is(scalar Ipblock->get_maxed_out_subnets(version => 4), 0, "get_maxed_out_subnets(4): nothing");

my @fs = $subnet2->free_space;
if ($reserved) {
    is(scalar @fs, 4, "free_space: correct count");
    is("$fs[0]", "192.0.2.160/32", "free_space: correct first space");
    is("$fs[-1]", "192.0.2.176/28", "free_space: correct last space");
} else {
    is(scalar @fs, 1, "free_space: correct count");
    is("$fs[0]", "192.0.2.160/27", "free_space: correct first");
}
@fs = $subnet2->free_space(32);
is(scalar @fs, 32-$reserved, "free_space(32): correct count");
is("$fs[0]", "192.0.2.160/32", "free_space(32): correct first space");
is("$fs[-1]", "192.0.2.191/32", "free_space(32): correct last space");

like(exception {
     my $x = $subnet2->add_range(
	start  => "192.0.2.190",
	end    => "192.0.2.180",
	status => "Discovered");
}, qr/Invalid range/, 'bad add_range 1');

like(exception {
     my $x = $subnet2->add_range(
	start  => "192.168.2.180",
	end    => "192.168.2.190",
	status => "Discovered");
}, qr/not within this subnet/, 'bad add_range 2');

like(exception {
     my $x = $subnet2->add_range(
	start  => "192.168.2.180",
	end    => "192.168.2.190");
}, qr/required argument: status/, 'bad add_range 3');

like(exception {
     my $x = $subnet2->add_range(
	start  => "not an ip",
	end    => "192.0.2.180",
	status => "Discovered");
}, qr/Invalid range/, 'bad add_range 4');

like(exception {
     my $x = $subnet2->add_range(
	start  => "192.0.2.190",
	end    => "not an ip",
	status => "Discovered");
}, qr/Invalid range/, 'bad add_range 5');

like(exception {
     my $x = $subnet2->add_range(
	start  => "192.0.2.180",
	end    => "192.168.2.190",
	status => "Discovered");
}, qr/not within this subnet/, 'bad add_range 6');

like(exception {
     my $x = $subnet2->add_range(
	start  => "191.0.2.180",
	end    => "192.0.2.190",
	status => "Discovered");
}, qr/not within this subnet/, 'bad add_range 7');

like(exception {
     my $x = $subnet2->add_range(
	start  => "192.0.2.180",
	end    => "192.0.2.190",
	status => "Dynamic");
}, qr/Please enable DHCP/, 'bad add_range 8');

my $added = $subnet2->add_range(
    start  => "192.0.2." . (160 + $reserved + 1),
    end    => "192.0.2.180",
    status => "Discovered");
is(scalar @$added, 20-$reserved, "add_range 1: added expected number of IPs");
is($added->[0]->address, "192.0.2." . (160 + $reserved + 1), "add_range 1: first added is fine");
is($added->[-1]->address, "192.0.2.180", "add_range 1: last added is fine");

$added = $subnet2->add_range(
    start  => "192.0.2.180",
    end    => "192.0.2.190",
    status => "Discovered");
is(scalar @$added, 11, "add_range 2: added expected number of IPs");
is($added->[0]->address, "192.0.2.180", "add_range 2: first added is fine");
is($added->[1]->address, "192.0.2.181", "add_range 2: second added is fine");
is($added->[-1]->address, "192.0.2.190", "add_range 2: last added is fine");

my @maxed = Ipblock->get_maxed_out_subnets;
is(scalar @maxed, 1, "get_maxed_out_subnets(): found just filled net");
ok($maxed[0][1] < 5, "get_maxed_out_subnets(): free % is below the threshold");
is($maxed[0][0]->address, "192.0.2.160", "get_maxed_out_subnets(): correct maxed out network");
is($maxed[0][0]->prefix, 27, "get_maxed_out_subnets(): correct maxed out prefix");

like(exception {
     my $x = $subnet2->remove_range(
	start  => "192.0.2.190",
	end    => "192.0.2.180");
}, qr/Invalid range/, 'bad remove_range 1');

like(exception {
     my $x = $subnet2->remove_range(
	start  => "not an ip",
	end    => "192.0.2.180");
}, qr/Invalid range/, 'bad remove_range 2');

like(exception {
     my $x = $subnet2->remove_range(
	start  => "192.0.2.190",
	end    => "not an ip");
}, qr/Invalid range/, 'bad remove_range 3');

like(exception {
     my $x = $subnet2->remove_range(
	start  => "192.168.2.180",
	end    => "192.168.2.190");
}, qr/not within this subnet/, 'bad remove_range 4');

like(exception {
     my $x = $subnet2->remove_range(
	start  => "192.0.2.180",
	end    => "192.168.2.190");
}, qr/not within this subnet/, 'bad remove_range 5');

like(exception {
     my $x = $subnet2->remove_range(
	start  => "191.0.2.180",
	end    => "192.0.2.190");
}, qr/not within this subnet/, 'bad remove_range 6');

ok($subnet2->remove_range(
    start  => "192.0.2.180",
    end    => "192.0.2.190"),
    "remove_range: removed");

is(scalar Ipblock->get_maxed_out_subnets(), 0, "get_maxed_out_subnets(): nothing after remove_range");

# my $subnet3 = Ipblock->insert({
#     address => "169.254.100.0",
#     prefix  => '23',
#     version => 4,
#     status  => 'Subnet',
# });
# my @arpa_names = ('100.254.169.in-addr.arpa', '101.254.169.in-addr.arpa');
# my @a = $subnet3->get_dot_arpa_names();
# is($a[0], $arpa_names[0], 'get_dot_arpa_names_v4_23');
# is($a[1], $arpa_names[1], 'get_dot_arpa_names_v4_23');

my $blk = Ipblock->insert({
    address => "8.0.0.0",
    prefix  => '7',
    version => 4,
    status  => 'Container',
});
my @arpa_names = ('8.in-addr.arpa', '9.in-addr.arpa');
my @a = $blk->get_dot_arpa_names();
is($a[0], $arpa_names[0], 'get_dot_arpa_names_v4_7');
is($a[1], $arpa_names[1], 'get_dot_arpa_names_v4_7');
$blk->delete();

# Previously 2001:db8::/32 was used, but it is now present in the DB by default,
# so we use a real /32 (allocated to TELIANETDK) for tests here.
my $v6container = Ipblock->insert({
    address => "2001:2010::",
    prefix  => '32',
    version => 6,
    status  => 'Container',
});
is(($v6container->get_dot_arpa_names)[0], '0.1.0.2.1.0.0.2.ip6.arpa', 'get_dot_arpa_name_v6_32');
is($v6container->is_address, 0, '!v6 container.is_address');

my $v6subnet = Ipblock->insert({
    address => "2001:2010::",
    prefix  => '62',
    version => 6,
    status  => 'Subnet',
});
is($v6subnet->parent, $v6container, 'v6_parent');
is($v6subnet->is_address, 0, '!v6 subnet.is_address');
is($v6container->subnet_usage(), Math::BigInt->new(1) << (128-62), 'v6 subnet_usage');

my @unused_v6 = Ipblock->get_unused_subnets(version => 6);
if (!$reserved) {
	ok(scalar(grep { $v6subnet->id eq $_->id } @unused_v6), "1: newly inserted IPv6 subnet is unused");
} else {
	ok(!scalar(grep { $v6subnet->id eq $_->id } @unused_v6), "1: newly inserted IPv6 subnet is NOT unused because of reservations");
}
@unused_v6 = Ipblock->get_unused_subnets();
if (!$reserved) {
	ok(scalar(grep { $v6subnet->id eq $_->id } @unused_v6), "2: newly inserted IPv6 subnet is unused");
} else {
	ok(!scalar(grep { $v6subnet->id eq $_->id } @unused_v6), "2: newly inserted IPv6 subnet is NOT unused because of reservations");
}

my $v6address = Ipblock->insert({
    address => "2001:2010::10",
    prefix  => '128',
    version => 6,
    status  => 'Static',
});
is($v6address->is_address, 1, 'v6 address.is_address');
is($v6address->status->name, 'Static', 'insert v6 address');
is($v6container->parent, undef, "v6 container does not and never will have a parent");
is(scalar($v6container->children), 1, "container still has 1 kid");
is($v6container->children->first, $v6subnet, "v6 container.children.first = v6 subnet");
is($v6address->parent, $v6subnet, 'v6address.parent = v6subnet');
is(scalar($v6subnet->children), 1 + $reserved, "v6subnet now has interesting children");
is(($v6subnet->children)[$reserved], $v6address, "container.children.last = address");

is($v6address->address, '2001:2010::10', 'v6 address method');
#is($v6address->address_numeric, '3221225994', 'address_numeric method');
is($v6address->prefix, 128, 'v6 prefix method');
is($v6address->version, 6, 'v6 version method');

is(($v6subnet->get_dot_arpa_names)[0], '0.0.0.0.0.0.0.0.0.1.0.2.1.0.0.2.ip6.arpa', 
   'get_dot_arpa_name_v6_62');
is(($v6subnet->get_dot_arpa_names)[1], '1.0.0.0.0.0.0.0.0.1.0.2.1.0.0.2.ip6.arpa', 
   'get_dot_arpa_name_v6_62');
is(($v6subnet->get_dot_arpa_names)[2], '2.0.0.0.0.0.0.0.0.1.0.2.1.0.0.2.ip6.arpa', 
   'get_dot_arpa_name_v6_62');
is(($v6subnet->get_dot_arpa_names)[3], '3.0.0.0.0.0.0.0.0.1.0.2.1.0.0.2.ip6.arpa', 
'get_dot_arpa_name_v6_62');

is(scalar(Ipblock->search_like(address=>'2001:2010')), 3 + $reserved, 'v6 search_like' );
is(scalar(Ipblock->search_like(address=>'2001:2010/128')), 1 + $reserved, 'v6 search_like with host prefix' );
is((Ipblock->search_like(address=>'2001:2010/62'))[0], $v6subnet, 'v6 search_like with subnet prefix' );

my $v6container3 = Ipblock->insert({
    address => "2001:2010::",
    prefix  => '48',
    version => 6,
    status  => 'Container',
});

is($v6container3->parent, $v6container,  'v6_parent2');
# Refresh object to avoid looking at old data
my $tmpid = $v6subnet->id;
$v6subnet = undef;
$v6subnet = Ipblock->retrieve($tmpid);
is($v6subnet->parent, $v6container3, 'v6_parent3');

is($v6subnet->get_next_free, '2001:2010::' . (1 + $reserved), 'get_next_free_v6');
is($v6subnet->get_next_free(strategy=>'last'), '2001:2010:0:3:ffff:ffff:ffff:fffe', 'get_next_free_last_v6');

is(Ipblock->matches_v4($address->address), 1, 'matches_v4_1');
is(Ipblock->matches_v4($v6subnet->address), 0, 'matches_v4_2');
is(Ipblock->matches_v4(), 0, 'matches_v4: nothing does not match');


is(Ipblock->matches_v6($v6subnet->address), 1, 'matches_v6_1');
is(Ipblock->matches_v6($address->address), 0, 'matches_v6_2');
is(Ipblock->matches_v6(), 0, 'matches_v6: nothing does not match');

is(Ipblock->matches_ip($v6subnet->address), 1, 'matches_ip_1');
is(Ipblock->matches_ip($address->address), 1, 'matches_ip_2');
is(Ipblock->matches_ip(), 0, 'matches_ip: nothing does not match');

my $ar1 = Ipblock->matches_cidr($address->cidr);
my $ar2 = ($address->address, $address->prefix);
is_deeply(\$ar1, \$ar2, 'matches_cidr: v4');
is(Ipblock->matches_cidr("no slash"), 0, "!matches_cidr: no slash");
is(Ipblock->matches_cidr("384.384.384.0/24"), 0, "!matches_cidr: bad IPv4 address");
is(Ipblock->matches_cidr("10.10.10.10/33"), 0, "!matches_cidr: bad IPv4 prefix");
ok(Ipblock->matches_cidr("2001:2010::/32"), "matches_cidr: v6 large");
ok(Ipblock->matches_cidr("2001:2010::1/128"), "matches_cidr: v6");
is(Ipblock->matches_cidr("2001:2010::z/128"), 0, "!matches_cidr: bad IPv6 address");
is(Ipblock->matches_cidr("2001:2010::1/129"), 0, "!matches_cidr: bad IPv6 prefix");
is(Ipblock->matches_cidr("10.10.10.10/666"), 0, "!matches_cidr: totally bad prefix");

is(  $address->full_address, "192.0.2.10", "full_address: IPv4");
is($v6address->full_address, "2001:2010:0000:0000:0000:0000:0000:0010", "full_address: IPv6");

my @roots;
@roots = Ipblock->get_roots();
ok( scalar(grep {   $container->id eq $_->id } @roots), "get_roots(): v4 container is there");
ok(!scalar(grep { $v6container->id eq $_->id } @roots), "get_roots(): v6 container is not there");
ok(!scalar(grep {   $subnet   ->id eq $_->id } @roots), "get_roots(): v4 subnet is not there");
ok(!scalar(grep { $v6subnet   ->id eq $_->id } @roots), "get_roots(): v6 subnet is not there");
ok(!scalar(grep {   $address  ->id eq $_->id } @roots), "get_roots(): v4 address is not there");
ok(!scalar(grep { $v6address  ->id eq $_->id } @roots), "get_roots(): v6 address is not there");
my $some_root = Ipblock->get_roots();
ok($some_root, "get_roots() in a scalar context");

@roots = Ipblock->get_roots(4);
ok( scalar(grep {   $container->id eq $_->id } @roots), "get_roots(4): v4 container is there");
ok(!scalar(grep { $v6container->id eq $_->id } @roots), "get_roots(4): v6 container is not there");
ok(!scalar(grep {   $subnet   ->id eq $_->id } @roots), "get_roots(4): v4 subnet is not there");
ok(!scalar(grep { $v6subnet   ->id eq $_->id } @roots), "get_roots(4): v6 subnet is not there");
ok(!scalar(grep {   $address  ->id eq $_->id } @roots), "get_roots(4): v4 address is not there");
ok(!scalar(grep { $v6address  ->id eq $_->id } @roots), "get_roots(4): v6 address is not there");

@roots = Ipblock->get_roots(6);
ok(!scalar(grep {   $container->id eq $_->id } @roots), "get_roots(6): v4 container is not there");
ok( scalar(grep { $v6container->id eq $_->id } @roots), "get_roots(6): v6 container is there");
ok(!scalar(grep {   $subnet   ->id eq $_->id } @roots), "get_roots(6): v4 subnet is not there");
ok(!scalar(grep { $v6subnet   ->id eq $_->id } @roots), "get_roots(6): v6 subnet is not there");
ok(!scalar(grep {   $address  ->id eq $_->id } @roots), "get_roots(6): v4 address is not there");
ok(!scalar(grep { $v6address  ->id eq $_->id } @roots), "get_roots(6): v6 address is not there");

@roots = Ipblock->get_roots("all");
ok( scalar(grep {   $container->id eq $_->id } @roots), "get_roots('all'): v4 container is there");
ok( scalar(grep { $v6container->id eq $_->id } @roots), "get_roots('all'): v6 container is there");
ok(!scalar(grep {   $subnet   ->id eq $_->id } @roots), "get_roots('all'): v4 subnet is not there");
ok(!scalar(grep { $v6subnet   ->id eq $_->id } @roots), "get_roots('all'): v6 subnet is not there");
ok(!scalar(grep {   $address  ->id eq $_->id } @roots), "get_roots('all'): v4 address is not there");
ok(!scalar(grep { $v6address  ->id eq $_->id } @roots), "get_roots('all'): v6 address is not there");

is(Ipblock->objectify($address), $address, "objectify(\$ipblock)");
is(Ipblock->objectify($address->id), $address, "objectify(ID)");
is(Ipblock->objectify($address->address), $address, "objectify(address)");
is(Ipblock->objectify("8.8.8.8"), undef, "objectify(non-existing address)");

like(exception {
     Ipblock->_prevalidate;
}, qr/Missing required arguments: address/, 'bad _prevalidate 1');
like(exception {
     Ipblock->_prevalidate("384.384.384.384");
}, qr/appears to be invalid/, 'bad _prevalidate 2');
like(exception {
     Ipblock->_prevalidate("not an ip not an ip");
}, qr/appears to be invalid/, 'bad _prevalidate 2');
like(exception {
     Ipblock->_prevalidate("2001:2010::::::1");
}, qr/appears to be invalid/, 'bad _prevalidate 3');
like(exception {
     Ipblock->_prevalidate("0.0.0.0");
}, qr/The unspecified IP/, 'bad _prevalidate 4');
like(exception {
     Ipblock->_prevalidate("::");
}, qr/The unspecified IP/, 'bad _prevalidate 5');
like(exception {
     Ipblock->_prevalidate("1.2.3.4", 33);
}, qr/Invalid IP/, 'bad _prevalidate 6');
like(exception {
     Ipblock->_prevalidate("2001:2010::1", 555);
}, qr/Invalid IP/, 'bad _prevalidate 7');
like(exception {
     Ipblock->_prevalidate("1.1.1.1", 24);
}, qr/is not base address of block/, 'bad _prevalidate 8');
like(exception {
     Ipblock->_prevalidate("2001:2010::1", 48);
}, qr/is not base address of block/, 'bad _prevalidate 9');

is(Ipblock->validate("1.1.1.0-255", 24), 1, "validate 1");
is(Ipblock->validate("1.1.1.0", 24), 1, "validate 2");
is(Ipblock->validate("1.1.1.1", 24), 0, "validate 3");

my $container2 = Ipblock->insert({
    address => "192.2.2.0",
    prefix  => '24',
    version => 4,
    status  => 'Container',
});
ok($container2, "insert another container");
like(exception {
    $container2->update({address => "192.0.2.0"});
}, qr/already exists in db/, "update to existing fails");
$container2->update({address => "192.2.4.0"});
is(Ipblock->search_like(address=>'192.2.4')->first, $container2, 'address update succesfull' );
$container2->update({address => "192.2.2.0", prefix => 23});
is(Ipblock->search(address=>'192.2.2.0', prefix => 23)->first, $container2, 'address+prefix update succesfull' );
is(Ipblock->search(address=>'192.2.2.0', prefix => 24)->first, undef, 'no hanging results after update, 1' );
is(Ipblock->search_like(address=>'192.2.4')->first, undef, 'no hanging results after update, 2' );
$container2->update({status => 'Subnet'});
is($container2->status->name, 'Subnet', 'change container into subnet');

like(exception {
     $address->update_a_records;
}, qr/Missing required arguments/, 'update_a_records: no args');
like(exception {
     $address->update_a_records(num_ips => 1);
}, qr/Missing required arguments/, 'update_a_records: missing args 1');
like(exception {
     $address->update_a_records(hostname_ips => []);
}, qr/Missing required arguments/, 'update_a_records: missing args 2');
like(exception {
     $address->update_a_records(hostname_ips => [], num_ips => 1);
}, qr/not associated with any Device/, 'update_a_records: no device association');

# For properly testing update_a_records(), we need to work with Device and Zone
use_ok('Netdot::Model::Device');
#my $dd = Netdot->config->get('DEFAULT_DNSDOMAIN');
my $ddn = (Zone->search(name=>"defaultdomain")->first)->name;
my $dev = Device->insert({name=>'localhost'});
isa_ok($dev, 'Netdot::Model::Device', 'insert');
$dev->add_interfaces(1);
my ($devint) = $dev->interfaces();
$devint->update({auto_dns => 0});
$address->update({interface => $devint});

like(exception {
     $address->update_a_records(hostname_ips => [], num_ips => 1);
}, qr/configured for no auto DNS/, 'update_a_records: no auto DNS');

$dev->delete;
isa_ok($dev, 'Class::DBI::Object::Has::Been::Deleted', 'delete device');

# Delete all records
$container2->delete(recursive=>1);
$container->delete(recursive=>1);
$v6container->delete(recursive=>1);
isa_ok($container, 'Class::DBI::Object::Has::Been::Deleted', 'delete');

} # and then repeat everything again with a different SUBNET_AUTO_RESERVE value

done_testing();
