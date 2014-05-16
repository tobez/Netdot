use strict;
use Test::More qw(no_plan);
use lib "lib";

BEGIN { use_ok('Netdot::Model::PhysAddr'); }

my $obj = PhysAddr->insert({address=>'DE:AD:DE:AD:BE:EF'});
isa_ok($obj, 'Netdot::Model::PhysAddr', 'insert');

is($obj->address, 'DEADDEADBEEF', 'address');
is($obj->colon_address, 'DE:AD:DE:AD:BE:EF', 'address');

my $mac2id = PhysAddr->to_id([qw(DE:AD:DE:AD:BE:EF 7071BC115354)]);
ok($mac2id, "to_id returns");
is(keys %$mac2id, 1, "to_id returns the right number of keys");
is($mac2id->{"0876FF4888E1"}, undef, "to_id: did not ask, did not get");
is($mac2id->{"7071BC115354"}, undef, "to_id: asked but not found");
is($mac2id->{"DEADDEADBEEF"}, $obj->id, "to_id: got correct ID");

$obj->delete;
