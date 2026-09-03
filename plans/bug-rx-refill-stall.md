# A masked receive interrupt can leave the receive ring stalled

## Status

The failure is a race in the legacy stmmac shared DMA interrupt handler.
Patch `0018-net-stmmac-preserve-masked-rx-interrupt-status.patch` implements
the candidate fix and adds temporary counters that observe the race.

Patch `0016-net-stmmac-record-rx-refill-starvation.patch` is instrumentation
only. It helped exclude receive-buffer allocation failure and does not change
recovery behavior.

This bug is distinct from the receive-path memory corruption tracked in
[`bug-rx-writes-freed-pages.md`](bug-rx-writes-freed-pages.md). The stall
reproduces before interface teardown, with or without the Hisilicon outer
cache, and on a non-debug kernel that reports no memory corruption.

## Symptom

During sustained traffic, `eth0` stops receiving while the physical link and
interface remain up. The UART remains usable, but network access does not
recover. The terminal state is:

- DMA Operation Mode Register [CSR6] retains Start Receive [SR].
- DMA Interrupt Enable Register [CSR7] retains Receive Interrupt Enable [RIE].
- DMA Status Register [CSR5] reports receive-process state 4, suspended.
- Receive Interrupt [RI], Receive Buffer Unavailable [RU], and Receive Process
  Stopped [RPS] are clear.
- Every receive descriptor has DMA Ownership [OWN] clear, so the CPU owns the
  entire ring.
- The interrupt count, receive counters, descriptor cursor, and NAPI poll
  count stop advancing.

The DMA cannot receive another frame because it owns no descriptor. NAPI is
not running to refill the ring, and no pending receive event remains to wake
it.

## Reproduction

A 64-entry receive ring makes the race frequent enough to reproduce under
bidirectional TCP traffic. The ring size is selected with
`stmmac.rx_ring_size=64`; `ethtool -g eth0` must confirm the effective value.

The clearest baseline is
`artifacts/ethernet-tests/20260903T124152Z-nondebug-rx64/`. It used Linux
6.18.42 with the Hisilicon outer cache enabled and the following debug options
disabled:

```text
# CONFIG_DMA_API_DEBUG is not set
# CONFIG_DEBUG_KERNEL is not set
# CONFIG_PAGE_POISONING is not set
```

The image contained neither patch 0016 nor patch 0018. A first fresh-boot,
four-stream bidirectional TCP trial completed its ten-minute limit. The next
fresh-boot trial entered the terminal state after 135.188 seconds and remained
there for the remaining 407.697 seconds of UART observation.

```text
DMA Status Register [CSR5]                    0x00680404
  receive-process state                       4, suspended
  Receive Interrupt [RI]                      clear
  Receive Buffer Unavailable [RU]             clear
  Receive Process Stopped [RPS]               clear
DMA Operation Mode Register [CSR6]            0x03002902
  Start Receive [SR]                          set
DMA Interrupt Enable Register [CSR7]          0x0001a061
  Receive Interrupt Enable [RIE]              set
Receive Descriptor List Address Register
  [CSR3]                                      0x80d70000
Current Host Receive Descriptor Register
  [CSR19]                                     0x80d70280, ring entry 20
receive ring                                  64 of 64 CPU-owned
kernel fault or corruption report             none
```

The full 32-byte extended-descriptor dump was stable and had DMA Ownership
[OWN] clear in every entry. Complete image provenance, watcher output, UART
capture, and descriptor data are in that artifact directory.

An unfixed run passing once does not exclude the bug. The two consecutive
non-debug trials above ranged from a ten-minute pass to failure in just over
two minutes because the trigger depends on interrupt timing.

## Root cause

The legacy stmmac receive and transmit paths share one DMA interrupt handler.
`stmmac_dma_interrupt()` calls `stmmac_napi_check()` with `DMA_DIR_RXTX`, and
`dwmac_dma_interrupt()` reads and acknowledges the combined receive and
transmit status.

The failure sequence is:

1. RX NAPI clears Receive Interrupt Enable [RIE] while polling.
2. Receive Interrupt [RI] becomes pending during that interval.
3. Transmit Interrupt [TI] invokes the shared DMA interrupt handler.
4. The handler reads both causes from DMA Status Register [CSR5]. Because
   Receive Interrupt Enable [RIE] is clear, it correctly declines to schedule
   RX NAPI again.
5. The handler nevertheless includes Receive Interrupt [RI] in its
   write-one-to-clear acknowledgement, destroying the pending receive event.
6. NAPI completes and restores Receive Interrupt Enable [RIE], but the event
   that should wake the next poll is gone. The DMA consumes the remaining
   descriptors, suspends when the ring is empty, and cannot generate another
   receive completion.

The failure is therefore not that the driver detects an empty ring and fails
to refill it. The driver loses the interrupt that would make it inspect and
refill the ring.

## Fix

Patch `0018-net-stmmac-preserve-masked-rx-interrupt-status.patch` changes the
legacy DMA interrupt acknowledgement. If Receive Interrupt [RI] is pending
while Receive Interrupt Enable [RIE] is clear, the handler omits Receive
Interrupt [RI] from the write-one-to-clear value. It still acknowledges the
other causes, including Transmit Interrupt [TI].

When NAPI completes and restores Receive Interrupt Enable [RIE], the preserved
Receive Interrupt [RI] schedules the next poll through the normal interrupt
path. The fix does not poll the ring after every NAPI completion and does not
keep NAPI running solely because descriptors are CPU-owned.

Patch 0018 also exposes two temporary ethtool counters:

- `rx_irq_preserved_while_masked`: Receive Interrupt [RI] was preserved while
  Receive Interrupt Enable [RIE] was clear.
- `rx_irq_preserved_with_tx`: the preserved Receive Interrupt [RI] coincided
  with Transmit Interrupt [TI].

These counters are diagnostic; preserving the status bit is the behavioral
fix.

## Validation

The fix completed the receive-liveness suite with a 64-entry ring under both
cache configurations:

| Artifact | Outer cache | Traffic completed | Preserved events | With Transmit Interrupt [TI] | Stall |
| --- | --- | --- | ---: | ---: | --- |
| `20260903T111341Z-rx64` | disabled | full suite, including 180-second soak | 41,434 | 41,301 | none |
| `20260903T113600Z-rx64` | enabled | full suite, including 180-second soak | 48,199 | 48,149 | none |

In the two runs, 99.7% and 99.9% of preserved receive events coincided with
Transmit Interrupt [TI]. This directly observes the shared-interrupt timing
required by the proposed root cause. DMA Status Register [CSR5] ended at
`0x006e0000`, with receive-process state 7 rather than the terminal suspended
state 4.

The cache-enabled run later reported page-poison corruption after an interface
reopen. Traffic continued and no receive stall occurred. That result belongs
to the separate memory-corruption bug; it does not invalidate the receive-ring
liveness result.

## Paths excluded

- **Receive-refill allocation failure:** Patch 0016 recorded no page-allocation
  failures. At the last NAPI completion before each stall, `cur_rx` equalled
  `dirty_rx` and the dirty count was zero, so no processed descriptors were
  awaiting refill. Separately, the terminal ring dump showed all 64
  descriptors CPU-owned and holding completed frames awaiting NAPI processing.
- **The proposed upstream refill retry:** The March 2026 stmmac proposal at
  <https://lore.kernel.org/netdev/20260328192503.520689-3-CFSworks@gmail.com/>
  keeps NAPI polling after an allocation failure. Its retry branch never ran
  in these failures, so it addresses a different stall mode.
- **Receive Interrupt Watchdog Timer [RIWT] moderation:** The stall reproduced
  with the normal value `0xa0`, the minimum value `0x10`, and with the timer
  disabled. Disabling the timer also cleared Disable Interrupt on Completion
  [DIC] on every descriptor without preventing the failure.
- **Inspecting the ring after NAPI completion:** A candidate that rescheduled
  NAPI when the next descriptor was CPU-owned prevented the permanent
  terminal state, but could keep NAPI continuously scheduled under load. It
  treated the symptom and was replaced by preserving the lost interrupt.

## Remaining work

1. Make the traffic harness fail immediately on an oops, page corruption, or
   another kernel diagnostic so a liveness pass cannot conceal the separate
   memory-corruption failure.
2. Repeat the fixed 64-entry-ring test across fresh boots on a non-debug kernel
   without interface teardown.
3. Validate the fixed driver with the production 512-entry ring after the
   diagnostic check is in place.
4. Remove patch 0016 and the two temporary counters from patch 0018 after the
   repeated validation, retaining only the masked-status acknowledgement fix.
5. Decide whether the fix should be submitted upstream for all legacy DWMAC
   integrations or initially scoped to this hardware.
