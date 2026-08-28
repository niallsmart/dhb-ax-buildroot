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
  survives and the link is never dropped.  A 45 s four-stream run at 512
  wedged 0.8 s in, recovered, and finished at 472 Mbit/s received and 39k
  pps, against 319-360 Mbit/s when each recovery cost a PHY renegotiation.
  Six wedges recovered this way across three runs with no page-pool message
  and no RCU stall, where close-and-reopen stalled on the third.
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
- Ruled out as contributors: L2 cache (wedge reproduced with `L2_CTRL` both
  ways, `L2_RINT` clear), RPS, CPU frequency scaling (no `cpufreq` driver),
  TCP buffer sizing.

## Open

1. Whether the ring approaches exhaustion smoothly as offered rate rises, or
   is emptied by an occasional long stall.  These need different fixes.  One
   run each of the same four-stream test read a low-water mark of 126 of 512
   and 525 of 1024: the ring drains by about 390 descriptors either way,
   which is a fixed backlog rather than a capacity that scales with the
   ring.  Two runs is not a result; step 3 is the measurement.
2. Whether the vendor driver avoids the wedge, or has simply never been driven
   to the received packet rate that triggers it.  Its 256-entry ring survives
   only workloads that were also survivable on mainline.
3. Whether a receive process in state 4 can be restarted by anything short of
   the three-channel reset.  Every documented DWMAC1000 mechanism has failed.
4. What blocks the in-place reset on the wedge that eventually hangs the
   board.  `Reset DMA.` printed and `stmmac_hw_setup()` never did, so it
   stops between taking `rtnl` and rebuilding.  No RCU stall was reported
   and the console stopped responding, including to sysrq over a serial
   break, which points at a sleeping deadlock rather than a spin.  The
   teardown has since been reordered to match `__stmmac_release()` --
   `napi_disable` first, then the transmit timers, then `netif_tx_disable`,
   with `priv->lock` held only across the rebuild.  That ordering is
   untested: the board needs a power cycle to boot the kernel carrying it.

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

### 3. Characterise the approach to exhaustion

Mainline only.  At fixed received pps, sweep the ring across 256, 512 and
1024, and record the low-water mark and whether RU fires.

- A watermark that falls smoothly with rate is a capacity problem, and the
  next question is what consumes the refill budget.
- A watermark that sits high until a single run empties it is a latency
  problem, and the next question is what blocks the refill path for 10 ms.

Record CSR8 alongside, to keep drops before the DMA out of the reading.

### 4. Vendor comparison

Only if step 3 leaves the question open.  One question: at the received pps
where mainline with a 256-entry ring wedges, does the vendor with its 256-entry
ring wedge?

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

- **RX checksum offload.** A throughput item, tracked in
  [optimizing-network-throughput.md](optimizing-network-throughput.md).  It is
  expensive to validate — wrong descriptor semantics accept corrupt frames
  silently — and the measurements so far show the ring full of DMA-owned
  descriptors with neither core saturated, so CPU cost is not yet implicated
  in the wedge.  The claim in patch 0014 that software checksumming is what
  delays the refill is an assertion, not a measurement.
- **GRO, interrupt coalescing, flow control.**  All change per-packet CPU cost
  or arrival smoothing rather than descriptor demand.  Revisit only if step 3
  identifies a capacity problem.

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

The sixth wedge still hung the board between `rtnl_lock()` and
`stmmac_hw_setup()`, with no stall report and an unresponsive console.

### Next

Boot the kernel with the reordered teardown and repeat the stress run: three
45 s runs at 512, watching for a wedge that does not come back.  The board is
hung and needs a power cycle first.

Then step 3: at fixed received pps, sweep the ring across 256, 512 and 1024
and record the low-water mark and whether RU fires.  Use full MTU; the frame
size sweep showed nothing else reaches the rate that wedges.
