# The receive path writes to freed pages

The Hi3531 receive path has written into memory the kernel already reclaimed.
It surfaces as page poison corruption and as an oops in whatever touches the
page next.  A separate receive stall can leave the DMA suspended with the
board off the network.  Both faults occurred in the same run, but the wedge
can occur without corruption and is treated separately here.

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
- The board wedged in the same run with CSR5 `0x00680404`: receive state 4,
  eth0 interrupts frozen, `dmesg` otherwise clean.
- Earlier the same day, without the debug kernel, the corruption surfaced as
  `Unable to handle kernel paging request at virtual address 25242322` in
  `ext4_read_folio`, preceded by `BUG: Bad rss-counter state`.

## What is inferred

`0x004e0380` read as a receive descriptor status is OWN clear with a frame
length of 78 bytes.  Descriptor writeback into memory that is no longer the
ring fits the value, the 32-byte spacing and the timing, but nothing yet
proves the hardware is the writer.

The corruption followed the interface reopen and link flap: link down at 81 s,
up at 86 s, down at 110 s, up at 114 s, corruption reported at 122 s and
128 s.

## The wedge is separable from the corruption

A run on 2026-09-02 with `CACHE_HIL2V200` compiled out, page poisoning live
and no poller wedged during `tcp-3`, the third steady TCP run:
`20260902T231542Z-rx64`.

```text
CSR5 0x00680404   receive state 4
eth0 interrupts   63435, frozen
corruption        none reported
```

- The outer cache was disabled, so it does not explain this wedge.
- `tcp-3` runs before the UDP, bidirectional, soak and reopen cases, so no
  `stmmac_release()` ran and no ring was freed.  The release race does not
  explain this wedge either.
- Page poisoning was active and reported nothing, so this wedge came with no
  corruption.  The two are not always the same fault.

What it does match is the upstream stall: refill leaves no descriptor the DMA
owns, NAPI exits and unmasks, and no interrupt arrives to schedule it again.
Receive state 4 with a frozen interrupt count is that state.

### Live ring state after the wedge

The still-wedged board from `20260902T231542Z-rx64` was read over the UART.
The kernel was 6.18.42 with a 64-entry receive ring, page poisoning and DMA API
debugging.  The link remained up at 1000/full, but the receive packet count,
NAPI poll count and interrupt count did not move.

```text
DMA bus mode                  0x00a01080
DMA transmit poll demand      0x00000000
DMA receive poll demand       0x00000000
DMA receive descriptor base   0x80da8000
DMA transmit descriptor base  0x82014000
DMA status                    0x00680404  receive state 4, transmit state 6
DMA control                   0x03002902  SR remains set
DMA interrupt enable          0x0001a061  RUE is masked
current transmit descriptor   0x82014600
current receive descriptor    0x80da8680  ring entry 52
current transmit buffer       0x8280bc5e
current receive buffer        0x81ee2040
DMA hardware features         0x016def37
GMAC1 configuration           0x00610c0c
GMAC1 frame filter            0x00000404
GMAC1 flow control            0xffff000e
GMAC1 version                 0x00001036
GMAC1 debug                   0x00000220  RX FIFO above threshold,
                                           read controller in status state
TNK status / enable           0x00000000 / 0x00000048
eth0 interrupt count          63436, frozen
rx packets / NAPI polls       3108532 / 63749, frozen
```

All eight words of all 64 enhanced descriptors were read.  Every descriptor
was a clean, completed, full-size frame owned by the CPU:

```text
des0       0x05ee0320  OWN clear, first and last segment, no error,
                       frame length 1518
des1       0x80000600  interrupt disabled, buffer 1 length 1536
des2       per-entry receive buffer address
des3-des7  0
```

Entry 63 had `des1 = 0x80008600`, adding the correct end-of-ring bit.  The
entries around the DMA cursor were:

```text
51  0x80da8660  0x05ee0320  0x80000600  0x8329b040
52  0x80da8680  0x05ee0320  0x80000600  0x81ee2040
53  0x80da86a0  0x05ee0320  0x80000600  0x82bb9040
63  0x80da87e0  0x05ee0320  0x80008600  0x837e8040
```

The current receive-buffer register exactly matched entry 52's buffer, and
the descriptor base and current pointers remained unchanged before and after
the complete dump.  The ring was structurally sound and still programmed into
the DMA.  Its failure state was that software had returned none of its 64
descriptors to DMA ownership.

The strongest explanation is the upstream refill stall:

1. Sustained full-size traffic consumes the 64 DMA-owned descriptors.
2. NAPI processes them, but a receive replacement-page allocation fails and
   `stmmac_rx_refill()` leaves one or more dirty entries unrefilled.
3. This 6.18.42 path returns fewer than the NAPI budget despite the dirty
   entries, so NAPI completes and unmasks the normal receive interrupt.
4. No descriptor remains DMA-owned.  The receive process suspends, while a
   frame waits in the RX FIFO.  It cannot complete another descriptor and
   therefore cannot raise the normal interrupt that would schedule NAPI.
5. Receive-buffer-unavailable interrupts are masked in CSR7, so that event
   cannot restart polling either.

The snapshot establishes the final conditions described in steps 3 through 5,
not the execution path that produced them.  It does not observe the allocation
failure itself; those page-pool allocations are normally `__GFP_NOWARN`.  A
lost NAPI scheduling transition from another cause could leave the same final
state, but the upstream bug is an exact code and hardware-state match.
Instrumenting failed page-pool allocations and `stmmac_rx_dirty()` at NAPI
completion would distinguish them directly.

### No interrupt source remains once polling stops

Read from the same wedged board:

```text
CSR8 receive watchdog     0x000000a0   enabled at the driver default
ch0 CSR3 / CSR5 / CSR6    0 / 0 / 0    quiescent
ch1 CSR3 / CSR5 / CSR6    0x80da8000 / 0x00680404 / 0x03002902
ch2 CSR3 / CSR5 / CSR6    0 / 0 / 0    quiescent
```

`enh_desc_init_rx_desc()` sets `ERDES1_DISABLE_IC` when its `disable_rx_ic`
argument is true, and `stmmac_main.c:1381` passes `priv->use_riwt`.  Every
descriptor in the dump carries `des1` bit 31, so per-descriptor receive
completion interrupts are disabled and the watchdog timer is the only source
of receive interrupts.

That leaves the wedge with no way out.  The watchdog restarts on a newly
completed frame, and the receive process is suspended so no frame can
complete.  Per-descriptor completion interrupts are disabled.  Receive buffer
unavailable is masked in CSR7.  Once software stops collecting with the ring
full, nothing can schedule NAPI again.

Both other DMA channels are quiescent with a zero descriptor base, so no
second channel is running against stale memory.  The driver and the hardware
also agreed on the ring throughout: 3108532 frames were received from the base
still programmed in CSR3, which rules out a mismatched ring base as the cause
of the stall.

The upstream budget fix helps only while the driver is still inside
`stmmac_rx()`.  Unmasking RUE would give this state a recovery path, at the
cost of an interrupt per exhaustion event.

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

Clearing SR asks the receive process to stop when it finishes the descriptor
it is working on, so the state machine can still be transferring data or
closing a descriptor when the write returns.  Nothing between the two
statements waits for CSR5 to report the receive process stopped, and the
pages go back to the allocator immediately.  A descriptor writeback landing
in that window writes into memory the kernel has already reclaimed, which is
the observed corruption.

This race does not explain the fresh-boot wedge above: no release had run and
the live descriptor ring was still allocated and correctly programmed.  It
remains a candidate for the corruption that follows an interface reopen.

This is a thesis.  What supports it is the code path above, the
descriptor-shaped value, the 32-byte spacing and the timing after a reopen.
What is missing is any observation of the receive process still running at
the moment the ring is freed.

If it holds, the fix is to poll CSR5 for the stopped receive state with a
timeout after clearing SR and before freeing, or to soft-reset the channel at
release as `stmmac_init_dma_engine()` already does at open.  The race is in
mainline `dwmac_lib.c`, not in this port's glue, so the hand-rolled
three-channel reset is not implicated.

Testing it needs driver instrumentation rather than a console read: the stop
and the free happen inside one syscall, so userspace cannot sample CSR5
between them.  Log the receive process state inside `__stmmac_release()`
after `stmmac_stop_all_dma()` and again after `free_dma_desc_resources()`.

## Thesis: outer cache maintenance around DMA

`linux.config` carries `CONFIG_OUTER_CACHE`, `CONFIG_OUTER_CACHE_SYNC`,
`CONFIG_CACHE_HIL2V200` and `CONFIG_CACHE_L2X0`, from the L2 work of
2026-08-27.  With an outer cache present, every DMA map and unmap depends on
outer maintenance being correct: an invalidate that misses leaves the CPU
reading stale data, and a dirty line that survives past a free is written back
over whatever occupies the page next.  Wrong maintenance under a correct API
call also explains why `DMA_API_DEBUG` reports nothing, since it checks the
calls rather than the cache behaviour beneath them.

Two outer cache implementations are enabled at once, the Hisilicon v200 driver
and the generic L2X0.  Which one binds, and whether both attempt to, is worth
establishing before anything else here.

Against the thesis: an evicted dirty line writes back the whole line, and the
poison dump shows 4 corrupted bytes followed by 28 bytes of intact `0xaa`
within the same 32 bytes.  A targeted small write fits that pattern better
than a line writeback.  The L2 was also enabled on 2026-08-27, before the
runs of 08-31 and 09-01 that passed, though those used a harness with no
interface reopen.

The test is a build with `CONFIG_CACHE_HIL2V200=n`.  If the corruption stops
without the outer cache and returns with it, this thesis holds and the stmmac
release race does not.  Expect a throughput drop, so it is a correctness run
rather than a benchmark.

The driver binds as `hil2v200: enabled outer cache, 256 KB, 8 ways, 32-byte
lines`, so the Hisilicon v200 driver claims the controller and L2X0 does not.
Its line size matches the 32-byte spacing of the corrupted words, though
enhanced descriptors are also 32 bytes, so the spacing does not discriminate.

The cache-disabled `20260902T231542Z-rx64` run wedged before it reached an
interface reopen.  Its lack of corruption rules the cache out as the cause of
that wedge, but it did not exercise the phase which has exposed corruption and
therefore is not yet a negative test of the cache-corruption thesis.

## Reproduction

Not deterministic.  Two full runs at a 64-entry ring passed before this one
failed, and runs at the 512-entry default have passed repeatedly.  Sustained
inbound traffic followed by an interface reopen is the shape that has failed;
`tools/ethernet-rx-recovery-test.sh` and `tools/ethernet-rx-wedge-repro.sh`
both drive it.

The debug kernel is what makes a failure legible: `PAGE_POISONING`,
`DEBUG_PAGEALLOC`, `DEBUG_VM`, `DEBUG_LIST`, `DEBUG_SG`, `DEBUG_NET` and
`DMA_API_DEBUG` in `linux.config`, with `slub_debug=FZP debug_pagealloc=on` on
the command line.  It costs about 45% of receive throughput: 407 Mbit/s
against 740.

An earlier suspicion of `tools/ethernet-rx-ring-watch.c` is displaced.  Every
failure before this one happened in a boot where the poller had run, but this
run had none and produced the same corruption.

## Next steps

The independent wedge has to be removed before a corruption run can reliably
reach the reopen phase.  Take the next steps in this order.

1. Backport the upstream `stmmac_rx_dirty()` NAPI-budget fix and repeat the
   64-entry debug run.  Instrument page-pool allocation failure and dirty-ring
   state if the fixed kernel can still wedge.
2. With that fix, run through the reopen cases with
   `CONFIG_CACHE_HIL2V200=n`.  Corruption here rules out outer-cache
   maintenance and leaves teardown as the leading thesis.
3. Repeat the same run with the Hisilicon outer cache enabled.  Corruption
   appearing only in this configuration supports the cache thesis.  Because
   the fault is intermittent, use repeated fresh boots on each side.
4. If corruption survives without the outer cache, instrument
   `__stmmac_release()` to log CSR5, CSR6 and CSR3 before the stop, after
   `stmmac_stop_all_dma()` and immediately before freeing the descriptors.  A
   receive process still active at the free confirms the release race.
5. Reboot between runs.  A board that has corrupted its own memory cannot be
   trusted to produce a meaningful next result, and the root filesystem is
   mounted read-write, so check it before treating the disk as sound.

## How to establish the cause

Cheapest first.  The register offsets below are recalled rather than checked
against `dwmac_dma.h`.

1. Read the receive process state around the teardown.  On the console, take
   the interface down and read CSR5 and CSR6.  A receive state other than 0,
   or CSR6 bit 1 still set, means the DMA is live while the ring is freed.
2. Compare the descriptor list address across a reopen.  CSR3 holds the
   receive descriptor base, believed to be at `0x101c110c` for channel 1.
   Record it before the down, after the down and after the up.  If it still
   holds the old ring's address after the ring is freed, the hardware is
   pointed at reclaimed memory.
3. Log CSR5, CSR6 and CSR3 from inside `stmmac_release`: before the DMA stop,
   after it, and after `free_dma_desc_resources`.  Diagnostic-only driver
   code, to be removed once the result is established.
4. Compare runs with and without the reopen and flap cases, several
   repetitions each side, to establish whether teardown is necessary for the
   fault.  Weak on its own, because the fault is intermittent.

## Related upstream reports

**Indefinite RX stall on buffer exhaustion**, net v3, March 2026:
<https://lkml.iu.edu/hypermail/linux/kernel/2603.3/10555.html>.  When
`stmmac_rx_refill()` fails the driver "will stop NAPI polling and unmask
interrupts to await an interrupt that will never arrive, stalling the receive
pipeline indefinitely".  The fix returns the full budget from `stmmac_rx()`
when `stmmac_rx_dirty()` is nonzero, so NAPI keeps polling.

That is absent from 6.18.42: `stmmac_rx()` ends with `stmmac_rx_refill()` and
returns `count`, while the zero-copy path already carries the equivalent guard
at `stmmac_main.c:5389`.  It describes this port's wedge exactly.  Its trigger
is an allocation failure, and the wedged kernel logged none, though page-pool
allocations in NAPI context are often `__GFP_NOWARN` so silence is not proof.

**Memory corruption with large MTUs**, 2019:
<https://lkml.rescloud.iu.edu/1903.2/02787.html>.  A bogus private-data
pointer during DES3 refill left "stale pointers in the RX descriptor ring", so
"DMA will now likely overwrite/corrupt some already freed memory".  Long
merged, and specific to 16K buffers in ring mode, so it does not apply at an
MTU of 1500.  It stands as precedent that stale receive descriptors produce
this corruption signature.

## Relationship between the wedge and corruption

The faults are separable.  The cache-disabled run wedged before any release,
with an allocated, structurally valid ring and no poison report.  Corruption
is not required to produce the wedge.

A causal sequence is still possible.  The refill bug can wedge the interface,
the recovery harness can respond by reopening it, and a separate asynchronous
DMA-stop race can then write back into the ring after it is freed.  In that
model the wedge triggers the operation that exposes the corruption without
being the memory-corruption mechanism itself.  Backporting the refill fix is
therefore necessary both to test the known stall and to let cache-disabled
corruption runs reach the reopen phase consistently.

## Open questions

- Does `dwmac_dma_stop_rx` wait for the receive process to reach the stopped
  state, or clear the start bit and return?  If it does not wait, the race is
  in mainline rather than in this port's glue.
- Is a transient page-pool allocation failure the initial event in every
  wedge, or can another NAPI exit path leave the same all-CPU-owned ring?
- Does recovering from a refill wedge make the release race more likely by
  entering teardown with a frame waiting in the MAC receive FIFO?
- Is the three-channel reset at probe enough to clear a channel left running
  by the previous kernel, or does it need to run at teardown as well?
