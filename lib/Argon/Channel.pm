package Argon::Channel;
# ABSTRACT: Line protocol API for non-blocking sockets

=head1 DESCRIPTION

Internal class implementing the line protocol API used for non-blocking socket
connections.

=head1 SYNOPSIS

  my $ch = Argon::Channel->new(
    fh => $socket,
    on_msg => sub {...},
    on_close => sub {...},
    on_err => sub {...}
  );

  $ch->send(Argon::Message->new(...));

=cut

use strict;
use warnings;
use Carp;
use Moose;
use AnyEvent;
use AnyEvent::Handle;
use Argon::Constants qw(:defaults :commands);
use Argon::Log;
use Argon::Marshal qw();
use Argon::Types;
use Argon::Util qw(K);
require Argon::Message;

=head1 ATTRIBUTES

=head2 fh

File handle for the connected socket. Assumed to be non-blocking.

=cut

has fh => (
  is       => 'ro',
  isa      => 'FileHandle',
  required => 1,
);

=head2 on_msg

A code ref that is called when a new L<Argon::Message> arrives. The message is
passed as the only argument.

=cut

has on_msg => (
  is     => 'rw',
  isa    => 'Ar::Callback',
  default => sub { sub{} },
);

=head2 on_close

A code ref that is called when the connection is closed.

=cut

has on_close => (
  is      => 'rw',
  isa     => 'Ar::Callback',
  default => sub { sub{} },
);

=head2 on_err

A code ref that is called when an error occurs during socket communication. The
error message is passed as the only argument.

=cut

has on_err => (
  is      => 'rw',
  isa     => 'Ar::Callback',
  default => sub { sub{} },
);

has handle => (
  is      => 'ro',
  isa     => 'Maybe[AnyEvent::Handle]',
  lazy    => 1,
  builder => '_build_handle',
  handles => {
    disconnect => 'push_shutdown',
  },
);

sub _build_handle {
  my $self = shift;
  AnyEvent::Handle->new(
    fh       => $self->fh,
    on_read  => K('_read',  $self),
    on_eof   => K('_eof',   $self),
    on_error => K('_error', $self),
  );
}

=head1 METHODS

=cut

sub BUILD {
  my ($self, $args) = @_;
  $self->handle;
}

sub _eof {
  my ($self, $handle) = @_;
  $self->on_close->();
  undef $self->{handle};
}

sub _error {
  my ($self, $handle, $fatal, $msg) = @_;
  log_debug 'Network error: %s', $msg;
  $self->on_err->($msg);
  $self->disconnect;
}

sub _read {
  my $self = shift;
  $self->handle->push_read(line => $EOL, K('_readline', $self));
}

sub _readline {
  my ($self, $handle, $line) = @_;
  my $msg = $self->decode_msg($line);
  $self->recv($msg);
}

sub recv {
  my ($self, $msg) = @_;
  log_trace 'recv: %s', $msg->explain;
  $self->on_msg->($msg);
}

=head2 send

Sends an L<Argon::Message> over the socket.

=cut

sub send {
  my ($self, $msg) = @_;
  log_trace 'send: %s', $msg->explain;

  my $line = $self->encode_msg($msg);

  eval {
    $self->handle->push_write($line);
    $self->handle->push_write($EOL);
  };

  if (my $error = $@) {
    log_error 'send: remote host disconnected';
    log_debug 'error was: %s', $error;
    $self->_eof;
  };
}

sub encode_msg { Argon::Marshal::encode_msg($_[1]) }
sub decode_msg { Argon::Marshal::decode_msg($_[1]) }

__PACKAGE__->meta->make_immutable;

1;
