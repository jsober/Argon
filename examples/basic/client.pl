use strict;
use warnings;
use Carp;
use Data::Dumper;
use EV;
use AnyEvent;
use Getopt::Std;
use Argon qw/LOG :commands/;

require Argon::Client;
require Argon::Message;
require SampleJob;

my %opt;
getopt('hpc', \%opt);

my $client = Argon::Client->new(
    host => $opt{h},
    port => $opt{p},
);

my $count = 0;
my $total = $opt{c} || 10;

sub inc {
    if (++$count == $total) {
        LOG('All results are in. Bye!');
        exit 0;
    }   
}

sub on_complete {
    my $num = shift;
    return sub {
        LOG('COMPLETE (%4d): %4d', $num, shift);
        inc;
    }
}

sub on_error {
    my $num = shift;
    return sub {
        LOG('ERROR (%4d): %s', $num, shift);
        inc;
    }
}

$client->connect(sub {
    warn "Connected!\n";
    foreach my $i (1 .. $total) {
        $client->process(
            class      => 'SampleJob',
            args       => [$i],
            on_success => on_complete($i),
            on_error   => on_error($i),
        );
    }
});

EV::run;