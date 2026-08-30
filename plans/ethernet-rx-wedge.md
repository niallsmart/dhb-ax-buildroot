# Hi3531 RX wedge

`eth0` stops receiving permanently under sustained inbound load.  The link
stays up at 1000 Mb/s, transmit keeps working, and no counter or log message
moves.

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

Patch 0015 reports the condition: RU and receive-process-stopped unmasked,
and the registers the wedge is diagnosed from latched into the log.  Patch
0016 mirrors the vendor's 50 ms poll timer.  Neither recovers the interface
and neither is meant to; `ip link set eth0 down` and up does, through the
three-channel reset installed as the instance's `dma_ops->reset`.

## What any explanation has to satisfy

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
  clears it, with the outer cache enabled and at full link speed.
- One RU interrupt is raised per run, with the source re-armed every 50 ms.
  RU asserts on a failed descriptor fetch, so a channel that was retrying
  and failing would re-assert it.  The channel is not retrying.
- The vendor reaches state 4 constantly at the stock ring size and resumes
  from every episode, so nothing here is a silicon limit.
- State 4 is the wedge.  State 7 is what a healthy idle interface reports on
  this integration, so it is not a fault signature.

## The open question

**Both kernels suspend the receive process in state 4 under load.  The
vendor's resumes every time; mainline's never attempts another descriptor
fetch, and nothing short of resetting all three DMA channels makes it try
again.  What accounts for the difference?**

Everything the hardware needs in order to resume is present and correct:
descriptors available in physical memory, a pointer inside the ring, no bus
error, and an explicit poll demand telling it to go.  It stays suspended
anyway, and it stops asking.

That closes the two candidates this section used to hold.  The DMA is not
re-fetching from a wrong address, because CSR19 is in bounds.  The hardware
is not being denied the OWN bits, because they are set in physical memory and
disabling the outer cache changes nothing.

It also closes the poll-demand line of attack entirely.  Poll demand was
worth trying while the failure looked like a channel waiting to be told to
re-read a descriptor.  It is not: the channel has stopped fetching, and
telling it to fetch does not restart it.

What is left is the setup the channel is running under rather than anything
done to it afterwards.  The vendor suspends in state 4 as readily as mainline
does — 310 episodes in a 45 s run at ring 256 — and resumes from every one.
Suspension is not the fault; failing to leave it is.  So the difference is in
what makes resuming possible, and since nothing applied to a suspended channel
restarts it, that points at how the channel was configured before it stalled.
Compare the two configurations register by register: CSR0 for ATDS and
descriptor size, CSR6 for operating mode and thresholds, CSR10 for the
AXI/AHB bus settings, and the burst length.  Read the vendor's values on the
3.0 kernel and mainline's on the same board, and account for every
difference.

## Next experiments, cheapest first

1. **Compare the DMA configuration register by register.**  Both kernels
   suspend in state 4; only the vendor's channel resumes.  Read CSR0, CSR6, CSR9 and CSR10 under the vendor 3.0 kernel and under
   mainline on the same board, and account for every difference.  Known
   already: mainline sets ATDS and runs 32-byte enhanced descriptors where the
   vendor runs 16-byte with ATDS clear, and mainline's CSR9 is `0xa0` where
   the vendor's is zero.  Neither has been changed and tested.
2. **Clear ATDS and run 16-byte descriptors.**  This changes the stride the
   DMA uses to walk the ring, which is the most structural of the known
   differences.  `plat->enh_desc` and `dma_cfg->atds` both have to go, and
   mainline forces `priv->extend_desc` for cores at 3.50 and above in
   `stmmac_dwmac1_quirks()`, so that quirk has to be worked around as well.
3. **Disable the receive interrupt watchdog.**  Mainline defaults CSR9 to
   `DEF_DMA_RIWT`, `0xa0`, about 264 us on the 155 MHz `stmmaceth` clock,
   against the vendor's zero.  That delay is dead time in which the hardware
   consumes descriptors and the driver is not running to return any.
   `ethtool -C eth0 rx-usecs` floors at about 27 us because it rejects
   anything below `MIN_DMA_RIWT`; that much is a live toggle.  A true zero
   needs `riwt_off` in the platform data or a direct CSR9 write.

Closed, and not worth revisiting without new evidence:

- **CSR19 outside the ring.**  Measured in bounds at the wedge.
- **Descriptor coherency.**  OWN confirmed set in physical memory through
  `/dev/mem`, and disabling the outer cache changes nothing.
- **Receive poll demand, however issued.**  By hand at CSR2 with the vendor's
  write value and with traffic present, and from a 50 ms timer mirroring the
  vendor's `stmmac_poll_func`, with the outer cache on and at full link speed.
  It neither clears the wedge nor prevents it.

Independent of the above, and unresolved: which part of the batch-delivery
path takes the 3 to 4 ms that creates the excursion in the first place.  It
sits inside the NET_RX softirq, after the driver poll returns and outside
`stmmac_rx()`.  `gro_flush_normal()` is the suspect, unconfirmed.  Test with
`ethtool -K eth0 gro off` against the ring-256 reproducer, then filtered
function tracing on `netif_receive_skb_list_internal`.

## Running an experiment

The reproducer is four-stream inbound TCP against `iperf3 -s` on the board,
full MTU, 30 to 45 s.  At ring 256 it wedges reliably; at 512 it wedged 3 runs
out of 3.  Keep full MTU — smaller frames move the fault away.

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
- `rx_poll_ms` is writable at runtime, so the poll timer can be toggled
  between runs on one boot.
- Per run record: transferred bytes, frame size, flow count, duration, ring
  size, wedge count, CSR8, and CSR3/CSR5/CSR19 at the wedge.
- Register addresses are `0x101c1100` plus the CSR index times four, so
  CSR2 receive poll demand is `0x101c1108` and CSR5 is `0x101c1114`.  Check
  a derived address against `dwmac_dma.h` before writing to it.

Treat a wedge as confirmed when the receive process is in state 4 with no
packet or current-descriptor progress after descriptors have been returned to
DMA ownership.  Preserve the register samples before any recovery reset.
