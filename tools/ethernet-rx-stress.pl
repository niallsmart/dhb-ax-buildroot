#!/usr/bin/env perl
# Drive the receive reproducer from the development host and stop as soon as
# the board stops taking data.
#
# Runs here rather than on the board: a receive stall takes SSH with it, so
# nothing running there can report one.  The iperf3 client keeps running and
# its own interval output is the stall signal.  --forceflush matters, because
# iperf3 block-buffers into a pipe and the abort would otherwise arrive tens
# of seconds late.
#
# Exit 0 ran to completion, 2 stalled, 3 iperf3 carried no data.
#
# usage: ethernet-rx-stress.pl HOST [STREAMS] [SECONDS] [ZERO_INTERVALS]
use strict;
use warnings;

my ($host, $streams, $secs, $need) = (shift, shift // 4, shift // 45, shift // 3);
die "usage: $0 HOST [STREAMS] [SECONDS] [ZERO_INTERVALS]\n" unless defined $host;

my $start = time;
my $pid = open(my $fh, "-|", "iperf3", "-c", $host, "-P", $streams, "-t", $secs,
               "-i", "1", "-f", "m", "--forceflush") or die "spawn iperf3: $!";

my $zeros   = 0;   # consecutive zero-rate intervals
my $seen    = 0;   # intervals that carried data
my $last    = 0;   # end time of the last interval with data
my $stalled = 0;

while (my $line = <$fh>) {
    print $line;
    next unless $line =~
        /^\[SUM\]\s+([\d.]+)-\s*([\d.]+)\s+sec\s+\S+\s+\S+\s+([\d.]+)\s+Mbits/;
    my ($to, $rate) = ($2, $3);
    if ($rate == 0) {
        if (++$zeros >= $need) { $stalled = 1; kill 'TERM', $pid; last }
    } else {
        $zeros = 0;
        $seen++;
        $last = $to;
    }
}
close $fh;
my $rc = $?;
kill 'KILL', $pid;

my $wall = time - $start;
if (!$seen) {
    printf "\n*** ERROR: iperf3 carried no data (exit %d) after %d s\n", $rc, $wall;
    exit 3;
}
if ($stalled) {
    printf "\n*** STALLED: last data at %.0f s, %d idle intervals, aborted %d s wall\n",
        $last, $need, $wall;
    exit 2;
}
printf "\n*** completed %d s, no stall (%d s wall)\n", $secs, $wall;
exit 0;
