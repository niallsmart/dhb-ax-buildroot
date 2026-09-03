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

## Thesis: the ring is freed before the receive process stops

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
the live descriptor ring was still allocated and correctly programmed.  It
remains a candidate for the corruption that follows an interface reopen.

This is a thesis. What supports it is the code path above, the two corruption
captures, the descriptor-shaped value, the 32-byte spacing, and the timing
after a reopen. What is missing is any observation of the receive process
still running at the moment the ring is freed.

If it holds, the fix is to poll the DMA Status Register [CSR5] for the stopped
receive state with a timeout after clearing Start Receive [SR] and before
freeing, or to soft-reset the channel at release as
`stmmac_init_dma_engine()` already does at open. The race is in mainline
`dwmac_lib.c`, not in this port's glue, so the hand-rolled three-channel reset
is not implicated.

Testing it needs driver instrumentation rather than a console read: the stop
and the free happen inside one syscall, so userspace cannot sample the DMA
Status Register [CSR5] between them. Capture the relevant DMA registers inside
`__stmmac_release()` before the stop, after the stop, and immediately before
the free. Store the samples and print them after the free so the logging does
not change the interval under investigation.

## Thesis: outer cache maintenance around DMA

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
It does not yet distinguish incorrect cache maintenance from DMA continuing
after the ring is freed.

## Reproduction

Not deterministic. Two full runs at a 64-entry ring passed before the first
page-poison capture, and runs at the 512-entry default have passed repeatedly.
Sustained inbound traffic followed by an interface reopen is the shape that
has failed;
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
2. Instrument `__stmmac_release()` to capture the DMA Receive Descriptor List
   Address Register [CSR3], DMA Status Register [CSR5], DMA Operation Mode
   Register [CSR6], DMA Current Host Receive Descriptor Register [CSR19], and
   DMA Current Host Receive Buffer Address Register [CSR21]:
   - immediately before `stmmac_stop_all_dma()`;
   - immediately after `stmmac_stop_all_dma()` returns;
   - immediately before `free_dma_desc_resources()` frees the ring.
3. Store all three samples first and print them only after the ring has been
   freed, so UART output cannot delay or conceal the race being measured.
4. Repeat fresh-boot 64-entry runs with the outer cache enabled and disabled.
   Separate runs with and without the reopen phase will establish whether
   teardown is necessary. The register samples will show whether receive DMA
   remains active or points at the old ring when it is freed.
5. If receive DMA is still active at the pre-free sample, test a bounded wait
   for the receive process to stop after clearing Start Receive [SR]. Treat a
   timeout as a diagnostic failure rather than freeing the ring anyway.
6. Reboot immediately after every corruption report. The root filesystem is
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
