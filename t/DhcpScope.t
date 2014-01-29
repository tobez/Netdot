use strict;
use Test::More;
use Test::Fatal;
use lib "lib";

BEGIN { 
    use_ok('Netdot::Model::DhcpScope'); 
    use_ok('Netdot::Model::Ipblock'); 
}

my $subnet = Ipblock->insert({
    address => "8.8.8.0",
    prefix  => '24',
    version => 4,
    status  => 'Subnet',
});
ok($subnet, "subnet insert");

my $global = DhcpScope->insert({name=>'t/DhcpScope.t', type=>'global'});
ok($global, "DHCP global scope insert");

like(exception {
    my $x = DhcpScope->insert({name=>'t/DhcpScope.t', type=>'global'});
}, qr/DHCP scope.*already exists/, 'cannot insert existing scope');

my $ip = '8.8.8.8';

like(exception {
     my $x = DhcpScope->insert({container=>$global, name=>$ip, type=>'host', ipblock=>$ip, physaddr=>'deaddeadbeef'});
}, qr/Subnet .* not dhcp-enabled/, 'subnet not dhcp-enabled');

my $subnet_scope = DhcpScope->insert({container=>$global, name=>"8.8.8.0/24", type=>'subnet', ipblock=>$subnet});
ok($subnet_scope, "subnet scope insert");

my $host_scope = DhcpScope->insert({container=>$global, name=>$ip, type=>'host', ipblock=>$ip, physaddr=>'deaddeadbeef'});

isa_ok($host_scope, 'Netdot::Model::DhcpScope', 'host scope insert');

is(DhcpScope->search(name=>$ip)->first, $host_scope, 'search host_scope' );

is($host_scope->container, $global, 'host scope container');
is($subnet_scope->container, $global, 'subnet scope container');

$global->delete(recursive => 1);
$subnet->delete(recursive => 1);

done_testing();
