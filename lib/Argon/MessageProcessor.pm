#-------------------------------------------------------------------------------
# MessageProcessors track message status.
#-------------------------------------------------------------------------------
package Argon::MessageProcessor;

use Moose;
use Carp;
use namespace::autoclean;
use Argon qw/LOG :commands :statuses/;

require Argon::MessageQueue;
require Argon::Message;

# Hash of msg id => msg
has 'message' => (
    is       => 'ro',
    isa      => 'HashRef[Argon::Message]',
    init_arg => undef,
    default  => sub { {} },
);

# Hash of msg id => STATUS_*
has 'status' => (
    is       => 'ro',
    isa      => 'HashRef[Int]',
    init_arg => undef,
    default  => sub { {} },
);

#-------------------------------------------------------------------------------
# When a message has been accepted, this method is called to updated tracking.
#-------------------------------------------------------------------------------
sub msg_accept {
    my ($self, $msg) = @_;
    $self->message->{$msg->id} = $msg;
    $self->status->{$msg->id}  = STATUS_QUEUED;
    LOG('Accepted: %s', $msg->id);
}

#-------------------------------------------------------------------------------
# When a message has been assigned, this method is called to update tracking.
#-------------------------------------------------------------------------------
sub msg_assigned {
    my ($self, $msg) = @_;
    $self->message->{$msg->id} = $msg;
    $self->status->{$msg->id}  = STATUS_ASSIGNED;
    LOG('Assigned: %s', $msg->id);
}

#-------------------------------------------------------------------------------
# When a message is complete, this method is called to update tracking.
#-------------------------------------------------------------------------------
sub msg_complete {
    my ($self, $msg) = @_;
    $self->message->{$msg->id} = $msg;
    $self->status->{$msg->id}  = STATUS_COMPLETE;
    LOG('Complete: %s', $msg->id);
}

#-------------------------------------------------------------------------------
# When a complete message is collected, this method is called to clear tracking
# data. Returns the last stored version of the message.
#-------------------------------------------------------------------------------
sub msg_clear {
    my ($self, $msg) = @_;
    my $result = $self->message->{$msg->id};
    undef $self->message->{$msg->id};
    undef $self->status->{$msg->id};
    LOG('Cleared: %s', $msg->id);
    return $result;
}

__PACKAGE__->meta->make_immutable;

1;