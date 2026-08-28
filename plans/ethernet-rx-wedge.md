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

Descriptor exhaustion is not recoverable on this SoC.  When the RX ring runs
dry the DMA sets RU in CSR5 and moves the receive process to state 4.  From
there it ignores receive poll demand, the DMA start/stop bit, the MAC receiver
enable, and a channel software reset.  Only a software reset of all three DMA
channels clears it — the same cure `hi3531_reset_dma_channels()` already
applies at probe.

Nothing detects it.  RU and receive-process-stopped are masked off in CSR7, no
error counter moves, and the netdev watchdog covers transmit only.

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
- Ruled out as contributors: L2 cache (wedge reproduced with `L2_CTRL` both
  ways, `L2_RINT` clear), RPS, CPU frequency scaling (no `cpufreq` driver),
  TCP buffer sizing.

## Open

1. Whether the ring approaches exhaustion smoothly as offered rate rises, or
   is emptied by an occasional long stall.  These need different fixes and the
   evidence so far does not separate them.
2. Whether the vendor driver avoids the wedge, or has simply never been driven
   to the received packet rate that triggers it.  Its 256-entry ring survives
   only workloads that were also survivable on mainline.
3. Whether a receive process in state 4 can be restarted by anything short of
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

### 2. Reproduce on demand

No further comparison work until the generator wedges mainline at 512
descriptors repeatably, 3 runs out of 3, within a bounded time.

Single-flow UDP is not that generator.  Use multiple flows and drive past
468 Mbit/s *received*; match runs on received packets/s, not offered, because
half the offered load is discarded before it reaches the DMA.  Sweep frame
size downward once a working rate is found: small frames raise descriptor
demand for the same bit rate.

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
- Recover a wedged interface in place rather than rebooting:

      ip link set eth0 down
      for c in 0x101c1000 0x101c1100 0x101c1200; do busybox devmem $c 32 1; done
      ip link set eth0 up

  Step 1 makes this automatic.
- Vendor runs cost a full reboot each.  Batch every vendor capture into one
  boot.

Per run, record: received Mbit/s and pps, payload size, flow count, duration,
ring size, low-water mark, RU count, CSR8, and CSR5/CSR19/GMAC debug at the
end.  Sender-side throughput alone is not a result.

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

### Next

Step 1: unmask RU, add detect-and-recover and the low-water mark, and make the
ring size a module parameter.
