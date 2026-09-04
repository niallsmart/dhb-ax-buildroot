# RX refill stall: plain-language explanation

The legacy DWMAC driver handles receive and transmit events through one shared
interrupt path. While RX NAPI is polling, the driver masks receive interrupts
but leaves transmit interrupts enabled. The stall occurs when the shared
handler acknowledges a receive status that arrived while receive interrupts
were masked, even though that invocation does not schedule another RX poll.

The walkthrough below follows the simplest execution: while receive interrupts
are masked, the RX DMA consumes every available descriptor and the final
completion leaves `RI` pending. A transmit interrupt then causes the shared
handler to clear that receive status while the RX ring is already empty.

For the register-by-register version, see the
[detailed trigger sequence](rx-refill-stall-sequence.md).

## Terms used below

| Term | Plain-language meaning |
| --- | --- |
| `RI` | A receive event is waiting to be handled. |
| `RIE` | Receive events are allowed to raise the shared interrupt. |
| `TI` / `TIE` | The corresponding status and enable flags for transmit events. |
| `OWN` | Identifies whether a receive descriptor belongs to the DMA or the CPU. |
| RX NAPI | The driver's deferred receive-processing loop. It processes completed descriptors and returns them to the DMA. |

## How the stall happens

<table style="table-layout: fixed; width: 100%; overflow-wrap: anywhere;">
<colgroup>
  <col style="width: 5%;" width="5%">
  <col style="width: 19%;" width="19%">
  <col style="width: 38%;" width="38%">
  <col style="width: 38%;" width="38%">
</colgroup>
<thead>
<tr>
  <th></th>
  <th>Actor and context</th>
  <th>What happens</th>
  <th>Why it matters</th>
</tr>
</thead>
<tbody>
<tr>
  <td>1</td>
  <td><strong>RX DMA</strong><br>Hardware</td>
  <td>Completes a received frame, returns its descriptor to the CPU, and sets <code>RI</code>.</td>
  <td>Because <code>RIE</code> is enabled, the shared interrupt is raised.</td>
</tr>
<tr>
  <td>2</td>
  <td><strong>stmmac interrupt path</strong><br>Hard IRQ</td>
  <td>Acknowledges the initial <code>RI</code>, disables <code>RIE</code>, and schedules RX NAPI. Transmit interrupts remain enabled.</td>
  <td>RX work moves out of the hard interrupt handler, and new receive status can accumulate while RX interrupts are masked.</td>
</tr>
<tr>
  <td>3</td>
  <td><strong>Linux IRQ core</strong><br>Hard-IRQ exit</td>
  <td>Leaves hard-IRQ context and makes the scheduled RX NAPI poll eligible to run.</td>
  <td>Receive processing can run in the interrupt-exit tail or later through the normal softirq mechanism.</td>
</tr>
<tr>
  <td>4</td>
  <td><strong>RX NAPI</strong><br>NAPI softirq</td>
  <td>Processes completed receive descriptors, stops when it reaches a DMA-owned descriptor, and refills the descriptors it processed. It has not yet re-enabled <code>RIE</code>.</td>
  <td>The DMA has receive buffers again, but this NAPI invocation will not scan them a second time before it completes.</td>
</tr>
<tr>
  <td>5</td>
  <td><strong>RX DMA</strong><br>Hardware</td>
  <td>Consumes every available receive descriptor while <code>RIE</code> is disabled. The final completion returns the last descriptor to the CPU, sets <code>RI</code>, and leaves the DMA suspended with no receive buffer.</td>
  <td>The receive status is latched but cannot raise the shared interrupt. The DMA cannot complete another frame unless RX NAPI returns descriptors to it.</td>
</tr>
<tr>
  <td>6</td>
  <td><strong>TX DMA</strong><br>Hardware</td>
  <td>Completes transmit work and sets <code>TI</code>.</td>
  <td><code>TIE</code> is still enabled, so the transmit event raises the shared interrupt while RX NAPI is running.</td>
</tr>
<tr>
  <td>7</td>
  <td><strong>stmmac interrupt path</strong><br>Hard IRQ</td>
  <td>Handles the enabled transmit event. It sees the masked <code>RI</code> as well, but does not request another RX poll because <code>RIE</code> is disabled. The unfixed handler nevertheless acknowledges both <code>TI</code> and <code>RI</code>, then schedules TX NAPI.</td>
  <td>The only pending RX wakeup is erased without arranging any replacement RX work, while the RX DMA already has no descriptor it can use.</td>
</tr>
<tr>
  <td>8</td>
  <td><strong>Linux IRQ core</strong><br>Hard-IRQ exit</td>
  <td>Leaves the second hard-interrupt invocation and allows the interrupted RX NAPI poll to resume.</td>
  <td>RX NAPI continues from where it was preempted; it does not restart its descriptor scan.</td>
</tr>
<tr>
  <td>9</td>
  <td><strong>RX NAPI</strong><br>NAPI softirq</td>
  <td>Completes its current poll and re-enables <code>RIE</code>.</td>
  <td>Re-enabling <code>RIE</code> does not raise an interrupt because the unfixed handler already cleared <code>RI</code>.</td>
</tr>
<tr>
  <td>10</td>
  <td><strong>RX DMA</strong><br>Hardware</td>
  <td>Remains suspended because it owns no receive descriptor. It cannot complete another frame and therefore cannot create a new receive event.</td>
  <td>The driver has no pending receive status that would schedule RX NAPI to refill the ring. The receive path is stalled.</td>
</tr>
</tbody>
</table>

The decisive mistake is in step 7: the handler treats the masked `RI` as
something to acknowledge even though it did not arrange for RX NAPI to handle
the associated work. After that, the driver and DMA can end up waiting on each
other: NAPI is waiting for another interrupt, and the DMA is waiting for NAPI
to return receive descriptors.

## How patch 0018 prevents it

Patch 0018 removes a pending `RI` from the acknowledgement value when `RIE` is
disabled. The transmit event is still acknowledged and TX NAPI is still
scheduled, but the receive status remains latched.

When RX NAPI re-enables `RIE` in step 9, the preserved `RI` can raise the shared
interrupt immediately; it does not require another packet completion. The
normal interrupt path then schedules another RX NAPI poll, which processes and
refills the receive descriptors before the normal RX IRQ/NAPI path stalls.

## Conditions that matter

This failure requires the following overlap:

- RX NAPI is active, so `RIE` is disabled while transmit interrupts remain
  enabled.
- A receive completion leaves `RI` pending during that interval.
- A transmit event invokes the shared handler, which sees both `TI` and the
  masked `RI`.
- The unfixed handler clears `RI` without scheduling another RX poll.
- The RX DMA has already run out of receive descriptors, so it cannot produce a
  later completion that would set `RI` again.

The precise timing and number of descriptors can vary. Those details affect
how likely the race is, but not the underlying failure: a pending RX wakeup is
acknowledged without preserving it or scheduling equivalent RX work.
