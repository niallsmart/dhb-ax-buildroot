# The receive path writes to freed pages

The Hi3531 receive path has written into memory the kernel already reclaimed.
It surfaces as page poison corruption and as an oops in whatever touches the
page next.  A separate receive stall can leave the DMA suspended with the
board off the network.  Both faults occurred in the same run, but the wedge
can occur without corruption.  Its evidence, theory and fix plan are tracked
in [`bug-rx-refill-stall.md`](bug-rx-refill-stall.md).

## What is established

Caught on 2026-09-02 with `PAGE_POISONING`, at a 64-entry ring, no poller
running: `artifacts/ethernet-tests/20260902T224615Z-rx64`.

```text
pagealloc: memory corruption
81ddf2a0: 80 03 4e 00 aa aa aa aa aa aa aa aa aa aa aa aa
81ddf2b0: aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa aa
81ddf2c0: 80 03 4e 00
```

- Two 4-byte writes of the same value into a poisoned free page, 32 bytes
  apart: one cache line, and one receive descriptor stride.
- One report came from `stmmac_napi_poll_rx` allocating for the receive page
  pool, the other from `copy_process` allocating a page table.  The damage
  reaches memory unrelated to networking.
- `DMA_API_DEBUG` reported nothing, so the driver's own map and unmap calls
  are consistent.  The writes happen outside the DMA API's view.
- The board wedged in the same run with the DMA Status Register [CSR5] at
  `0x00680404`: receive state 4, eth0 interrupts frozen, and `dmesg`
  otherwise clean.
- Earlier the same day, without the debug kernel, the corruption surfaced as
  `Unable to handle kernel paging request at virtual address 25242322` in
  `ext4_read_folio`, preceded by `BUG: Bad rss-counter state`.

A second cache-enabled failure on 2026-09-03 captured received Ethernet and
ARP packet contents in a poisoned free page:
`artifacts/ethernet-tests/20260903T113600Z-rx64`.

```text
[392.651784] Register MEM_TYPE_PAGE_POOL RxQ-0
[395.027216] Link is Up
[396.476788] pagealloc: memory corruption
82820040: ff ff ff ff ff ff 6c 63 f8 58 c0 70 08 06 00 01
82820050: 08 00 06 04 00 01 6c 63 f8 58 c0 70 c0 a8 05 a2
82820060: 00 00 00 00 00 00 c0 a8 05 96 00 00 00 00 00 00
```

The bytes are a broadcast ARP frame from MAC address `6c:63:f8:58:c0:70`,
with source address `192.168.5.162` and target address `192.168.5.150`. The
page had reference count zero, and the report arose in
`__kernel_unpoison_pages()` while `stmmac_napi_poll_rx()` allocated receive
pages through the page pool. A network payload written into a free page is
direct evidence that receive DMA retained access to memory after the kernel
returned it to the allocator.

This failure occurred about 1.45 seconds after link came back during the
interface reopen. It preceded the later link-flap phase. The network workload
continued to completion, so the harness's `PASS` records liveness only and
does not make this a successful memory-safety run. DMA API debugging again
reported no mapping violation.

After the workload, the DMA Status Register [CSR5] was `0x006e0000`, with
receive process state 7, and both `rx_refill_alloc_failed` and
`rx_napi_complete_pending` were zero. The board was rebooted immediately
after the UART evidence was collected and reached the Linux login prompt.
Post-reboot filesystem and kernel-log checks remain outstanding.

## Controlled old-ring correlation after stall recovery

A fresh-boot run on 2026-09-04 correlated both forms of corruption with exact
pre-teardown receive-ring addresses:
`artifacts/ethernet-tests/20260904T120226Z-focused-bidir-fresh-boot-recovery-3/`.
The unfixed 64-entry debug kernel stalled after 15 seconds of four-stream
bidirectional TCP. Returning one descriptor to DMA and writing DMA Receive
Poll Demand Register [CSR2] restarted receive DMA and NAPI. Receive packets
and refilled descriptors both advanced by 1,408, and Receive Process State
[RS] changed from suspended state 4 to running state 7.

Before cycling `eth0`, the complete ring dump recorded:

```text
Receive Descriptor List Address Register [CSR3] 0x81fb2000
descriptor 7 address                             0x81fb20e0
descriptor 7 status                              0x804e0380
descriptor 7 receive buffer                      0x81ec0040
descriptor 8 address                             0x81fb2100
descriptor 8 status                              0x804e0380
```

The reopen installed a new receive ring at `0x81e9c000`. Controlled process
allocation then detected corruption in two poisoned pages:

```text
81fb20e0: 20 03 ba 00 aa aa aa aa ...
81fb2100: 80 03 44 00
page: ... pfn:0x81fb2

81ec0040: 00 18 ae 3c a2 49 80 da 13 77 b9 b2 86 dd ...
page: ... pfn:0x81ec0
```

Page `0x81fb2000` is the exact freed old descriptor ring. The words written at
the old descriptor 7 and 8 offsets are new receive completion statuses
`0x00ba0320` and `0x00440380`, with DMA Ownership [OWN] clear. Page
`0x81ec0000` held descriptor 7's exact old receive buffer; the bytes at
`0x81ec0040` are a received IPv6 frame addressed to the board.

The poison surrounding the targeted descriptor words establishes that the
writebacks happened after the page was freed. The complete Ethernet frame at
the exact old buffer address establishes that receive DMA, rather than an
unrelated CPU writer, retained access to the freed resources. Page allocation
debugging reported the damage later, when `copy_process()` reused the pages;
its timestamps are detection times rather than write times.

The interface went down at kernel time `588.070255`, link returned at
`591.587422`, and the allocator detected the two corrupt pages at `637.818232`
and `638.157811`. A 60-second post-reopen connectivity check received all 300
ICMP replies. The board was rebooted immediately; the next boot mounted the
root filesystem normally and reported no filesystem error.

## Earlier descriptor-writeback evidence

`0x004e0380` read as a receive descriptor status has DMA Ownership [OWN]
clear and a frame length of 78 bytes. Descriptor writeback into memory that
is no longer the ring fits the value, the 32-byte spacing and the timing, but
nothing in that first capture alone proved the hardware was the writer. The
later ARP capture independently proves stale receive DMA access, although it
does not establish whether the earlier 4-byte writes were descriptor
writebacks or part of the same underlying lifetime error.

In the first capture, the corruption followed both an interface reopen and a
link flap: link down at 81 s, up at 86 s, down at 110 s, up at 114 s, and
corruption reported at 122 s and 128 s.

## Separate receive interrupt stall

The independent stall is tracked in
[`bug-rx-refill-stall.md`](bug-rx-refill-stall.md).  A cache-disabled debug run
wedged before any interface release and produced no page-poison report. Its
live ring was structurally valid and still programmed into DMA, but all 64
descriptors were CPU-owned, the receive process was suspended, and a shared
Transmit Interrupt [TI] had cleared Receive Interrupt [RI] while Receive
Interrupt Enable [RIE] was masked. Neither corruption thesis in this report
explains that state.

The stall could precede this bug operationally: recovery reopened the
interface and may have exposed a teardown race. Preserving masked Receive
Interrupt [RI] status now lets the corruption test reach its reopen phase
reliably; it is not a proposed fix for the memory corruption itself.

## Root cause: receive DMA is not quiesced before ring resources are freed

`__stmmac_release()` stops the DMA and frees the ring in consecutive
statements:

```c
	/* Stop TX/RX DMA and clear the descriptors */
	stmmac_stop_all_dma(priv);

	/* Release and free the Rx/Tx resources */
	free_dma_desc_resources(priv, &priv->dma_conf);
```

`dwmac_dma_stop_rx()` clears the start-receive bit and returns at once:

```c
	value &= ~DMA_CONTROL_SR;
	writel(value, ioaddr + DMA_CHAN_CONTROL(chan));
```

Clearing Start Receive [SR] asks the receive process to stop when it finishes
the descriptor it is working on, so the state machine can still be
transferring data or closing a descriptor when the write returns. Nothing
between the two statements waits for the DMA Status Register [CSR5] to report
the receive process stopped, and the pages go back to the allocator
immediately. A payload transfer or descriptor writeback landing in that
window writes into memory the kernel has already reclaimed, which is the
observed corruption.

This race does not explain the fresh-boot wedge above: no release had run and
the live descriptor ring was still allocated and correctly programmed.

The controlled 2026-09-04 capture establishes the lifetime failure: after the
reopen installed a different ring, receive DMA wrote completion statuses into
the poisoned old ring and a complete frame into an exact poisoned old receive
buffer. What remains unobserved is the narrow interval inside
`__stmmac_release()`: whether the receive process still reports running after
Start Receive [SR] is cleared, or whether an additional hardware queue or
prefetched transaction survives a stopped state.

The first fix to test is polling the DMA Status Register [CSR5] for the stopped
receive state with a timeout after clearing Start Receive [SR] and before
freeing. If a stopped state does not prevent the stale writes, test a channel
soft reset at release as
`stmmac_init_dma_engine()` already does at open. The race is in mainline
`dwmac_lib.c`, not in this port's glue, so the hand-rolled three-channel reset
is not implicated.

Testing it needs driver instrumentation rather than a console read: the stop
and the free happen inside one syscall, so userspace cannot sample the DMA
Status Register [CSR5] between them. Capture the relevant DMA registers inside
`__stmmac_release()` before the stop, after the stop, and immediately before
the free. Store the samples and print them after the free so the logging does
not change the interval under investigation.

## Secondary question: outer cache timing

`linux.config` carries `CONFIG_OUTER_CACHE`, `CONFIG_OUTER_CACHE_SYNC`,
`CONFIG_CACHE_HIL2V200` and `CONFIG_CACHE_L2X0`, from the L2 work of
2026-08-27.  With an outer cache present, every DMA map and unmap depends on
outer maintenance being correct: an invalidate that misses leaves the CPU
reading stale data, and a dirty line that survives past a free is written back
over whatever occupies the page next.  Wrong maintenance under a correct API
call also explains why `DMA_API_DEBUG` reports nothing, since it checks the
calls rather than the cache behaviour beneath them.

Two outer cache implementations are compiled in, the Hisilicon v200 driver
and the generic L2X0. The boot log establishes that the Hisilicon v200 driver
claims this controller; there is no second L2X0 binding.

Against the thesis: an evicted dirty line writes back the whole line, and the
poison dump shows 4 corrupted bytes followed by 28 bytes of intact `0xaa`
within the same 32 bytes.  A targeted small write fits that pattern better
than a line writeback.  The L2 was also enabled on 2026-08-27, before the
runs of 08-31 and 09-01 that passed, though those used a harness with no
interface reopen.

The discriminating test uses otherwise equivalent builds with and without
`CONFIG_CACHE_HIL2V200`. Expect a throughput drop without the outer cache, so
this is a correctness comparison rather than a benchmark. Cache dependence
does not by itself exclude a DMA-stop race: cache maintenance may expose a
stale mapping, or the cache may change the timing of an asynchronous stop.

The driver binds as `hil2v200: enabled outer cache, 256 KB, 8 ways, 32-byte
lines`, so the Hisilicon v200 driver claims the controller and L2X0 does not.
Its line size matches the 32-byte spacing of the corrupted words, though
enhanced descriptors are also 32 bytes, so the spacing does not discriminate.

The cache-disabled `20260902T231542Z-rx64` run wedged before it reached an
interface reopen. The masked Receive Interrupt [RI] fix then allowed
`20260903T111341Z-rx64` to complete the interface reopen and link-flap cases
under the same cache-disabled memory diagnostics. It transferred about
17.47 GB without page poison, an oops, or a DMA API fault. This is one
negative cache-disabled corruption run; the fault is intermittent, so it is
not sufficient by itself to rule out either corruption thesis.

The matching outer-cache-enabled run `20260903T113600Z-rx64` reproduced the
freed-page write immediately after the interface reopen. The kernel reported
`hil2v200: enabled outer cache, 256 KB, 8 ways, 32-byte lines` at boot. This
one-run A/B result strongly implicates outer-cache state or its interaction
with teardown, but repetition is required because the fault is intermittent.
The exact old-ring and old-buffer correlation on 2026-09-04 establishes DMA
continuing after the resources are freed. Outer-cache state may still change
the race timing, but incorrect cache maintenance is no longer a competing
explanation for the targeted descriptor writebacks and received frame.

## Reproduction

The receive stall used to enter the controlled recovery remains probabilistic:
two fresh-boot 120-second runs passed before the third stalled after 15 seconds.
After manually restarting receive DMA, cycling `eth0` and forcing page reuse
exposed writes into exact old ring resources in that first controlled attempt.
Sustained inbound traffic followed by an interface reopen is the general shape
that has failed;
`tools/ethernet-rx-recovery-test.sh` and `tools/ethernet-rx-wedge-repro.sh`
both drive it.

The debug kernel is what makes a failure legible: `PAGE_POISONING`,
`DEBUG_PAGEALLOC`, `DEBUG_VM`, `DEBUG_LIST`, `DEBUG_SG`, `DEBUG_NET` and
`DMA_API_DEBUG` in `linux.config`, with `slub_debug=FZP debug_pagealloc=on` on
the command line.  It costs about 45% of receive throughput: 407 Mbit/s
against 740.

An earlier suspicion of `tools/ethernet-rx-ring-watch.c` is displaced. The
2026-09-02 page-poison capture ran without the poller and produced the same
class of corruption.

## Next steps

The independent wedge fix now carries both configurations through the reopen
phase, and the outer-cache-enabled run reproduced a freed-page write there.
Take the next steps in this order.

1. Make the traffic harness inspect kernel diagnostics after every phase and
   fail immediately on page corruption, an oops, or another kernel fault.
2. Turn the controlled 2026-09-04 sequence into a harness: record every old
   descriptor and buffer address, reopen the interface, force safe page reuse,
   and correlate every corruption report with the old mappings.
3. Instrument `__stmmac_release()` to capture the DMA Receive Descriptor List
   Address Register [CSR3], DMA Status Register [CSR5], DMA Operation Mode
   Register [CSR6], DMA Current Host Receive Descriptor Register [CSR19], and
   DMA Current Host Receive Buffer Address Register [CSR21]:
   - immediately before `stmmac_stop_all_dma()`;
   - immediately after `stmmac_stop_all_dma()` returns;
   - immediately before `free_dma_desc_resources()` frees the ring.
4. Store all three samples first and print them only after the ring has been
   freed, so UART output cannot delay or conceal the race being measured.
5. If receive DMA is still active at the pre-free sample, test a bounded wait
   for the receive process to stop after clearing Start Receive [SR]. Treat a
   timeout as a diagnostic failure rather than freeing the ring anyway.
6. If the pre-free sample reports the receive process stopped, or the bounded
   wait does not prevent stale writes, test a channel soft reset before freeing
   the old ring.
7. Repeat the discriminating test with the outer cache disabled only after the
   quiescence behavior is instrumented; cache state is now a timing variable,
   not the primary competing mechanism.
8. Reboot immediately after every corruption report. The root filesystem is
   mounted read-write, so check it after reboot before treating the disk as
   sound.

## How the instrumentation distinguishes the causes

- Start Receive [SR] clear with a non-stopped receive process at the pre-free
  sample demonstrates that clearing the bit is asynchronous and that the
  release path frees memory too early.
- An old ring address remaining in the DMA Receive Descriptor List Address
  Register [CSR3], DMA Current Host Receive Descriptor Register [CSR19], or
  DMA Current Host Receive Buffer Address Register [CSR21] identifies exactly
  which freed allocation the hardware can still reach.
- A stopped receive process at every pre-free sample weakens the simple
  stop-versus-free race. Corruption confined to outer-cache-enabled runs would
  then focus the investigation on map, unmap, invalidate, and clean behavior.
- Capturing inside `__stmmac_release()` is required. A console read after the
  syscall cannot observe the interval between stopping DMA and freeing the
  ring.

## Related upstream report

**Memory corruption with large MTUs**, 2019:
<https://lkml.rescloud.iu.edu/1903.2/02787.html>.  A bogus private-data
pointer during DES3 refill left "stale pointers in the RX descriptor ring", so
"DMA will now likely overwrite/corrupt some already freed memory".  Long
merged, and specific to 16K buffers in ring mode, so it does not apply at an
MTU of 1500.  It stands as precedent that stale receive descriptors produce
this corruption signature.

## Relationship between the wedge and corruption

The faults are separable. The cache-disabled run wedged before any release,
with an allocated, structurally valid ring and no poison report. Corruption
is not required to produce the wedge. Conversely, the cache-enabled run with
the interrupt fix completed every traffic case without a receive stall but
still wrote an ARP frame into a free page after reopen. The complete stall
evidence is in
[`bug-rx-refill-stall.md`](bug-rx-refill-stall.md).

An operational sequence remains possible in older runs: the shared-interrupt
bug wedged the interface and recovery then invoked the teardown path that can
expose the corruption. The latest run did not require that sequence. The
explicit reopen was sufficient to precede corruption while the stall fix kept
RX live throughout.

## Open questions

- Does the receive process remain active in an observed release after
  `dwmac_dma_stop_rx()` clears Start Receive [SR] and returns?
- Does recovering from a receive wedge make the release race more likely by
  entering teardown with a frame waiting in the MAC receive FIFO?
- Is the three-channel reset at probe enough to clear a channel left running
  by the previous kernel, or does it need to run at teardown as well?
