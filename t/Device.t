use strict;
use Test::More;
use Test::Fatal;
use lib "lib";

BEGIN { use_ok('Netdot::Model::Device'); }
BEGIN { use_ok('Netdot::Exporter'); }

my $dd = Netdot->config->get('DEFAULT_DNSDOMAIN');
my $ddn = (Zone->search(name=>$dd)->first)->name;

my $obj = Device->insert({name=>'localhost'});
isa_ok($obj, 'Netdot::Model::Device', 'insert');

is($obj->short_name, 'localhost', 'get short_name');
is($obj->fqdn, "localhost.$ddn", 'fqdn');
is(Device->search(name=>"localhost.$ddn")->first, $obj, 'search' );

my $obj2 = Device->insert({name=>'localhost2'});
ok(scalar(Device->search_like(name=>"local")) == 2, 'search_like' );

# This should give us $obj's name
my $rr = Device->assign_name(host=>'localhost');
is($rr->id, $obj->name, 'assign_name');

my $testcl = ContactList->insert({name=>'testcl'});
my @cls = $obj->add_contact_lists($testcl);
is($cls[0]->contactlist->name, $testcl->name, 'add_contact_lists');
$testcl->delete;

$obj->update({layers=>'00000010'});
is($obj->has_layer(2), 1, 'has_layer');

my $p = $obj->update_bgp_peering( peer=>{bgppeerid =>'10.0.0.1',
					 address   =>'172.16.5.5',
					 asname    => 'testAS',
					 asnumber  => '1000',
					 orgname   => 'testOrg'},
				  old_peerings=>{} );
is($p->bgppeerid, '10.0.0.1', 'update_bgp_peering');

my $newints = $obj->add_interfaces(1);
my @ints = $obj->interfaces();
is($ints[0], $newints->[0], 'add_interfaces');

my $newip = $obj->add_ip('10.0.0.1');
is($newip->address, '10.0.0.1', 'add_ip');

like(exception {
	 $obj2->add_ip('10.0.10.10');
}, qr/Need an interface to add this IP to/, 'cannot attach IP to device without interfaces');

my $newints2 = $obj2->add_interfaces(1);
my @ints2 = $obj2->interfaces();
is($ints2[0], $newints2->[0], 'add_interfaces to second device');

my $ip2 = $obj2->add_ip('10.0.10.10');
is($ip2->address, '10.0.10.10', 'add_ip 2');

is(Device->search(name=>"10.0.0.1")->first, $obj, 'search via IP' );
isnt(Device->search(name=>"10.0.0.2")->first, $obj, 'search via IP fails' );

my $devs = Device->get_all_from_block("10.0.0.0/16");
ok(@$devs >= 2, "get_all_from_block returns expected number of devices");
ok((grep { $_ eq $obj } @$devs), "get_all_from_block returns device attached to 10.0.0.1");
ok((grep { $_ eq $obj2 } @$devs), "get_all_from_block returns device attached to 10.0.10.10");

my $ts = $obj->timestamp;
$obj->update({collect_arp=>1});
$obj->arp_update(cache => {
    4 => { $ints[0] => { "192.168.52.46" => "7071BC115354",
			 "192.168.66.66" => "90fba62a3270" }},
    6 => { $ints[0] => { "2001:2010:1::beef" => "7071BC115354",
			 "2001:2010:1::f00f" => "90fba62a3270" }}
    }, timestamp => $ts);
my @ace = ArpHistory->search_interface($ints[0], $ts);
ok(@ace >= 4, "found new arp history entries");
ok(1 == (grep { $_->ipaddr->address eq "192.168.52.46" } @ace), "192.168.52.46 is in the results once");
ok(1 == (grep { $_->ipaddr->address eq "2001:2010:1::f00f" } @ace), "2001:2010:1::f00f is in the results once");
ok(2 == (grep { $_->physaddr->address eq "7071BC115354" } @ace), "7071BC115354 is in the results twice");
ok(2 == (grep { $_->physaddr->address eq "90FBA62A3270" } @ace), "90FBA62A3270 is in the results twice");
ok(1 == (grep { $_->ipaddr->address eq "192.168.66.66" } @ace), "192.168.66.66 is in the results once");
ok(1 == (grep { $_->ipaddr->address eq "2001:2010:1::beef" } @ace), "2001:2010:1::beef is in the results once");

my %to_clean;
%to_clean = (%to_clean, map { $_->ipaddr->address, $_->ipaddr } @ace);
%to_clean = (%to_clean, map { $_->physaddr->address, $_->physaddr } @ace);

sleep 2;
my $new_ts = $obj->timestamp;
$obj->arp_update(cache => {
    4 => { $ints[0] => { "192.168.52.46" => "7071BC115354" }},
    6 => { $ints[0] => { "2001:2010:1::f00f" => "90fba62a3270" }}
    }, timestamp => $new_ts);
@ace = ArpHistory->search_interface($ints[0], $new_ts);
ok(@ace >= 2, "found updated arp history entries");
ok(1 == (grep { $_->ipaddr->address eq "192.168.52.46" } @ace), "192.168.52.46 is in the updated results once");
ok(1 == (grep { $_->ipaddr->address eq "2001:2010:1::f00f" } @ace), "2001:2010:1::f00f is in the updated results once");
ok(1 == (grep { $_->physaddr->address eq "7071BC115354" } @ace), "7071BC115354 is in the updated results once");
ok(1 == (grep { $_->physaddr->address eq "90FBA62A3270" } @ace), "90FBA62A3270 is in the updated results once");
ok(0 == (grep { $_->ipaddr->address eq "192.168.66.66" } @ace), "192.168.66.66 is NOT in the updated results");
ok(0 == (grep { $_->ipaddr->address eq "2001:2010:1::beef" } @ace), "2001:2010:1::beef is NOT in the updated results");

%to_clean = (%to_clean, map { $_->ipaddr->address, $_->ipaddr } @ace);
%to_clean = (%to_clean, map { $_->physaddr->address, $_->physaddr } @ace);

my $ip2dev = Device->get_ips_from_all();
is($ip2dev->{"10.0.0.1"}, $obj->id, "10.0.0.1 correctly points to device 1");
is($ip2dev->{"10.0.10.10"}, $obj2->id, "10.0.10.10 correctly points to device 2");
is($ip2dev->{"8.8.8.8"}, undef, "8.8.8.8 correctly points to no devices");

like(exception {
	 $obj->get_ips(sort_by => "nogenting");
}, qr/Invalid sort criteria/, 'invalid sort criterium is invalid');
is($obj->get_ips()->[0]->address, "10.0.0.1", "get_ips()");
is($obj->get_ips(sort_by => "address")->[0]->address, "10.0.0.1", "get_ips(sort_by => 'address')");
is($obj->get_ips(sort_by => "addr")->[0]->address, "10.0.0.1", "get_ips(sort_by => 'addr')");
is($obj->get_ips(sort_by => "interface")->[0]->address, "10.0.0.1", "get_ips(sort_by => 'interface')");

# We need to insert a subnet first.
# is((values %{$obj->get_subnets})[0]->addr, "10.0.0.0/8", "get_subnets()");

my $peers = $obj->get_bgp_peers();
is(($peers->[0])->id, $p->id, 'get_bgp_peers');

# The Exporter get_device_info datastructure tests
$obj->set(monitored => 1);  ok($obj->update, "update without parameters");
my $exporter  = Netdot::Exporter->new();
isa_ok($exporter, 'Netdot::Exporter', 'Constructor');
$exporter->cache('exporter_device_info', ""); # hack: clear cache
my $xp = $exporter->get_device_info();
ok($xp, "Exporter->get_device_info returns something");
ok($xp->{$obj->id}, "first device is there");
ok(!$xp->{$obj2->id}, "second device is not there since it's not monitored");
ok($xp->{$obj->id}{interface}{$ints[0]->id}, "first device has an interface we expect");

my $ip1 = $obj->get_ips()->[0];
my $ipinfo = $xp->{$obj->id}{interface}{$ints[0]->id}{ip}{$ip1->id};
ok($ipinfo, "first device has the IP we expect");
is($ipinfo->{addr}, "10.0.0.1", "that IP has correct address, 10.0.0.1");
is($ipinfo->{version}, 4, "that IP has correct version, 4");
is($ipinfo->{subnet}, $ip1->parent->id, "that IP has correct subnet, ". $ip1->parent->addr);

$obj->delete;
isa_ok($obj, 'Class::DBI::Object::Has::Been::Deleted', 'delete');
$obj2->delete;

for (values %to_clean) {
    $_->delete;
}

done_testing();

