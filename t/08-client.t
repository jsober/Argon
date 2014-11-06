use strict;
use warnings;
use AnyEvent::Loop; # Ensure the pure perl loop is loaded for testing
use Test::More;
use List::Util qw(shuffle);
use Sub::Override;
use AnyEvent;
use Coro;
use Coro::AnyEvent;

use Argon qw(:logging);
use Argon::Client;
use Argon::Manager;
use Argon::Worker;

SET_LOG_LEVEL($FATAL);

sub test {
    my $n = shift || 0;
    return $n * $n;
}

SKIP: {
    skip 'does not run under MSWin32' if $^O eq 'MSWin32';

    my $manager_cv     = AnyEvent->condvar;;
    my $manager        = Argon::Manager->new();
    my $manager_thread = async { $manager->start(sub { $manager_cv->send(shift) }) };
    my $manager_addr   = $manager_cv->recv;

    like($manager_addr, qr/^[\w\.]+:\d+$/, 'manager address is set');

    my $worker_cv      = AnyEvent->condvar;
    my $worker         = Argon::Worker->new(manager => $manager_addr);
    my $worker_thread  = async { $worker->start(sub { $worker_cv->send }) };
    $worker_cv->recv;

    # Wait for worker to connect to manager.
    # TODO There's got to be a better way to do this. But if the worker thread blocks
    # while waiting for a manager connection, the manager cannot connect because the
    # worker startup doesn't cede.
    Coro::AnyEvent::sleep(3);

    my $client = Argon::Client->new(host => $manager->host, port => $manager->port);
    $client->connect;

    # Server status
    my $status   = $client->server_status;
    my $expected = {
        workers          => 1,
        total_capacity   => $worker->workers,
        current_capacity => $worker->workers,
        queue_length     => 0,
        pending          => {$worker->key => {}},
    };

    is_deeply($status, $expected, 'expected server status');

    my @range = 1 .. 20;

    # Test queue, collect, and server_status
    foreach my $i (@range) {
        my $overrid = Sub::Override->new('Argon::Tracker::age', sub { 42 });

        ok(my $msgid = $client->queue(\&test, [$i]), "queue $i");

        my $status = $client->server_status;
        my $result = $client->collect($msgid);

        my $expected = {
            workers          => 1,
            total_capacity   => $worker->workers,
            current_capacity => $worker->workers - 1,
            queue_length     => 0,
            pending          => { $worker->key => { $msgid => 42 } },
        };

        is($result, ($i * $i), "queue => collect result $i");
        is_deeply($status, $expected, "server_status $i");
    }

    # Test process
    foreach my $i (@range) {
        my $result = $client->process(\&test, [$i]);
        is($result, ($i * $i), "process result $i");
    }

    # Test defer
    my %deferred = map { $_ => $client->defer(sub { $_[0] * $_[0] }, [$_]) } @range;
    my %results  = map { $_ => $deferred{$_}->() } keys %deferred;
    foreach my $i (shuffle @range) {
        is($results{$i}, $i * $i, "defer result $i");
    }

    $client->shutdown;
    $worker->stop;
    $manager->stop;

    $manager_thread->join;
    $worker_thread->join;
};

done_testing;
