package test_helpers;

use Log::Log4perl::Appender::TestArrayBuffer;
use Netdot::Config;

sub disable_logging
{
	my $appender = Log::Log4perl::Appender::TestArrayBuffer->new(name => 'buffer');
	my $logger = Netdot->log->get_logger('Netdot');
	$logger->add_appender($appender);
	$logger->remove_appender("Syslog");
}

our $original_getter;
our %config_overlay;

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

1;
