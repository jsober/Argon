#-------------------------------------------------------------------------------
# MessageManagers forward tasks to a series of servers. Essentially, they act
# as a pool of client objects. The targets may be any kind of MessageServer
# service. Managers track the speed and responsiveness of their servers and
# route tasks to the most available server.
#-------------------------------------------------------------------------------
package Argon::MessageManager;

use Moose;
use Carp;
use namespace::autoclean;
use List::Util qw/sum/;
use AnyEvent   qw//;
use Argon      qw/:commands TRACK_MESSAGES/;

require Argon::Client;

extends 'Argon::MessageProcessor';
with    'Argon::QueueManager';

# List of Argon::Client instances
has 'servers' => (
    is       => 'rw',
    isa      => 'ListRef',
    default  => sub { [] },
    init_arg => undef,
);

# Hash of msg id => server; tracks what messages are assigned where
has 'assigned_to' => (
    is       => 'ro',
    isa      => 'HashRef',
    default  => sub { {} },
    init_arg => undef,
);

# Hash of server => list of msg ids; tracks assignments to a server
has 'assignments' => (
    is       => 'ro',
    isa      => 'HashRef',
    default  => sub { {} },
    init_arg => undef,
);

# Hash of server => list of last N processing times
has 'processing_times' => (
    is       => 'ro',
    isa      => 'HashRef',
    default  => sub { {} },
    init_arg => undef,
);

# Hash of server => precalculated avg processing time
has 'avg_processing_time' => (
    is       => 'ro',
    isa      => 'HashRef',
    default  => sub { {} },
    init_arg => undef,
);

#-------------------------------------------------------------------------------
# Required by the QueueManager role, this method processes queue items by
# assigning them to the next available client.
#-------------------------------------------------------------------------------
sub process_message {
    my ($self, $message) = @_;
    $self->assign($message, $self->next_client);
}

#-------------------------------------------------------------------------------
# Adds a new client object to the manager.
#-------------------------------------------------------------------------------
sub add_client {
    my ($self, $client) = @_;

    $client->connect(sub {
        push @{$self->servers}, $client;
        $self->assignments->{$client}         = [];
        $self->processing_times->{$client}    = [];
        $self->avg_processing_time->{$client} = 0;
    });

    # TODO: add on_error handler
}

#-------------------------------------------------------------------------------
# Removes a client object from the manager.
#-------------------------------------------------------------------------------
sub del_client {
    my ($self, $client) = @_;

    foreach my $id (@{$self->assignments->{$client}}) {
        my $msg   = $self->message->{$id};
        my $reply = $msg->reply(CMD_ERROR);
        $self->msg_complete($reply);
    }

    $self->servers([ map {$_ ne $client} @{$self->servers} ]);
    undef $self->assignments->{client};
    undef $self->processing_times->{$client};
    undef $self->avg_processing_time->{$client};
    $client->destroy;
}

#-------------------------------------------------------------------------------
# Calculates the amount of processing time required by a tracked service to
# process all items currently assigned to it.
#-------------------------------------------------------------------------------
sub estimated_processing_time {
    my ($self, $client) = @_;
    return $self->avg_processing_time->{$client}
         * scalar(@{$self->assignments->{$client}});
}

#-------------------------------------------------------------------------------
# Returns the next most available client.
# TODO account for servers which may be inaccessible
#-------------------------------------------------------------------------------
sub next_client {
    my $self = shift;

    my %time;
    $time{$_} = $self->estimated_processing_time($_) foreach @{$self->servers};

    my $least;
    foreach my $server (@{$self->servers}) {
        if (!defined $least || $time{$server} < $time{$least}) {
            $least = $server;
        }
    }

    return $least;
}

#-------------------------------------------------------------------------------
# Assigns a message to the selected client.
#-------------------------------------------------------------------------------
sub assign {
    my ($self, $msg, $client) = @_;
    push @{$self->assignments->{$client}}, $msg->id;

    $self->msg_assigned($msg);
    my $sent = AnyEvent->now;

    $client->send($msg, sub {
        my ($client, $msg) = @_;

        push @{$self->processing_times->{$client}}, (AnyEvent->now - $sent);
        shift @{$self->processing_times->{$client}}
            if @{$self->processing_times->{$client}} > TRACK_MESSAGES;

        $self->avg_processing_time->{$client} = sum(@{$self->processing_times->{$client}}) / TRACK_MESSAGES;
        $self->msg_complete($msg);
    });
}

__PACKAGE__->meta->make_immutable;

1;