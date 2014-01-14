use strict;
use Test::More;
use Test::Fatal;
use lib "lib";

BEGIN { use_ok('Netdot::Model::Device'); }

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

$obj->delete;
isa_ok($obj, 'Class::DBI::Object::Has::Been::Deleted', 'delete');
$obj2->delete;

done_testing();

