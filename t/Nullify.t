use strict;
use warnings;
use Test::More;
use lib "lib";
use Data::Dumper;

BEGIN { use_ok('Netdot::Model'); }

# Ipblock
my $subnet = Ipblock->insert({address => '1.1.1.0',
                              prefix => 24,
                              status => 'Subnet'});
my $subnet_id = $subnet->id;
ok(defined $subnet, 'subnet insert');

$subnet->set('description', 'test1');
ok($subnet->update, "update without params returns success");
undef $subnet;
$subnet = Ipblock->retrieve($subnet_id);
is($subnet->description, 'test1', 'update without params');

ok($subnet->update({description => 'test2'}), "update with params returns success");
undef $subnet;
$subnet = Ipblock->retrieve($subnet_id);
is($subnet->description, 'test2', 'update with params');

eval {
    my $vlan = Vlan->insert({name => 'test vlan',
                             vid => 1});
    ok(defined $vlan, "vlan insert");

    $subnet->update({vlan => $vlan});
    is($subnet->vlan, $vlan, 'set vlan to subnet');

    $vlan->delete;
    undef $subnet;
    $subnet = Ipblock->retrieve($subnet_id);
    ok(!$subnet->vlan, 'nullify');
};
fail($@) if $@;

$subnet->delete;

done_testing;
