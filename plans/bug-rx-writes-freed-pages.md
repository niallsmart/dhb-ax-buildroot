# The receive path writes to freed pages

The Hi3531 receive path writes into memory the kernel has already reclaimed.
It surfaces as page poison corruption, as an oops in whatever touches the page
next, and as a receive DMA left suspended with the board off the network.

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

## Are the wedge and the corruption one fault?

Undecided.  Buffers released while the DMA still owns them would produce both:
descriptor writes into reclaimed pages, and a ring holding nothing the DMA
owns.  The upstream stall is a separate mechanism that needs only an
allocation failure.

Backporting the stall fix and rerunning on the debug kernel separates them.
Wedges stopping while poison reports continue means two faults; both stopping
means one.

## Open questions

- Does `dwmac_dma_stop_rx` wait for the receive process to reach the stopped
  state, or clear the start bit and return?  If it does not wait, the race is
  in mainline rather than in this port's glue.
- Does the wedge share this cause?  A DMA following stale descriptors until it
  suspends would be the same fault seen from the other side.
- Is the three-channel reset at probe enough to clear a channel left running
  by the previous kernel, or does it need to run at teardown as well?
