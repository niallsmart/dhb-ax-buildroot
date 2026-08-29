# Hi3531 RX wedge

`eth0` stops receiving permanently under sustained inbound load.  The link
stays up at 1000 Mb/s, transmit keeps working, and no counter or log message
moves.  This plan diagnoses the mainline driver.  The vendor 3.0.8 kernel is a
runtime comparison point, used only where a mainline-only measurement cannot
answer the question.

Register-level evidence is in
`artifacts/diagnostics/ethernet-wedge-20260828-hard-reset/README.md`.
Throughput work unrelated to the wedge is in
[optimizing-network-throughput.md](optimizing-network-throughput.md).

## The fault

Descriptor exhaustion does not seem to be recoverable on this SoC.  When the RX ring runs
dry the DMA sets RU in CSR5 and moves the receive process to state 4.  From
there it ignores receive poll demand, the DMA start/stop bit, the MAC receiver
enable, and a channel software reset.  Only a software reset of all three DMA
channels clears it — the same cure `hi3531_reset_dma_channels()` already
applies at probe.

Patches 0015 and 0016 make it visible and self-clearing: RU and
receive-process-stopped are unmasked, the state is recorded, and the
three-channel reset is installed as this instance's DMA reset so the core's
own close and reopen is the cure.  The fault itself is untouched.

We have not verified whether the vendor Linux has somehow avoided or recovered from this
condition. That would seem to be required to copper-fasten whether the above is somehow
triggered by the driver, or is a lower-level hardware issue.

## Established

Verified on kernel 6.18.42, Debian initramfs, GMAC1 on DMA channel 1.

- The wedge is ordinary descriptor exhaustion.  A 10 ms sampler caught the
  transition: healthy at t=14.7650 (receive state 7, FIFO below threshold),
  RU set and state 4 at t=14.7749, CSR19 frozen from then on.
- In the wedged state all 512 descriptors carry OWN, so buffers are available
  to the DMA and there is nothing to resume for.  CSR8 counts no missed frames
  and no FIFO overflows.  The AHB/AXI status register is zero.
- Recovery matrix, applied live: poll demand, SR clear/set, MAC RE clear,
  channel-1 SWR and `ip link` down/up all fail.  Three-channel SWR plus
  `ip link up` recovers, 2 runs out of 2.
- `0014-net-stmmac-size-the-hi3531-rx-ring-for-burst-receive.patch` sets the
  probe-time ring to 1024.  At 512 a four-stream inbound TCP test wedged 4 runs
  out of 4 after 40-110 MB; at 1024 it sustained 3.27 GB at 468 Mbit/s and a
  6.29 GB UDP flood, RU never set across 12,025 samples.  Four-stream
  throughput rose from 386-392 to 468 Mbit/s.
- `ethtool -G eth0 rx 1024` on a healthy interface wedges receive by a second
  route: CSR19 walks addresses outside the ring CSR3 points at.  Never use it
  to select a test ring size; select at probe.
- Single-flow UDP does not stress the descriptor path.  At 400 Mbit/s offered,
  1472-byte payloads, the vendor received 201 Mbit/s (49% loss) and
  mainline-1024 received 233 Mbit/s (41% loss).  Both ended in receive state 7
  with essentially the whole ring DMA-owned, and neither trace contained an RU
  sample.  Received throughput pins near 230 Mbit/s regardless of offered rate,
  so the excess is dropped upstream of the DMA.
- Vendor boot defaults, captured 2026-08-28: RX/TX rings 256/256, RX checksum
  offload on (fixed), GRO on, pause frames off both directions, IRQ 119 on
  CPU0, DMA channel-1 interrupt mask `0x0001a061`, bus mode `0x00201000`,
  operation mode `0x03202002`.
- Detect-and-recover works.  Four-stream inbound TCP on a 512-entry ring
  wedged and recovered, and the transfer ran to completion: 2.16 GB at
  412 Mbit/s over 45 s, where the same test used to stop for good after
  40-110 MB.  Recovery costs about 3.5 s, nearly all of it PHY
  renegotiation after the reopen.
- A 1024-entry ring wedges too.  One RU in a 45 s four-stream run, 2.12 GB
  at 404 Mbit/s.  The earlier reading of "RU never set across 12,025
  samples" was the 10 ms sampler missing it; the interrupt sees every one.
  The larger ring lowers the rate, it does not remove the fault.
- Unmasking RU is only safe if it is masked again at the wedge.  The
  condition survives the interrupt being acknowledged, so the channel
  re-interrupts as fast as the handler can clear it.  0016 masks both
  sources when it asks for the reset; `hi3531_dma_init_chan()` re-arms them
  on reopen.  That removed the interrupt storm but not the stall it was
  blamed for -- see the repeated-recovery entry below.
- Repeated recovery stalls the board.  After a few successful recoveries a
  later one never completes: CPU0 stays in `stmmac_napi_poll_rx` with
  interrupts on, RCU reports the stall, and `page_pool_release_retry()`
  reports the same pool stuck with 1345 inflight pages for minutes.  It took
  the fifth wedge in one session and the third in another, and both times
  the fatal one arrived a few seconds after a completed recovery (link up at
  312.5 s, wedge at 318.6 s).  The board needs `sysrq-b`.  The suspect is
  the page pool: `dev_close` cannot reclaim RX pages the wedged DMA still
  holds, so every cycle leaks a poolful.
- The reproducer is four-stream inbound TCP against `iperf3 -s`, ring 512,
  30 to 45 s.  It wedged 3 runs out of 3, first wedge between 1.3 s and 19 s
  in, at 30k received pps and 320-350 Mbit/s.
- Smaller frames do not bring the wedge on; they push it away.  Received pps
  saturates near 38k whatever the frame size, so shrinking frames only lowers
  the bit rate, and the ring drains less.  Ring 512, four streams, 30 s, frame
  size set with `ip link set eth0 mtu` on the board because macOS rejects
  `iperf3 -M`:

      MTU 1500   348 Mbit/s   30353 pps   1435 B   low-water  24   wedged at 1.3 s
      MTU 1000   293 Mbit/s   36144 pps   1014 B   low-water  34   no wedge
      MTU  600   192 Mbit/s   39058 pps    614 B   low-water  91   no wedge
      MTU  400   126 Mbit/s   38181 pps    414 B   low-water 162   no wedge

  Bytes per second is what empties the ring here, not packets per second.
- `ethtool -S eth0` reports `rx_desc_low_water`, the fewest descriptors seen
  in the DMA's hands since the previous read.  It is measured from CSR19,
  because cur_rx and dirty_rx describe only the driver's own progress.
- `dwmac_hi3531.rx_ring_size=` selects the probe-time ring, 64 to 1024.
- GMAC debug at the wedge reads `0x00000117`, `0x00000120` or `0x00000137`
  across five events, not the `0x00000220` recorded on 2026-08-28.
- Recovery in place works and is much cheaper than closing and reopening.
  0016 rebuilds the DMA around the rings it already has, so the page pool
  survives and the link is never dropped.  Six 45 s four-stream runs at 512
  took 15 wedges and recovered from all of them, at 463-489 Mbit/s received
  and 38-40k pps, against 319-360 Mbit/s when each recovery cost a PHY
  renegotiation.  Three of those wedges fell inside 105 ms of each other.
  No RCU stall, no page-pool message, memory flat across the six runs.
- The in-place reset has to stop in the order `__stmmac_release()` uses:
  `napi_disable`, then the transmit timers, then `netif_tx_disable`, with
  `priv->lock` held only across the rebuild.  Taking the transmit queue
  first hangs the board a few wedges in, between `rtnl_lock()` and
  `stmmac_hw_setup()`, with no stall reported and a console that stops
  answering even a serial break.
- The three-channel reset clears GMAC1's control register along with the
  DMA: a 1000/full interface reads `0x0061080c` there and reads zero
  afterwards.  Opening the interface does not care, because phylink
  programs speed and duplex on link-up, but an in-place reset never gets
  that call.
- `GMAC_CORE_INIT` asserts port select unconditionally, which selects MII.
  Restoring the link bits before `stmmac_core_init()` runs is not enough --
  the register came back `0x0061880c` and receive stayed dead against a
  1000 Mb/s link.  0016 overrides `core_init` to put the three bits back
  afterwards.
- The ring is emptied by an occasional stall, not by a rising steady load.
  Sampling `rx_desc_low_water` once a second across 96 to 422 Mbit/s received
  at rings of 256, 512 and 1024 puts the median backlog at 52 to 80
  descriptors below 300 Mbit/s, and at the same value for all three ring
  sizes.  Raising the ring does not lower the steady depth, because arrival
  rate alone sets it.  What grows with rate is the worst second: at 374
  Mbit/s and 31k pps on a 1024 ring the backlog reaches 551 in one second out
  of thirty while the other twenty-nine sit near 72.  That is 18 ms of
  arrivals during which nothing was handed back to the DMA.
- Ring size buys headroom against that excursion and nothing else.  At 370
  Mbit/s received, 256 wedges four times in 30 s, 512 once and 1024 not at
  all; with the sender unthrottled, eight, three and none.  A ring smaller
  than the excursion truncates the measurement, because the wedge is what
  happens when the excursion runs out of ring.  1024 is not immune, only
  rare: an earlier run read 525 of 1024.
- `rx_overflow_irq` and CSR8 read zero in every run at every rate and every
  ring size, so nothing is lost ahead of the DMA.
- `stmmac_reset_rx_queue()` reinitialises `rx_desc_low_water`, so a run that
  wedges reports only the interval after its last recovery.  Sample the
  statistic once a second and take the minimum across samples.
- The receive poll is never starved.  Tracing `irq:softirq_entry`,
  `irq:softirq_exit`, `irq:irq_handler_entry` and `sched:sched_switch` through
  a 10 s run at 399 Mbit/s offered gives 11,107 windows between one NET_RX
  softirq leaving and the next entering.  Thirty-three exceed 4 ms, and in
  every one of them the only eth0 interrupt is the one that ends the window:
  both CPUs sit in `swapper`, taking the 10 ms timer tick and going back to
  idle.  The long windows are the sender pausing, not the receiver being held
  off.
- The poll interval at the moment the ring is emptiest is 1.5 to 3 ms, the
  ordinary cadence.  `rx_poll_gap_us` reads 1551 us at a backlog of 441 on a
  1024 ring and 1705 us at a backlog of 882.  The ring drains while NAPI is
  polling normally, so the excursion is a burst that outruns the drain rate
  rather than a gap in service.
- The page pool never comes up short.  `rx_refill_starved` counts refills that
  end early for want of a page and stays at zero through every run.
- NET_RX costs 71% of one CPU at 364 Mbit/s received and 30k pps, or about
  24 us of softirq per packet.  That puts the drain ceiling near 42k pps
  against a burst arrival rate of 81k pps at line rate with full frames, which
  is why a burst empties the ring and why received throughput saturates near
  420 Mbit/s.
- The MAC implements receive checksum offload and the port turns it off.
  `plat->rx_coe = STMMAC_RX_COE_NONE` in the glue, on the stated grounds that
  CSR58 is unusable.  CSR58 reads `0x016DEF37` at both `0x101c1058` and
  `0x101c1158`, which decodes to tx_coe and rx_coe_type2 present, and setting
  IPC in `GMAC_CONTROL` sticks.  The vendor runs with RX checksum offload on.
- Receive checksum offload halves the cost and halves the wedge count.  With
  `plat->rx_coe = STMMAC_RX_COE_TYPE2` the NET_RX softirq falls from 71% of a
  CPU to 36% at the same load, TCP `InCsumErrors` stays at zero and no receive
  error counter moves.  Wedges in 30 s go from 4 to 2 at ring 256 and 400
  Mbit/s offered, 8 to 5 unthrottled, and 3 to 1 at ring 512 unthrottled.  On
  a 1024 ring the worst second goes from 142 descriptors left to 659.  It is a
  mitigation: 256 and 512 still wedge.
- The interval before the emptiest poll is spent delivering the previous
  batch, not waiting.  Timing the receive loop and the refill separately puts
  both under 1 ms in every large interval, so the time is neither.  Anchoring
  the reading in the trace and adding `napi:napi_poll` shows what it is: the
  driver poll returns work 64 against a budget of 64, NAPI is therefore not
  completed, and `net_rx_action` then runs for 2.9 to 4.0 ms without a single
  further poll before the softirq exits to `ksoftirqd/0`.  The next driver
  poll comes 4.8 to 8.4 ms after the last one.  That stretch is the batch
  going up the stack, outside `stmmac_rx()`.
- The steady state is interrupt-paced and healthy.  Over 15 s the receive
  NAPI polled 32,469 times and took 416,332 packets, a median of 13 per poll
  and 2165 polls per second, which at `rx-usecs 264` is the coalescing timer
  setting the cadence.  Only 27 of those polls reached the full budget of 64.
  The full-budget poll is what an excursion looks like from inside, not what
  causes one.
- Each cycle returns 64 descriptors, so what matters is cycle time.  At the
  ordinary 1.5 ms that is 42k descriptors per second against 30k arriving.
  At the 4 to 12 ms seen during an excursion it is 5 to 16k, and the ring
  loses about 50 descriptors per cycle until it is empty.  Raising the budget
  does not help, because cycle time scales with batch size and the rate is
  roughly one over the per-packet cost either way -- which is why halving that
  cost with checksum offload moved the wedge rate.
- Refill is not what holds the ring.  `stmmac_rx_refill()` runs at the end of
  `stmmac_rx()`, before the poll returns and before the expensive part of
  delivery, so the descriptors a poll consumed are back with the DMA before
  the slow stretch begins.
- The slow stretch is not scheduling latency.  Threaded NAPI, which gives the
  poll its own kernel thread, made it worse at ring 256: nine wedges in 30 s
  as `SCHED_OTHER` and ten at `SCHED_FIFO` 50, against three for the default
  softirq poll.  `time_squeeze` reads zero on both CPUs, so `net_rx_action`
  never hits its budget or time ceiling either.
- Where the stretch has to be: `gro_flush_normal()` runs in `napi_poll()`
  after `__napi_poll()` has returned, so after the `napi:napi_poll`
  tracepoint fires and after `stmmac_rx()` has returned.  It is outside both
  driver timers and after the anchor, which is exactly where the unaccounted
  4.4 ms sits in every capture.  Unconfirmed.
- `net:netif_receive_skb_list_entry` cannot see it.  That tracepoint is in
  `netif_receive_skb_list()`, the external API; the GRO flush calls
  `netif_receive_skb_list_internal()` directly.  Filtered function tracing on
  the internal name can see it, and costs little: with ten functions filtered
  the board still ran at 434 Mbit/s.
- Ruled out as contributors: L2 cache (wedge reproduced with `L2_CTRL` both
  ways, `L2_RINT` clear), RPS, CPU frequency scaling (no `cpufreq` driver),
  TCP buffer sizing.

## Open

1. Which part of the batch-delivery path takes the 3 to 4 ms.  The events
   available place it inside the NET_RX softirq, after the driver poll
   returns and outside `stmmac_rx()`, which covers the GRO flush, the list
   receive and the TCP stack including the cross-CPU wakeups.  Narrowing it
   further needs either a tracer this kernel does not carry or more driver
   timing.
2. Whether returning descriptors during the receive loop rather than only at
   its end removes the excursion.  The ring drains because the driver holds
   what it has consumed until the poll ends.
3. Whether the vendor driver avoids the wedge, or has simply never been driven
   to the received packet rate that triggers it.  Its 256-entry ring survives
   only workloads that were also survivable on mainline.
4. Whether a receive process in state 4 can be restarted by anything short of
   the three-channel reset.  Every documented DWMAC1000 mechanism has failed.

## Plan

### 1. Make the wedge observable and self-recovering

Mainline only, one kernel build.  This is the fix the evidence already points
to, and it is the instrument for everything that follows.

- Unmask RU (`0x80`) and receive-process-stopped (`0x100`) in CSR7.
- On RU, latch CSR5, CSR19, CSR21 and the GMAC debug register, then reset all
  three DMA channels and reinitialise.
- Add a free-descriptor low-water mark: the minimum `cur_rx`-to-`dirty_rx`
  distance since last read, exposed through `ethtool -S`.  A 10 ms poller
  cannot see the approach to exhaustion — at 30k pps a 256-entry ring empties
  in under 9 ms — so the watermark has to be latched in the driver.
- Make the probe-time ring size a module parameter so ring experiments cost a
  reboot rather than a rebuild.

### 2. Reproduce on demand — done

`iperf3 -c dvr -P 4 -t 30` against `iperf3 -s` on the board, ring 512, wedges
3 runs out of 3.  The frame-size sweep is done and points the other way from
the expectation recorded here: received pps is capped near 38k, so smaller
frames lower the bit rate and move the ring away from exhaustion.  Keep full
MTU for every run that has to wedge.

### 3. Characterise the approach to exhaustion — done

Five offered rates from 100 Mbit/s to unthrottled, 30 s each, at rings of
256, 512 and 1024.  The answer is the latency case: the watermark sits high
and is emptied by one second in thirty.  Results in the progress log.

### 4. Vendor comparison

One question: at the received pps where mainline with a 256-entry ring
wedges, does the vendor with its 256-entry ring wedge?  Step 3 supplies the
rate -- mainline at 256 wedges four times in 30 s at 370 Mbit/s received and
31k pps, and eight times unthrottled.

The vendor is also worth one boot to dump live DMA and MAC configuration for
comparison against mainline: bus mode, operation mode, PBL, thresholds,
store-and-forward, RIWT, and the descriptor interrupt-on-completion bit.  That
comparison is cheap and needs no source reading.

### 5. Fix or mitigate

- Vendor also wedges: the fault is in the silicon and independent of the
  driver.  Keep the 1024 ring, ship detect-and-recover from step 1, close this.
- Vendor survives at a rate that wedges mainline with matched ring: compare the
  live register configuration first, then the refill path — OWN-bit ordering,
  memory barriers, `dma_sync` placement, poll-demand writes, NAPI completion
  and interrupt re-enable ordering.

### Deliberately deferred

- **GRO, interrupt coalescing, flow control.**  All change per-packet CPU cost
  or arrival smoothing rather than descriptor demand.  Step 3 found a capacity
  problem, so these are in scope behind receive checksum offload.

## Working practices

The port is under active development; prefer a fast loop over isolation.

- Prefer boot-time knobs to rebuilds, and live `sysfs`/`ethtool` toggles to
  boot-time knobs — except ring size, where `ethtool -G` has its own wedge.
- Iterate over TFTP with `tools/dvr-stage.sh buildroot-tftp`, or
  `--kernel-only` from a production HDD root.  Do not restage a Debian rootfs
  to change a driver; copy the module.
- The driver recovers a wedged interface on its own.  The equivalent by
  hand, for a kernel without 0016:

      ip link set eth0 down
      for c in 0x101c1000 0x101c1100 0x101c1200; do busybox devmem $c 32 1; done
      ip link set eth0 up

- Select a test ring size at boot, with `dwmac_hi3531.rx_ring_size=` on the
  kernel command line.
- Vendor runs cost a full reboot each.  Batch every vendor capture into one
  boot.

Per run, record: received Mbit/s and pps, payload size, flow count, duration,
ring size, low-water mark, RU count, CSR8, and CSR5/CSR19/GMAC debug at the
end.  Sender-side throughput alone is not a result.

Count wedges from the `receive DMA suspended` lines in `dmesg`, not from
`rx_buf_unav_irq`.  That counter is cumulative and runs ahead of the log,
because the core counts an RU that arrived while the mask was being written
and 0016 deliberately does not report it twice.  `rx_desc_low_water` is the
one statistic that resets on read.

Treat a wedge as confirmed when the receive process is in state 4 with no
packet or current-descriptor progress after descriptors have been returned to
DMA ownership.  Preserve the register samples before any recovery reset.

## Progress log

Append an entry per session.  Newest last.

### 2026-08-28 — fault characterised

Reproduced the wedge with four-stream inbound TCP on a 512-entry ring, 4 runs
out of 4.  Captured the failed state over serial, identified receive state 4
and GMAC debug `0x00000220`, and established that only a three-channel DMA
reset recovers.  Caught the transition with a 10 ms sampler and confirmed the
trigger is descriptor exhaustion.

### 2026-08-28 — ring raised to 1024

Landed patch 0014.  The four-stream test sustained 3.27 GB at 468 Mbit/s and a
900 Mbit/s UDP flood sustained 6.29 GB, with RU never set.  Mitigation only;
the fault is untouched and undetected.

### 2026-08-28 — vendor baseline and first UDP comparison

Captured vendor boot defaults.  Ran single-flow UDP at 100 and 400 Mbit/s
offered against vendor, and 400 Mbit/s against mainline-1024.  Neither system
approached descriptor exhaustion and neither wedged; both ended with the ring
almost entirely DMA-owned.  Single-flow UDP is not a usable reproducer.

### 2026-08-28 — step 1 landed

Patches 0015 and 0016.  RU and receive-process-stopped unmasked (CSR7
`0x0001a1e1`, against the vendor's `0x0001a061`), the three-channel reset
installed as the instance's DMA reset so the core's close and reopen clears
the wedge, CSR5/CSR19/CSR21 and the GMAC debug register recorded before it,
`rx_desc_low_water` in `ethtool -S`, and the probe-time ring size on the
kernel command line.

Four-stream inbound TCP recovered from every wedge: three in one 45 s run at
512 before the interrupt-storm fix, one after, one at 1024.  The storm was
the one surprise -- unmasking RU without masking it again starves the reset
workqueue and stalls the board.

### 2026-08-28 — step 2 done, recovery found wanting

Four-stream inbound TCP at ring 512 wedged 3 runs out of 3, first wedge from
1.3 s to 19 s into the run at 30k received pps.  Swept frame size with the
board's MTU: 1500, 1000, 600, 400.  Only full MTU wedges.  pps flattens near
38k across the sweep while bit rate falls with frame size, and the low-water
mark rises from 24 to 162 as frames shrink, so the ring is emptied by bytes
per second rather than packets per second.

Two sessions ended with the board stalled in `stmmac_napi_poll_rx` after a
wedge that followed a completed recovery, each with a page pool stuck at 1345
inflight pages.  Recovery survives isolated wedges and does not survive a
run of them.

### 2026-08-28 — recovery moved in place

0016 now rebuilds the DMA around the rings it already has instead of going
through `dev_close()` and `dev_open()`: the suspend and resume pair with the
parts that release memory or touch the PHY left out.  Received throughput at
512 rose to 472 Mbit/s and 39k pps because a recovery no longer costs a PHY
renegotiation, and six wedges recovered without the page-pool leak.

Two hardware facts came out of it.  The three-channel reset clears GMAC1's
control register, and `GMAC_CORE_INIT` then re-asserts port select, so the
link bits have to be carried across the reset and put back again after
`core_init` -- the first attempt did only the former and brought the MAC up
in MII mode against a gigabit link.

The sixth wedge hung the board between `rtnl_lock()` and
`stmmac_hw_setup()`.  The teardown was taking the transmit queue before
disabling NAPI, and holding `priv->lock` across it, which no upstream path
does; reordering it to match `__stmmac_release()` fixed it.  Six 45 s runs
then took 15 wedges and recovered from every one.

### 2026-08-28 — step 3: the ring is emptied by a stall

Five offered rates by three ring sizes, 30 s each, full MTU, four streams,
`rx_desc_low_water` sampled once a second so the series survives a recovery
resetting the latch.  Median and minimum free descriptors, and wedges:

| received | pps | 256 | 512 | 1024 |
| --- | --- | --- | --- | --- |
| 96 Mbit/s | 7.9k | 204 / 194 / 0 | 459 / 428 / 0 | 969 / 953 / 0 |
| 190 Mbit/s | 15.7k | 201 / 175 / 0 | 454 / 426 / 0 | 963 / 916 / 0 |
| 283 Mbit/s | 23.5k | 182 / 102 / 0 | 450 / 387 / 0 | 955 / 903 / 0 |
| 370 Mbit/s | 30.8k | 181 / 70 / 4 | 431 / 101 / 1 | 952 / 473 / 0 |
| unthrottled | 33k | 177 / 4 / 8 | 384 / 67 / 3 | 874 / 533 / 0 |

The medians barely move.  Across a 4.4x rise in rate the steady backlog goes
from 52 to 128 descriptors, and at a given rate it is the same at all three
ring sizes.  The minima collapse instead, and the per-second series says why:
at 370 Mbit/s on a 512 ring, twenty-eight seconds read 365 to 452 free and
one reads 101.  Nothing is filling the ring up.  Something empties it.

The largest excursion visible is on the 1024 ring, where the ring is big
enough not to truncate it: 551 descriptors of backlog against a median of 72,
which at 31k pps is 18 ms in which the refill path returned nothing.

`rx_overflow_irq` and CSR8 were zero in all fifteen runs, so no frame was
lost ahead of the DMA at any rate.

Throughput follows the wedge count rather than the ring: 362 Mbit/s
unthrottled at 256 with eight wedges, 417 at 512 with three, 422 at 1024
with none.  Recovery is cheap now but not free.

One boot at ring 256 hung at `eth0: Register MEM_TYPE_PAGE_POOL RxQ-0` with
a console that would not answer a serial break.  The same image and command
line booted on the retry after a power cycle, so it is not a bring-up failure
at that ring size.

### 2026-08-28 — nothing stalls the refill; the drain rate is the ceiling

Patch 0017 adds two reset-on-read statistics beside `rx_desc_low_water`:
`rx_poll_gap_us`, the interval between the poll that recorded the low-water
reading and the one before it, and `rx_poll_max_gap_us`, the largest such
interval.  It also adds `rx_refill_starved`, counting refills that end early
because the page pool has nothing to give.  Together they separate a poll that
never ran from one that ran and could not refill from one that ran slowly.

The answer is none of the three.  At 364 Mbit/s received on a 1024 ring the
worst second reads 583 free after a 1551 us poll gap, and unthrottled it reads
142 free after 1705 us.  Both are the ordinary cadence.  `rx_refill_starved`
stays at zero.

Tracing confirmed it from outside the driver.  A 10 s capture of
`irq:softirq_entry`, `irq:softirq_exit`, `irq:irq_handler_entry`,
`irq:irq_handler_exit` and `sched:sched_switch` gives 11,107 windows between
NET_RX softirqs; 33 exceed 4 ms and every one of them is idle, with both CPUs
in `swapper` and no eth0 interrupt waiting.  The longest, 34 ms, has the timer
tick arriving three times into an idle machine.  Those windows are the sender
pausing.

What the same capture does show is cost: NET_RX is executing for 71% of one
CPU, about 24 us per packet at 30k pps.  That caps the drain near 42k pps
while a burst after a sender pause arrives at up to 81k pps with full frames,
so the backlog grows at 39k descriptors per second and 1024 of them last 26 ms.
It also explains why received throughput saturates near 420 Mbit/s however the
sender is driven.

`ethtool -k eth0` reports `rx-checksumming: off [requested on]`, which the glue
sets deliberately: `plat->rx_coe = STMMAC_RX_COE_NONE`, because CSR58 is held
to be unusable.  CSR58 reads `0x016DEF37` at `0x101c1058` and `0x101c1158`,
decoding to tx_coe and rx_coe_type2 present, and setting IPC in `GMAC_CONTROL`
by hand sticks and reads back.  The vendor defaults captured earlier have RX
checksum offload on and fixed.  So the silicon has it and the port is paying
for a software checksum over every 1500-byte frame.

The build with `plat->rx_coe = STMMAC_RX_COE_TYPE2` hung on the way up at
`eth0: Register MEM_TYPE_PAGE_POOL RxQ-0`, the same intermittent bring-up hang
seen once before at ring 256 with an image that booted on retry.  It is
unmeasured.

### 2026-08-28 — receive checksum offload

The MAC computes receive checksums and the port was not asking it to.
`ethtool -k eth0` reported `rx-checksumming: off [requested on]` because the
glue sets `plat->rx_coe = STMMAC_RX_COE_NONE`, on the stated grounds that
CSR58 is unusable.  CSR58 reads `0x016DEF37` at `0x101c1058` and `0x101c1158`,
which decodes to tx_coe and rx_coe_type2 present; setting IPC in
`GMAC_CONTROL` by hand sticks and reads back; and the vendor defaults captured
earlier have RX checksum offload on and fixed.

With `STMMAC_RX_COE_TYPE2` the NET_RX softirq falls from 71% of a CPU to 36%
at 30k pps, from about 24 us of softirq per packet to about 12.  TCP
`InCsumErrors` is zero and no receive error counter moves, so the checksum
engine is giving correct answers.

Wedges in 30 s, and Mbit/s received, before and after:

    ring  offered      before            after
    256   400 Mbit/s   4 wedges, 364     2 wedges, 400
    256   unthrottled  8 wedges, 362     5 wedges, 405
    512   400 Mbit/s   1 wedge           1 wedge
    512   unthrottled  3 wedges          1 wedge
    1024  400 Mbit/s   0, worst 583/1024 0, worst 765/1024
    1024  unthrottled  0, worst 142/1024 0, worst 659/1024

The board also reaches the 400 Mbit/s it is offered, where before it fell
short.  A second trace at ring 512 with offload on repeats the earlier
result: of 110 NET_RX windows over 3 ms, none has an eth0 interrupt waiting
inside it, and both CPUs sit in `swapper` taking the timer tick.  That still
does not square with the 4.5 to 13 ms `rx_poll_gap_us` readings at the
emptiest moment.

One boot hung at `eth0: Register MEM_TYPE_PAGE_POOL RxQ-0` and needed a power
cycle.  That is the second time, after one at ring 256 with an image that
booted on retry, and it is not tied to a ring size or to this change.

### 2026-08-28 — the interval is batch delivery, not a stall

Patch 0018 emits the low-water reading into the ftrace buffer as it is taken
and splits the interval it carries into the previous poll's refill, this
poll's receive loop, and what is left.  Refill and receive loop came in under
1 ms for every interval over 2 ms, so the time is in neither.

Adding `napi:napi_poll` named it.  Every large interval has the same shape:
the driver poll returns work 64 against a budget of 64, so NAPI is not
completed and goes back on the repoll list; `net_rx_action` then runs 2.9 to
4.0 ms without another poll of any kind before the softirq exits and hands to
`ksoftirqd/0`; the driver is polled again 4.8 to 8.4 ms after the previous
poll.  The unaccounted stretch is the batch going up the stack, outside
`stmmac_rx()` and so outside the split.

Descriptors go back to the DMA only at the end of a poll, so the ring drains
through the whole of it.  Two 30 s runs at ring 512 with the anchor in place:
worst second 108 free after a 3696 us interval, and 66 free after 4792 us.

The two sysctls that change the round are `net.core.netdev_budget`, 300, and
`net.core.netdev_budget_usecs`, which will not go below 20000 on this board
because HZ is 100, so the time limit never binds.  One 20 s run at ring 512
unthrottled with the budget cut to 64: 462 Mbit/s against 448, worst second
184 free against 108, but two wedges against none.  Single runs, and the
wedge count varies enough between runs that this settles nothing.

Throughput with offload has been between 405 and 462 Mbit/s across these runs,
against 422 before it.

### 2026-08-28 — the excursion is the backlogged mode, and refill is not the problem

Two claims from earlier today were wrong and are corrected above.  Descriptors
are not held across the stack work: `stmmac_rx_refill()` runs before
`stmmac_rx()` returns, so a poll's descriptors are back with the DMA before
the slow stretch starts.  Refilling inside the receive loop, recommended in
the previous entry, would therefore buy nothing.

The poll-work histogram reframes it.  Over 15 s: 32,469 polls, 416,332
packets, median 13 per poll, and 27 polls at the full budget of 64.  The
ordinary cadence is the coalescing timer, and it keeps up comfortably.  The
excursion is the rare backlogged mode, where a poll fills its budget and the
next one arrives 4 to 12 ms later instead of immediately.

Two candidates for that delay are now out.  Threaded NAPI at ring 256 gave
nine wedges in 30 s as `SCHED_OTHER` and ten at `SCHED_FIFO` 50, against
three for the default softirq poll, so it is not the poll waiting for CPU.
`time_squeeze` reads zero, so `net_rx_action` is not being cut off at its
budget or time limit.

What remains is `gro_flush_normal()`, which runs in `napi_poll()` after the
tracepoint and after `stmmac_rx()` returns, in the one place none of the
instrumentation covers.

The board ended the session with networking dead after a run of recoveries,
and `reboot` hung as well, which is the stall already recorded above.  It
needed a power cycle.

### Next

Run `ethtool -K eth0 gro off` against the ring-256 reproducer.  If the slow
stretch is the GRO flush then turning GRO off removes it, because packets go
up during the receive loop instead of in a batch after the poll returns.  It
is one command and it needs no rebuild.  If that is inconclusive, a filtered
function trace including `netif_receive_skb_list_internal` during an excursion
shows the same thing directly; the runs that carried the filter did not happen
to contain an excursion, which ring 256 fixes.

Then step 4, with a sharper question than the one recorded there: the vendor
runs a 256-entry ring with checksum offload on and does not wedge, and
mainline now runs the same ring with the same offload and wedges five times in
30 s unthrottled.  What remains is the live DMA and MAC configuration --
bus mode, PBL, thresholds, store-and-forward, RIWT, interrupt-on-completion.
