# Hi3531 RX wedge

**Resolved.**  `eth0` stopped receiving permanently under sustained inbound
load: the link stayed up at 1000 Mb/s, transmit kept working, and no counter
or log message moved.

The cause is CSR6 bit 24, DFF.  Clear, as upstream leaves it, the receive DMA
flushes a frame it has no descriptor for, and on this silicon the flush
desynchronises the MTL receive FIFO and the receive process never fetches
again.  Set, as the vendor sets it, the frame waits in the FIFO instead and
the channel resumes.  Setting the bit takes a 45 s four-stream run from
5.12 MB and a wedge to 3.75 GB with none.

The same fault was found independently on Altera SoCFPGA and fixed upstream in
`45d100ee0d6e`, first released in Linux 6.19.  This port targets 6.18 LTS,
which is the last release without it, and the fix was never backported to
6.18.y.

The detailed record — measurements, dead ends, traps — is in
[ethernet-rx-wedge-log.md](ethernet-rx-wedge-log.md).  Read the dead-end list
before designing an experiment.  Register dumps from the first hard reset are
in `artifacts/diagnostics/ethernet-wedge-20260828-hard-reset/README.md`.
Throughput work unrelated to the wedge is in
[optimizing-network-throughput.md](optimizing-network-throughput.md).

## Efficiency

This is a diagnostic side-quest, not production code.  Find the answer
quickly.  Prefer live toggles to boot knobs, boot knobs to rebuilds, and the
working copy to an isolated test environment.

## The model

Under load the receive ring occasionally runs out of descriptors.  This is
normal backpressure: the DMA finds the next descriptor still CPU-owned, sets
RU, and suspends its receive process in state 4.  The driver then refills,
setting OWN across the ring, and the hardware is supposed to re-fetch on the
next arriving frame and carry on.

The vendor does exactly that, hundreds of times a run, on the same silicon.
Mainline does not.  It refills the entire ring and the receive process stays
suspended, ignoring every per-channel restart mechanism.  Only a software
reset of all three DMA channels clears it.

So the fault is not that the ring empties, and not that the SoC cannot recover
from an empty ring.  It is that this receive process, once suspended, stops
fetching descriptors and cannot be made to start again.

That model held, and the missing piece sits one step earlier than any of it.
The difference between the two kernels is what the DMA does with the frame it
could not place.  Upstream lets it flush; the vendor does not.  A flush on
this silicon leaves the MTL receive FIFO out of sync with the DMA, and it is
that desynchronised channel, not the suspension, that never fetches again.
Suspension is ordinary and both kernels do it constantly.

Patch 0015 reports the condition: RU and receive-process-stopped unmasked,
and the registers the wedge is diagnosed from latched into the log.  Patch
0016 mirrors the vendor's 50 ms poll timer, patch 0017 its refill-path poll
demand, and patch 0019 sets DFF.  Only the last of those fixes anything, and
0017 is required alongside it: with DFF set the DMA suspends rather than
flushing, so software has to poll-demand after refilling to resume it.  That
pairing is what upstream's own fix does.

## What the answer had to satisfy

The evidence the wedge was diagnosed from.  Every item is consistent with a
receive FIFO desynchronised by a flush: the descriptors and pointers are all
correct, which is why nothing about them ever explained the failure.

- Every descriptor in the ring carries OWN in physical memory at the wedge,
  read through `/dev/mem` rather than the driver's mapping.  The DMA is not
  short of buffers and is not being shown a stale view of them.
- CSR19 is frozen, and inside the ring CSR3 points at.  The hardware is not
  reading outside its own descriptor list.
- CSR8 counts no missed frames and no FIFO overflow.  The AHB/AXI status
  register is zero.  No bus error, nothing lost ahead of the DMA.
- A receive poll demand does nothing, at CSR2 with the vendor's own write
  value, with inbound traffic present, on a channel whose descriptors are
  confirmed available.  Neither does SR toggling, MAC receiver disable or a
  channel software reset.  A three-channel reset works, so what is wrong is
  not confined to channel 1's own state.
- Polling every 50 ms as the vendor does neither prevents the wedge nor
  clears it, with the outer cache enabled and at full link speed.  Nor does
  polling from the refill path where the vendor polls, with the vendor's
  barrier ahead of the write and a counter proving the write happened.
- One RU interrupt is raised per run, with the source re-armed every 50 ms.
  RU asserts on a failed descriptor fetch, so a channel that was retrying
  and failing would re-assert it.  The channel is not retrying.
- The vendor reaches state 4 constantly at the stock ring size and resumes
  from every episode, so nothing here is a silicon limit.
- State 4 is the wedge.  State 7 is what a healthy idle interface reports on
  this integration, so it is not a fault signature.

## The answer

**CSR6 bit 24, DFF, Disable Flushing of Received Frames.**  The vendor sets
it whenever receive store-and-forward is on.  Upstream defines
`DMA_CONTROL_DFF` in `dwmac1000.h` and never writes it, so on 6.18 the bit
stays at its reset value.

With the bit clear, a receive DMA that has no descriptor for an arriving
frame flushes it.  On this silicon that flush leaves the MTL receive FIFO out
of sync with the DMA, and the receive process never transfers again.  With
the bit set the frame waits in the FIFO until a descriptor appears, and the
channel resumes.

Measured on one boot, ring 256, four-stream inbound TCP, 45 s, the parameter
toggled live between runs:

    rx_dff   CSR6         transferred   outcome
    Y        0x03002902      3.75 GB    no wedge
    Y        0x03002902      3.71 GB    no wedge
    N        0x02002902      5.12 MB    wedged, state 4

The successful runs still suspend.  One logged `CSR5 006884c4` — the exact
wedge signature — at t=138 s and carried on to 3.75 GB; RUE and RSE are
masked after the first report, so later episodes went unrecorded.  That is
the vendor's behaviour, which was measured at 310 suspend episodes in 45 s
with recovery from every one.  Descriptor exhaustion was never the fault.

Throughput rose with it, by more than the absence of wedges accounts for:
706-714 Mbit/s four-stream, against 468 Mbit/s recorded as the previous best
in [optimizing-network-throughput.md](optimizing-network-throughput.md).
CSR8 stayed at zero and `rx_errors` at zero across 2.78M packets.

This also explains why nothing applied to a suspended channel ever helped.
Poll demand, SR toggling, MAC receiver disable and a channel software reset
all arrive after the flush has already desynchronised the FIFO.  Only the
three-channel reset reaches far enough to clear it.

### Independently found and fixed upstream

`45d100ee0d6e`, "net: stmmac: dwmac: Disable flushing frames on Rx Buffer
Unavailable", by Rohan G Thomas, merged to net-next 2025-11-27 and first
released in Linux 6.19.  It was reported on SoCFPGA platforms carrying the
same DWMAC1000 IP — Arria 10, Cyclone V, Agilex 7 — where it presents as
latency rather than a permanent stop: frames sit in the FIFO until the next
packet arrives, so a ping returns one ping interval late.

Upstream sets DFF beside RSF in `dwmac1000_dma_operation_mode_rx()` and adds
`dwmac_enable_dma_reception()`, called from the refill path, for the same
reason patch 0017 exists: with DFF set the DMA suspends instead of flushing
and needs a poll demand to resume.

It was never backported to 6.18.y and will not be, having gone to net-next
with no `Fixes:` tag and no `Cc: stable`.  6.18 LTS is therefore the last
release that needs this carried locally.

### What the vendor knew

HiSilicon ships two drivers for this MAC, `stmmac` and `higmacv300`.  Their
`dwmac1000_dma.c` files are identical apart from an include, a Kconfig symbol
and one comment.  The stmmac copy attributes DFF to the TNK offload engine;
`higmacv300`, which contains no offload code at all, sets the same bit and
calls it required by the GMAC.  The requirement is the MAC's, and the TNK
attribution is a fork artifact.

## Follow-up work

1. **Replace patches 0017 and 0019 with a backport of `45d100ee0d6e`.**
   Upstream sets DFF beside RSF in `dwmac1000_dma.c`, which is where the bit
   belongs, rather than wrapping `dma_rx_mode` per platform as 0019 does.
   The backport then disappears on its own at any move past 6.19.
2. **Retire the mitigations this fault justified.**  `rx_ring_size` defaults
   to 1024 (patch 0014) to make an empty ring rare; the ring can go back to
   the upstream default once wedge-free operation is confirmed at it.  The
   three-channel `dma_ops->reset` in 0015 was the only known recovery and is
   no longer needed for that, though it is still needed at probe, where a
   warm restart otherwise inherits a running DMA.  The 0016 poll timer works
   as a poll demand source in its own right — 2.40 GB at 452 Mbit/s with the
   refill kick off — but is strictly worse than 0017 beside it, because a
   50 ms period leaves each suspension standing for 30 ms on average against
   the kick's 3.2 ms.  It has no purpose alongside 0017.
3. ~~**Confirm 0017 is still required.**~~  Done, and it is.  With DFF set,
   the kick off and the timer off, the channel entered state 4 at 6.74 s and
   was still there 43 s later: one episode, 86.6% of the run, 2.3 MB
   transferred.  DFF decides whether a suspended channel can be resumed; a
   poll demand is what resumes it.
4. **Re-measure throughput.**  706-714 Mbit/s four-stream is well above the
   468 Mbit/s that [optimizing-network-throughput.md](optimizing-network-throughput.md)
   records as the ceiling, so that document's conclusions were taken against
   a MAC that was flushing frames and need revisiting.

Independent of the above, and unresolved: which part of the batch-delivery
path takes the 3 to 4 ms that empties the ring in the first place.  It sits
inside the NET_RX softirq, after the driver poll returns and outside
`stmmac_rx()`.  `gro_flush_normal()` is the suspect, unconfirmed.  Test with
`ethtool -K eth0 gro off` against the ring-256 reproducer, then filtered
function tracing on `netif_receive_skb_list_internal`.  This is now a
throughput question rather than a correctness one.

Closed, and not worth revisiting without new evidence:

- **CSR19 outside the ring.**  Measured in bounds at the wedge.
- **Descriptor coherency.**  OWN confirmed set in physical memory through
  `/dev/mem`, and disabling the outer cache changes nothing.
- **Receive poll demand as the difference.**  By hand at CSR2 with the
  vendor's write value and with traffic present; from a 50 ms timer mirroring
  the vendor's `stmmac_poll_func`; and from the end of `stmmac_rx_refill()`
  with the vendor's barrier and a counter confirming 54 of them reached the
  hardware in a run that wedged anyway.  Necessary alongside DFF, but not
  sufficient and not the cause.
- **Descriptor format.**  16-byte descriptors with ATDS clear wedge exactly
  as 32-byte ones do, which also brought CSR0 to functional parity with the
  vendor: `0x00A01000` against `0x00201000`, differing only in USP, which
  selects between an RPBL and a PBL that both read 16.

## Running an experiment

The reproducer is four-stream inbound TCP against `iperf3 -s` on the board,
full MTU, 30 to 45 s.  At ring 256 it wedges reliably; at 512 it wedged 3 runs
out of 3.  Keep full MTU — smaller frames move the fault away.

Drive it with `tools/ethernet-rx-stress.pl dvr 4 45`, which runs on the
development host and stops as soon as the board stops taking data, reporting
where that happened.  It exits 2 on a stall and 0 on a clean run, so a wedged
run costs about five seconds instead of the full duration.  It has to run on
the host: a stall takes SSH with it, so nothing on the board can report one.

- Select the ring at probe with `dwmac_hi3531.rx_ring_size=`, 64 to 1024.
  Never with `ethtool -G`, which wedges receive by an unrelated route.
- A device-tree change needs `linux-dirclean` before the rebuild, or the old
  DTB is kept silently.
- Iterate over TFTP with `tools/dvr-stage.sh buildroot-tftp`, or
  `--kernel-only` from a production HDD root.  Copy a module rather than
  restaging a Debian rootfs.
- Nothing recovers the interface by itself.  The first wedge is the end of
  the run, so sender-side totals measure time to first wedge and not
  throughput.  `ip link set eth0 down` and up restores it, over the serial
  console, because SSH dies with receive.
- Sample the wedge with `tools/ethernet-rx-ring-watch.c`, built by
  `tools/build-ethernet-rx-tools.sh`.  It reads CSR3, CSR5, CSR19 and CSR21
  and counts OWN across the ring through `/dev/mem`, so it answers the
  descriptor and pointer questions without the driver in the way.  Ring 256
  and 32-byte descriptors while ATDS is set.  Run it detached with output to
  a file: SSH dies mid-command when receive stops.
- `rx_dff`, `rx_poll_ms`, `rx_kick_on_refill` and `rx_kicks` are all writable
  at runtime, so DFF, the poll timer and the refill-path kick can be toggled
  between runs on one boot and the kick counter reset before each.  Set
  `rx_poll_ms` to 0 when testing the refill kick, or the two cannot be told
  apart.  `rx_dff` takes effect on the next interface open, because
  `dma_rx_mode` runs from `stmmac_hw_setup()`, so bounce the interface after
  writing it and confirm CSR6 bit 24 before trusting a run.
- `extend_desc` is read at probe and is therefore a command-line knob:
  `dwmac_hi3531.extend_desc=0` for 16-byte descriptors with ATDS clear.
- A diagnostic that can read zero needs a counter proving its code path ran.
  `rx_kicks` exists because a wedge with the kick enabled looks identical to
  a wedge with the call site never reached.
- Put the console loglevel down before reading anything from a run that logs
  per episode.  `ignore_loglevel` is on the boot line, so `dmesg -n 1` alone
  does nothing; clear `/sys/module/printk/parameters/ignore_loglevel` first.
  A 50 ms timer re-arming RUE and RSE against a report-and-mask handler
  produces 20 lines a second onto a synchronous 115200 console, which cost a
  factor of four in throughput on one measurement.
- Per run record: transferred bytes, frame size, flow count, duration, ring
  size, wedge count, CSR8, and CSR3/CSR5/CSR19 at the wedge.
- Register addresses are `0x101c1100` plus the CSR index times four, so
  CSR2 receive poll demand is `0x101c1108` and CSR5 is `0x101c1114`.  Check
  a derived address against `dwmac_dma.h` before writing to it.

Treat a wedge as confirmed when the receive process is in state 4 with no
packet or current-descriptor progress after descriptors have been returned to
DMA ownership.  Preserve the register samples before any recovery reset.
