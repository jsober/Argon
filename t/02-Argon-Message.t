use strict;
use warnings;
use Carp;

use Test::More tests => 8;

require_ok('Argon::Message');
use_ok('Argon::Message');

use Argon qw/:priorities :commands/;
    
my $pri = PRI_LOW;
my $cmd = CMD_QUEUE;
my $pay = { foo => 'bar', secret => 42 };
    
# Construction
my $msg = Argon::Message->new(priority => $pri, command => $cmd);
$msg->set_payload($pay);

ok($msg->id, 'New message gets ID');
is_deeply($pay, $msg->get_payload, 'Getter/setter consistency for payload');

# Encoding / Decoding
my $decoded = Argon::Message::decode($msg->encode);
$decoded->get_payload; # force decoding of payload
is_deeply($msg, $decoded, 'Encode/decode consistency');

# Reply
my $reply = $msg->reply(CMD_ACK);
ok($reply->command eq CMD_ACK, 'Reply constructed correctly');
ok(!defined $reply->get_payload, 'Reply does not contain payload');
ok($reply->id eq $msg->id, 'Reply reuses id');