package Argon::Server;

use strict;
use warnings;
use Carp;

use Moose;
use MooseX::StrictConstructor;
use namespace::autoclean;

use AnyEvent;
use Coro;
use Coro::AnyEvent;
use IO::Socket::INET;
use Socket qw/getnameinfo/;

use Argon::Stream;
use Argon::Message;
use Argon::Queue;
use Argon qw/:commands LOG K/;

has 'port' => (
    is       => 'ro',
    isa      => 'Int',
    required => 1,
);

has 'host' => (
    is       => 'ro',
    isa      => 'Str',
    default  => 'localhost',
);

#-------------------------------------------------------------------------------
# Stores callbacks for a given command.
#-------------------------------------------------------------------------------
has 'handler' => (
    is       => 'ro',
    isa      => 'HashRef[CodeRef]',
    init_arg => undef,
    default  => sub {{}},
    traits   => ['Hash'],
    handles  => {
        respond_to  => 'set',
        get_handler => 'get',
        has_handler => 'exists',
        handles     => 'keys',
    }
);

#-------------------------------------------------------------------------------
# Flags the stream->address as currently being serviced. If the flag is deleted,
# the service loop for the stream will self-terminate. If unset from within a
# response-handler, any message returned by the handler will be sent before the
# loop terminates.
#-------------------------------------------------------------------------------
has 'service_loop' => (
    is       => 'ro',
    isa      => 'HashRef[Int]',
    init_arg => undef,
    default  => sub {{}},
    traits   => ['Hash'],
    handles  => {
        set_service => 'set',
        get_service => 'get',
        del_service => 'delete',
        has_service => 'exists',
    }
);

#-------------------------------------------------------------------------------
# Queue size limit. When the queue is at maximum capacity, tasks are rejected.
#-------------------------------------------------------------------------------
has 'queue_limit' => (
    is       => 'ro',
    isa      => 'Int',
    required => 1,
);

#-------------------------------------------------------------------------------
# Queue check time (float seconds). Controls the length of time a message may
# spend in the queue before it's priority is increased to prevent starvation.
#-------------------------------------------------------------------------------
has 'queue_check' => (
    is       => 'ro',
    isa      => 'Num',
    required => 1,
);

#-------------------------------------------------------------------------------
# Task queue storing tuples of [Argon::Stream, Argon::Message].
#-------------------------------------------------------------------------------
has 'queue' => (
    is       => 'rw',
    isa      => 'Argon::Queue',
    init_arg => undef,
    builder  => 'build_queue',
    lazy     => 1,
    handles  => {
        'queue_put'     => 'put',
        'queue_get'     => 'get',
        'queue_is_full' => 'is_full',
        'queue_filter'  => 'filter',
    }
);

#-------------------------------------------------------------------------------
# Queue constructor.
#-------------------------------------------------------------------------------
sub build_queue {
    my $self = shift;
    return Argon::Queue->new(
        limit => $self->queue_limit,
        check => $self->queue_check,
    );
}

#-------------------------------------------------------------------------------
# Starts the server listening for new requests.
#-------------------------------------------------------------------------------
sub start {
    my $self = shift;

    my $sock = IO::Socket::INET->new(
        LocalAddr => $self->host,
        LocalPort => $self->port,
        Proto     => 'tcp',
        Type      => SOCK_STREAM,
        Listen    => $Argon::LISTEN_QUEUE_SIZE,
        ReuseAddr => 1,
        Blocking  => 0,
    );

    unless ($sock) {
        LOG('Error creating server socket: %s', $!);
        exit 1;
    }

    $sock->listen or croak $!;
    LOG('Starting service on %s:%d (queue limit: %d, starvation check: %0.2fs)',
        $self->host,
        $self->port,
        $self->queue_limit,
        $self->queue_check,
    );

    async { $self->process_messages };

    while (1) {
        Coro::AnyEvent::readable($sock);
        my $client = $sock->accept;
        my $stream = Argon::Stream->new(fh => $client);
        $self->service($stream);
    }
}

#-------------------------------------------------------------------------------
# Consumer thread. Loops on Argon::Queue->get, dispatching messages and sending
# the results back to the originating stream.
#-------------------------------------------------------------------------------
sub process_messages {
    my $self = shift;
    while (1) {
        my ($stream, $msg) = @{ $self->queue_get };
        async {
            my $reply = $self->dispatch($msg, $stream);
            $self->reply($stream, $reply);
        };
    }
}

#-------------------------------------------------------------------------------
# Helper method to send a message to a stream. Traps connection errors.
#-------------------------------------------------------------------------------
sub reply {
    my ($self, $stream, $reply) = @_;
    if ($reply->isa('Argon::Message')) {
        eval { $stream->send_message($reply) };
        if ($@ && Argon::Stream::is_connection_error($@)) {
            # pass - stream is disconnected and producer thread
            # (Argon::Server->service) will self-terminate.
        } elsif ($@) {
            LOG('Error sending reply: %s', $@);
        }
    }
}

#-------------------------------------------------------------------------------
# Launches a new coro to handle incoming requests from a stream.
#-------------------------------------------------------------------------------
sub service {
    my ($self, $stream) = @_;
    my $addr = $stream->address;

    $self->set_service($addr, 1);

    async {
        while ($stream->is_connected && $self->has_service($stream->address)) {
            # Pull next message. On failure, stop serving stream.
            my $msg = $stream->next_message or last;

            if ($self->queue_is_full) {
                my $reply = $msg->reply(CMD_REJECTED);
                $self->reply($stream, $reply);
            } else {
                $self->queue_put([$stream, $msg], $msg->priority);
            }
        }

        $self->stop_service($stream->address);
    };
}

#-------------------------------------------------------------------------------
# Removes a stream from the service set.
#-------------------------------------------------------------------------------
sub stop_service {
    my ($self, $stream) = @_;
    $self->del_service($stream);
    $self->queue_filter(sub { $_->[0] ne $stream });
}

#-------------------------------------------------------------------------------
# Dispatches a message to registered callbacks based on the message's command.
#-------------------------------------------------------------------------------
sub dispatch {
    my ($self, $msg, $stream) = @_;
    if ($self->has_handler($msg->command)) {
        return $self->get_handler($msg->command)->($msg, $stream);
    } else {
        LOG('Warning: command not handled - %d', $msg->command);
        my $reply = $msg->reply(CMD_ERROR);
        $reply->set_payload('Command not handled');
        return $reply;
    }
}

no Moose;
__PACKAGE__->meta->make_immutable;

1;