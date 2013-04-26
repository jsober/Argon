#!/usr/bin/env perl

use strict;
use warnings;
use Carp;

use EV;
use Getopt::Long;
use Pod::Usage;
use Argon::Cluster;

# Default values
my $help  = 0;
my $limit = 64;
my $port;

my $got_options = GetOptions(
    'help'    => \$help,
    'limit=i' => \$limit,
    'port=i'  => \$port,
);

if (!$got_options || $help || !$port) {
    pod2usage(2);
    exit 1 if !$got_options || !$port;
    exit 0;
}

my $cluster = Argon::Cluster->new(
    port        => $port,
    queue_limit => $limit,
);

$cluster->start;

EV::run();

exit 0;
__END__

=head1 NAME

cluster.pl - runs an Argon cluster

=head1 SYNOPSIS

cluster.pl -p 8888 [-q 50] [-c 2]

 Options:
   -[p]ort          port on which to listen
   -[l]limit        max items permitted to queue (optional; default 64)
   -[c]heck         seconds before queue reprioritization (optional; default 2)
   -[h]elp          prints this help message

=head1 DESCRIPTION

B<cluster.pl> runs an Argon cluster on the selected port.

=head1 OPTIONS

=over 8

=item B<-[h]elp>

Print a brief help message and exits.

=item B<-[p]ort>

The port on which the cluster listens.

=item B<-[l]imit>

Sets the maximum number of messages which may build up in the queue before new
tasks are rejected. Optional; default value 64.

=back

=cut