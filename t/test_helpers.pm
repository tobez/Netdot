package test_helpers;

use strict;
use warnings;
use Netdot::Config;
use Test::More;

our $original_getter;
our %config_overlay;
our $log_appender;

sub disable_logging
{
    $log_appender = bless {}, "my_appender";
    my $logger = Netdot->log->get_logger('Netdot');
    $logger->add_appender($log_appender);
    $logger->remove_appender("Syslog");
    Netdot->log->get_logger('Netdot')->level($Log::Log4perl::DEBUG);
    Netdot->log->get_logger('Netdot::Model::Ipblock')->level($Log::Log4perl::DEBUG);
}

sub main::logged_like {
    my ($log_re, $test) = @_;
    like($log_appender->{s}, $log_re, $test);
}

sub settable_config
{
    return if $original_getter;
    $original_getter = \&Netdot::Config::get;
    *Netdot::Config::set = sub {
	my ($self, $key, $value) = @_;
	$config_overlay{$key} = $value;
    };
    *Netdot::Config::get = sub {
	my ($self, $key) = @_;
	if (exists $config_overlay{$key}) {
	    return $config_overlay{$key};
	}
	return $original_getter->($self, $key);
    };
}

package my_appender;

sub name { "testing" }
sub log
{
    my ($me, $p) = @_;
    $me->{s} = ref($p->{message}) ? "@{$p->{message}}" : $p->{message};
}

1;
