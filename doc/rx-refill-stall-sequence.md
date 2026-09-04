# Receive-ring stall trigger sequence

The legacy DWMAC RX and TX paths share an interrupt handler. RX NAPI masks
receive interrupts while polling, but transmit interrupts remain enabled. A
persistent stall in the normal RX IRQ/NAPI path can follow this causal ordering:

```text
last RI-producing RX completion -> buggy RI acknowledgement -> RIE re-enabled
-> non-interrupt-producing RX completions exhaust the ring
```

The DMA need not consume every available RX descriptor before the
acknowledgement. It need only pass the last completion that asserts `RI` under
the active RX interrupt-mitigation policy. One or more DMA-owned descriptors
can remain; if their completions do not assert `RI` and no receive-watchdog
event intervenes, the DMA can drain them after `RIE` is re-enabled without
waking RX NAPI. The stricter ordering in which the ring is already exhausted
at acknowledgement time is also sufficient. It is a simpler zero-tail variant,
not the `u>0` execution selected for the table. Sustained bidirectional traffic
and a reduced ring make the required overlap more likely.

The sequence models DMA channel 0 in the legacy single-channel, shared-IRQ path
with ordinary separate RX and TX NAPI instances. No other DMA channel
contributes interrupt status. Both interrupt invocations pass the early-return
checks and reach the DMA handler. RX NAPI is idle when the first interrupt
arrives, TX NAPI is idle when the TX-triggered interrupt arrives, and each
successful NAPI scheduling or completion transition shown below takes its
corresponding conditional branch.

The legacy default mask leaves Receive Buffer Unavailable Enable (`RUE`) and
Receive Stopped Enable (`RSE`) clear. Ring exhaustion may set the corresponding
raw `RU` or `RPS` status, but those sources do not raise the modeled second
interrupt, and no other enabled abnormal cause is pending. The state rows list
the register and descriptor state relevant to the causal argument rather than
every CSR5 status bit.

The register trace assumes that `NIS` summarizes enabled normal causes: `RI`
may remain set while `RIE=0` without asserting `NIS`, and changing `RIE` to 1
while `RI=1` can assert `NIS` and the IRQ without a new RX completion. Patch
0018 depends on this hardware behavior. The trace also assumes that completion
of an interrupt-suppressed RX descriptor does not set `RI`, and that no receive
watchdog event sets `RI` before the remaining descriptors are exhausted. These
are hardware-behavior premises of the selected execution.

## Register and state quick reference

| Register or state | Flag or field | Meaning |
| --- | --- | --- |
| CSR5 DMA Status Register | Normal Interrupt Summary (NIS) | An enabled normal interrupt cause is pending. |
|  | Receive Interrupt (RI) | Receive-completion status. Writing one acknowledges it. |
|  | Receive Process Stopped (RPS) | The receive process stopped. |
|  | Receive Process State (RS) | State 4 means suspended for lack of an RX buffer. |
|  | Receive Buffer Unavailable (RU) | The receive DMA found no available buffer. |
|  | Transmit Interrupt (TI) | Transmit-completion status. Writing one acknowledges it. |
| CSR6 DMA Operation Mode Register | Start Receive (SR) | The receive engine is enabled; this does not guarantee that a descriptor is available. |
| CSR7 DMA Interrupt Enable Register | Normal Interrupt Summary Enable (NIE) | Enables normal interrupt summary delivery. |
|  | Receive Interrupt Enable (RIE) | Enables delivery of receive interrupts. |
|  | Transmit Interrupt Enable (TIE) | Enables delivery of transmit interrupts. |
| OWN DMA Ownership |  | `OWN=1` means DMA-owned; `OWN=0` means CPU-owned. |

In the state columns, `D` is the number of DMA-owned RX descriptors. Thus
`D=0` is equivalent to every RX descriptor having `OWN=0`. The value `d>=1`
is the number of DMA-owned RX descriptors remaining after the initial
completion in step 1, and `r>0` is the number of descriptors refilled. The
table defines `u`, where `0<u<d+r`, as the number still DMA-owned after step
10's last completion that asserts `RI`. Those `u` descriptors do not assert
`RI` when completed during the modeled interval. The zero-tail variant is not
represented by `u` in this table.
Every step uses the same five register-state rows beneath its narrative row:
`RI` and `RIE`, `TI` and `TIE`, `NIS` and `NIE`, `RS` and `SR`, then `OWN`
and `D`. The Entry State and Exit State headings each span their two value
columns.

## Trigger sequence

RX NAPI and the RX DMA can run concurrently. The table selects one valid total
ordering in which NAPI completes the refill before the DMA consumes the newly
available descriptors. Other interleavings can produce the same terminal state
provided the last completion that asserts `RI` occurs before the buggy
acknowledgement and no later RX event asserts `RI` before ring exhaustion.

The IRQ-context rows select an allowed Linux schedule in which RX NAPI begins
after the first interrupt exits, the TX interrupt preempts it before
completion, and the interrupted RX NAPI invocation resumes after the second
interrupt exits.

<div style="page-break-after: always;"></div>

<table style="table-layout: fixed; width: 100%; overflow-wrap: anywhere;">
<colgroup>
  <col style="width: 5%;" width="5%">
  <col style="width: 14%;" width="14%">
  <col style="width: 10%;" width="10%">
  <col style="width: 40%;" width="40%">
  <col style="width: 7.75%;" width="7.75%">
  <col style="width: 7.75%;" width="7.75%">
  <col style="width: 7.75%;" width="7.75%">
  <col style="width: 7.75%;" width="7.75%">
</colgroup>
<thead>
<tr>
  <th></th>
  <th>Actor</th>
  <th>Execution Context</th>
  <th>Description</th>
  <th colspan="2">Entry State</th>
  <th colspan="2">Exit State</th>
</tr>
</thead>
<tbody>
<tr>
  <td rowspan="6">1</td>
  <td rowspan="6">RX DMA</td>
  <td rowspan="6">DMA</td>
  <td rowspan="6">Completes a received frame in an RX descriptor, clears that descriptor's <code>OWN</code> bit, and sets <code>RI</code>. With the normal interrupt enabled, this makes the shared interrupt pending.</td>
  <td colspan="2">RX NAPI is idle, and at least two descriptors are available to the DMA.</td>
  <td colspan="2">The shared IRQ is pending; the completed descriptor is CPU-owned, and at least one DMA-owned descriptor remains.</td>
</tr>
<tr>
  <td><code>RI=0</code></td>
  <td><code>RIE=1</code></td>
  <td><strong><code>RI=1</code></strong></td>
  <td><code>RIE=1</code></td>
</tr>
<tr>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
</tr>
<tr>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
  <td><strong><code>NIS=1</code></strong></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=1</code></td>
  <td><code>D=d+1</code></td>
  <td><strong><code>OWN=0</code></strong></td>
  <td><strong><code>D=d</code></strong></td>
</tr>

<tr>
  <td rowspan="6">2</td>
  <td rowspan="6">Linux IRQ core</td>
  <td rowspan="6">Hard interrupt entry</td>
  <td rowspan="6">Accepts the RX-triggered shared interrupt, enters hard-IRQ context, and dispatches <code>stmmac_interrupt()</code>. The driver begins handling the interrupt in step 3.</td>
  <td colspan="2">The shared IRQ is pending; hard-IRQ context is inactive; RX NAPI is idle.</td>
  <td colspan="2">Hard-IRQ context is active, and <code>stmmac_interrupt()</code> has been dispatched.</td>
</tr>
<tr>
  <td><code>RI=1</code></td>
  <td><code>RIE=1</code></td>
  <td><code>RI=1</code></td>
  <td><code>RIE=1</code></td>
</tr>
<tr>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
</tr>
<tr>
  <td><code>NIS=1</code></td>
  <td><code>NIE=1</code></td>
  <td><code>NIS=1</code></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=varies</code></td>
  <td><code>D=d</code></td>
  <td><code>OWN=varies</code></td>
  <td><code>D=d</code></td>
</tr>

<tr>
  <td rowspan="6">3</td>
  <td rowspan="6">Main interrupt handler</td>
  <td rowspan="6">Hard interrupt</td>
  <td rowspan="6">Runs <code>stmmac_interrupt()</code> after the IRQ-core dispatch in step 2. After the assumed early-return checks, it first calls <code>stmmac_common_interrupt()</code>, which does not change the tracked state in this sequence, and then calls <code>stmmac_dma_interrupt()</code>. It has not yet interpreted or acknowledged CSR5.</td>
  <td colspan="2">Hard-IRQ context is active; RX NAPI is idle.</td>
  <td colspan="2">The DMA interrupt path has been entered.</td>
</tr>
<tr>
  <td><code>RI=1</code></td>
  <td><code>RIE=1</code></td>
  <td><code>RI=1</code></td>
  <td><code>RIE=1</code></td>
</tr>
<tr>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
</tr>
<tr>
  <td><code>NIS=1</code></td>
  <td><code>NIE=1</code></td>
  <td><code>NIS=1</code></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=varies</code></td>
  <td><code>D=d</code></td>
  <td><code>OWN=varies</code></td>
  <td><code>D=d</code></td>
</tr>

<tr>
  <td rowspan="6">4</td>
  <td rowspan="6">Legacy DMA interrupt handler</td>
  <td rowspan="6">Hard interrupt</td>
  <td rowspan="6"><code>dwmac_dma_interrupt()</code> reads CSR5 and CSR7, observes <code>RI=1</code> with <code>RIE=1</code>, and includes <code>handle_rx</code> in its return status. It acknowledges the initial <code>RI</code> by writing the status value back to CSR5.</td>
  <td colspan="2">RX work has not yet been requested by this invocation.</td>
  <td colspan="2">The returned status contains <code>handle_rx</code>, and the initial RX status is acknowledged.</td>
</tr>
<tr>
  <td><code>RI=1</code></td>
  <td><code>RIE=1</code></td>
  <td><strong><code>RI=0</code></strong></td>
  <td><code>RIE=1</code></td>
</tr>
<tr>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
</tr>
<tr>
  <td><code>NIS=1</code></td>
  <td><code>NIE=1</code></td>
  <td><strong><code>NIS=0</code></strong></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=varies</code></td>
  <td><code>D=d</code></td>
  <td><code>OWN=varies</code></td>
  <td><code>D=d</code></td>
</tr>

<tr>
  <td rowspan="6">5</td>
  <td rowspan="6">NAPI scheduling path</td>
  <td rowspan="6">Hard interrupt</td>
  <td rowspan="6"><code>stmmac_napi_check()</code> receives <code>handle_rx</code>, and <code>napi_schedule_prep()</code> succeeds for RX NAPI. It calls <code>stmmac_disable_dma_irq()</code> to clear <code>RIE</code>, then schedules the RX poll. The mask helper changes the RX enable without clearing <code>TIE</code>.</td>
  <td colspan="2">RX NAPI is idle, and completed RX descriptors are present.</td>
  <td colspan="2">RX NAPI is scheduled.</td>
</tr>
<tr>
  <td><code>RI=0</code></td>
  <td><code>RIE=1</code></td>
  <td><code>RI=0</code></td>
  <td><strong><code>RIE=0</code></strong></td>
</tr>
<tr>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
</tr>
<tr>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=varies</code></td>
  <td><code>D=d</code></td>
  <td><code>OWN=varies</code></td>
  <td><code>D=d</code></td>
</tr>

<tr>
  <td rowspan="6">6</td>
  <td rowspan="6">Linux IRQ core</td>
  <td rowspan="6">Hard interrupt exit</td>
  <td rowspan="6">Completes the hard-interrupt invocation after <code>stmmac_interrupt()</code> returns. The IRQ core leaves hard-IRQ context with the <code>NET_RX</code> softirq pending. It may dispatch that softirq immediately in the interrupt-exit tail or leave it for later processing by <code>ksoftirqd</code>. It does not re-enable <code>RIE</code>.</td>
  <td colspan="2">Hard-IRQ context is active; RX NAPI is scheduled.</td>
  <td colspan="2">Hard-IRQ context is inactive; the <code>NET_RX</code> softirq is pending, and RX NAPI is eligible to run.</td>
</tr>
<tr>
  <td><code>RI=0</code></td>
  <td><code>RIE=0</code></td>
  <td><code>RI=0</code></td>
  <td><code>RIE=0</code></td>
</tr>
<tr>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
</tr>
<tr>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=varies</code></td>
  <td><code>D=d</code></td>
  <td><code>OWN=varies</code></td>
  <td><code>D=d</code></td>
</tr>

<tr>
  <td rowspan="6">7</td>
  <td rowspan="6">RX NAPI</td>
  <td rowspan="6">NAPI softirq</td>
  <td rowspan="6">The NAPI subsystem invokes <code>stmmac_napi_poll_rx()</code>, which calls <code>stmmac_rx()</code> to process consecutive CPU-owned descriptors. It advances its receive cursor and accumulates the value that will become <code>work_done</code>.</td>
  <td colspan="2">Hard-IRQ context is inactive; RX NAPI is running with completed descriptors available.</td>
  <td colspan="2">The receive cursor has advanced, and processed descriptors await refill.</td>
</tr>
<tr>
  <td><code>RI=0</code></td>
  <td><code>RIE=0</code></td>
  <td><code>RI=0</code></td>
  <td><code>RIE=0</code></td>
</tr>
<tr>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
</tr>
<tr>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=0</code></td>
  <td><code>D=d</code></td>
  <td><code>OWN=0</code></td>
  <td><code>D=d</code></td>
</tr>

<tr>
  <td rowspan="6">8</td>
  <td rowspan="6">RX NAPI</td>
  <td rowspan="6">NAPI softirq</td>
  <td rowspan="6"><code>stmmac_rx()</code> calls <code>stmmac_rx_status()</code> for the next descriptor, finds <code>OWN=1</code>, and ends the receive scan. This observation says only that the descriptor was DMA-owned when NAPI inspected it.</td>
  <td colspan="2">RX NAPI is running and is about to inspect the next descriptor.</td>
  <td colspan="2">The final scan has finished; the next descriptor was observed as DMA-owned, and <code>work_done&lt;budget</code> is possible.</td>
</tr>
<tr>
  <td><code>RI=0</code></td>
  <td><code>RIE=0</code></td>
  <td><code>RI=0</code></td>
  <td><code>RIE=0</code></td>
</tr>
<tr>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
</tr>
<tr>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=1</code></td>
  <td><code>D=d</code></td>
  <td><code>OWN=1</code></td>
  <td><code>D=d</code></td>
</tr>

<tr>
  <td rowspan="6">9</td>
  <td rowspan="6">RX NAPI</td>
  <td rowspan="6">NAPI softirq</td>
  <td rowspan="6"><code>stmmac_rx()</code> calls <code>stmmac_rx_refill()</code>. Each refill iteration prepares one processed descriptor, performs the DMA write barrier, and calls <code>stmmac_set_rx_owner()</code> to set <code>OWN=1</code> with the current RX interrupt-mitigation policy. After the loop, the function advances <code>dirty_rx</code> and updates the RX tail pointer. It does not restart the receive scan. In this serialized trace, the refill completes before the RX DMA action in step 10.</td>
  <td colspan="2">RX NAPI remains active; processed descriptors are CPU-owned.</td>
  <td colspan="2">Refilled descriptors are exposed to the DMA; <code>dirty_rx</code> and the tail advance, with no further scan in this invocation.</td>
</tr>
<tr>
  <td><code>RI=0</code></td>
  <td><code>RIE=0</code></td>
  <td><code>RI=0</code></td>
  <td><code>RIE=0</code></td>
</tr>
<tr>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
</tr>
<tr>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=0</code></td>
  <td><code>D=d</code></td>
  <td><strong><code>OWN=1</code></strong></td>
  <td><strong><code>D=d+r</code></strong></td>
</tr>

<tr>
  <td rowspan="6">10</td>
  <td rowspan="6">RX DMA</td>
  <td rowspan="6">DMA</td>
  <td rowspan="6">After step 9 completes, consumes descriptors while RX NAPI remains active and <code>RIE=0</code>, up to and including the last completion that asserts <code>RI</code> under the active RX interrupt-mitigation policy. That completion changes its descriptor to <code>OWN=0</code> and leaves <code>RI</code> pending. The DMA still owns <code>u&gt;0</code> descriptors, whose later completions do not assert <code>RI</code> during the modeled interval.</td>
  <td colspan="2">The refill is complete; RX NAPI remains active, and <code>d+r</code> descriptors are available to the DMA.</td>
  <td colspan="2">No RX interrupt is serviced; <code>RI</code> is pending, and <code>u</code> DMA-owned descriptors remain.</td>
</tr>
<tr>
  <td><code>RI=0</code></td>
  <td><code>RIE=0</code></td>
  <td><strong><code>RI=1</code></strong></td>
  <td><code>RIE=0</code></td>
</tr>
<tr>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
</tr>
<tr>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=1</code></td>
  <td><code>D=d+r</code></td>
  <td><strong><code>OWN=mixed</code></strong></td>
  <td><strong><code>D=u</code></strong></td>
</tr>

<tr>
  <td rowspan="6">11</td>
  <td rowspan="6">TX DMA</td>
  <td rowspan="6">DMA</td>
  <td rowspan="6">Completes transmit work and sets <code>TI</code>. Because <code>TIE=1</code>, the transmit event requests the shared interrupt even though <code>RIE=0</code>.</td>
  <td colspan="2">RX NAPI is running; <code>u</code> DMA-owned RX descriptors remain, and no TX completion is pending.</td>
  <td colspan="2">The shared IRQ is pending; RX NAPI continues running until IRQ entry.</td>
</tr>
<tr>
  <td><code>RI=1</code></td>
  <td><code>RIE=0</code></td>
  <td><code>RI=1</code></td>
  <td><code>RIE=0</code></td>
</tr>
<tr>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
  <td><strong><code>TI=1</code></strong></td>
  <td><code>TIE=1</code></td>
</tr>
<tr>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
  <td><strong><code>NIS=1</code></strong></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=mixed</code></td>
  <td><code>D=u</code></td>
  <td><code>OWN=mixed</code></td>
  <td><code>D=u</code></td>
</tr>

<tr>
  <td rowspan="6">12</td>
  <td rowspan="6">Linux IRQ core</td>
  <td rowspan="6">Hard interrupt entry</td>
  <td rowspan="6">Accepts the TX-triggered shared interrupt, enters hard-IRQ context, and preempts the running NAPI softirq. It dispatches <code>stmmac_interrupt()</code>; the driver begins handling this invocation in step 13.</td>
  <td colspan="2">The shared IRQ is pending; hard-IRQ context is inactive; RX NAPI is running.</td>
  <td colspan="2">Hard-IRQ context is active; RX NAPI is preempted, and <code>stmmac_interrupt()</code> has been dispatched.</td>
</tr>
<tr>
  <td><code>RI=1</code></td>
  <td><code>RIE=0</code></td>
  <td><code>RI=1</code></td>
  <td><code>RIE=0</code></td>
</tr>
<tr>
  <td><code>TI=1</code></td>
  <td><code>TIE=1</code></td>
  <td><code>TI=1</code></td>
  <td><code>TIE=1</code></td>
</tr>
<tr>
  <td><code>NIS=1</code></td>
  <td><code>NIE=1</code></td>
  <td><code>NIS=1</code></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=mixed</code></td>
  <td><code>D=u</code></td>
  <td><code>OWN=mixed</code></td>
  <td><code>D=u</code></td>
</tr>

<tr>
  <td rowspan="6">13</td>
  <td rowspan="6">Main interrupt handler</td>
  <td rowspan="6">Hard interrupt</td>
  <td rowspan="6">Runs <code>stmmac_interrupt()</code> after the IRQ-core dispatch in step 12. After the assumed early-return checks, it first calls <code>stmmac_common_interrupt()</code>, which does not change the tracked state in this sequence, and then calls <code>stmmac_dma_interrupt()</code>. This row ends before <code>dwmac_dma_interrupt()</code> reads CSR5.</td>
  <td colspan="2">Hard-IRQ context is active; RX NAPI is preempted.</td>
  <td colspan="2">The DMA interrupt path has been entered.</td>
</tr>
<tr>
  <td><code>RI=1</code></td>
  <td><code>RIE=0</code></td>
  <td><code>RI=1</code></td>
  <td><code>RIE=0</code></td>
</tr>
<tr>
  <td><code>TI=1</code></td>
  <td><code>TIE=1</code></td>
  <td><code>TI=1</code></td>
  <td><code>TIE=1</code></td>
</tr>
<tr>
  <td><code>NIS=1</code></td>
  <td><code>NIE=1</code></td>
  <td><code>NIS=1</code></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=mixed</code></td>
  <td><code>D=u</code></td>
  <td><code>OWN=mixed</code></td>
  <td><code>D=u</code></td>
</tr>

<tr>
  <td rowspan="6">14</td>
  <td rowspan="6">Shared DMA dispatch</td>
  <td rowspan="6">Hard interrupt</td>
  <td rowspan="6"><code>stmmac_dma_interrupt()</code> calls <code>stmmac_napi_check()</code> with <code>DMA_DIR_RXTX</code>. In turn, <code>stmmac_napi_check()</code> calls <code>stmmac_dma_interrupt_status()</code>, requesting combined RX and TX handling rather than direction-specific filtering. <code>dwmac_dma_interrupt()</code> performs the CSR5 inspection in step 15.</td>
  <td colspan="2">The shared DMA path is active.</td>
  <td colspan="2">The combined-status handler has been invoked.</td>
</tr>
<tr>
  <td><code>RI=1</code></td>
  <td><code>RIE=0</code></td>
  <td><code>RI=1</code></td>
  <td><code>RIE=0</code></td>
</tr>
<tr>
  <td><code>TI=1</code></td>
  <td><code>TIE=1</code></td>
  <td><code>TI=1</code></td>
  <td><code>TIE=1</code></td>
</tr>
<tr>
  <td><code>NIS=1</code></td>
  <td><code>NIE=1</code></td>
  <td><code>NIS=1</code></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=mixed</code></td>
  <td><code>D=u</code></td>
  <td><code>OWN=mixed</code></td>
  <td><code>D=u</code></td>
</tr>

<tr>
  <td rowspan="6">15</td>
  <td rowspan="6">Legacy DMA interrupt handler</td>
  <td rowspan="6">Hard interrupt</td>
  <td rowspan="6"><code>dwmac_dma_interrupt()</code> reads CSR5 and obtains a local status containing <code>RI</code>, <code>TI</code>, and <code>NIS</code>. It then reads CSR7 and observes that <code>RIE=0</code>.</td>
  <td colspan="2">The handler is about to inspect the combined interrupt state; <code>u</code> DMA-owned RX descriptors remain.</td>
  <td colspan="2">The local status and enable snapshots have been captured; hardware state is unchanged.</td>
</tr>
<tr>
  <td><code>RI=1</code></td>
  <td><code>RIE=0</code></td>
  <td><code>RI=1</code></td>
  <td><code>RIE=0</code></td>
</tr>
<tr>
  <td><code>TI=1</code></td>
  <td><code>TIE=1</code></td>
  <td><code>TI=1</code></td>
  <td><code>TIE=1</code></td>
</tr>
<tr>
  <td><code>NIS=1</code></td>
  <td><code>NIE=1</code></td>
  <td><code>NIS=1</code></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=mixed</code></td>
  <td><code>D=u</code></td>
  <td><code>OWN=mixed</code></td>
  <td><code>D=u</code></td>
</tr>

<tr>
  <td rowspan="6">16</td>
  <td rowspan="6">Legacy DMA interrupt handler</td>
  <td rowspan="6">Hard interrupt</td>
  <td rowspan="6"><code>dwmac_dma_interrupt()</code> declines to add <code>handle_rx</code> because <code>RIE=0</code>. It does add <code>handle_tx</code> because <code>TI=1</code>. The already-running RX NAPI is not asked to perform another receive scan.</td>
  <td colspan="2">RX NAPI is active; the handler is evaluating its local snapshots.</td>
  <td colspan="2">The return status requests TX handling but not RX handling; the acknowledgement value still includes <code>RI</code>.</td>
</tr>
<tr>
  <td><code>RI=1</code></td>
  <td><code>RIE=0</code></td>
  <td><code>RI=1</code></td>
  <td><code>RIE=0</code></td>
</tr>
<tr>
  <td><code>TI=1</code></td>
  <td><code>TIE=1</code></td>
  <td><code>TI=1</code></td>
  <td><code>TIE=1</code></td>
</tr>
<tr>
  <td><code>NIS=1</code></td>
  <td><code>NIE=1</code></td>
  <td><code>NIS=1</code></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=mixed</code></td>
  <td><code>D=u</code></td>
  <td><code>OWN=mixed</code></td>
  <td><code>D=u</code></td>
</tr>

<tr>
  <td rowspan="6">17</td>
  <td rowspan="6">Unfixed legacy DMA interrupt handler</td>
  <td rowspan="6">Hard interrupt</td>
  <td rowspan="6"><code>dwmac_dma_interrupt()</code> writes its local status value to CSR5. Because <code>RI</code> remains in that write-one-to-clear value, the write acknowledges both the enabled <code>TI</code> and the masked <code>RI</code>. The last completion that asserts <code>RI</code> already occurred in step 10; the remaining <code>u</code> descriptors do not assert it when completed during the modeled interval.</td>
  <td colspan="2">The last RX wakeup and the TX completion are pending; <code>u</code> DMA-owned RX descriptors remain.</td>
  <td colspan="2">The last RX wakeup is lost; the RX DMA can continue consuming the remaining descriptors.</td>
</tr>
<tr>
  <td><code>RI=1</code></td>
  <td><code>RIE=0</code></td>
  <td><strong><code>RI=0</code></strong></td>
  <td><code>RIE=0</code></td>
</tr>
<tr>
  <td><code>TI=1</code></td>
  <td><code>TIE=1</code></td>
  <td><strong><code>TI=0</code></strong></td>
  <td><code>TIE=1</code></td>
</tr>
<tr>
  <td><code>NIS=1</code></td>
  <td><code>NIE=1</code></td>
  <td><strong><code>NIS=0</code></strong></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=mixed</code></td>
  <td><code>D=u</code></td>
  <td><code>OWN=mixed</code></td>
  <td><code>D=u</code></td>
</tr>

<tr>
  <td rowspan="6">18</td>
  <td rowspan="6">TX NAPI scheduling path</td>
  <td rowspan="6">Hard interrupt</td>
  <td rowspan="6">After <code>dwmac_dma_interrupt()</code> returns <code>handle_tx</code>, <code>stmmac_napi_check()</code> successfully calls <code>napi_schedule_prep()</code> for the idle TX NAPI instance. It calls <code>stmmac_disable_dma_irq()</code> to clear <code>TIE</code>, then calls <code>__napi_schedule()</code> to schedule TX polling. This happens before <code>stmmac_interrupt()</code> returns.</td>
  <td colspan="2">The DMA status has been acknowledged; TX NAPI is idle.</td>
  <td colspan="2">TX interrupts are masked, and TX NAPI is scheduled.</td>
</tr>
<tr>
  <td><code>RI=0</code></td>
  <td><code>RIE=0</code></td>
  <td><code>RI=0</code></td>
  <td><code>RIE=0</code></td>
</tr>
<tr>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
  <td><code>TI=0</code></td>
  <td><strong><code>TIE=0</code></strong></td>
</tr>
<tr>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=mixed</code></td>
  <td><code>D=u</code></td>
  <td><code>OWN=mixed</code></td>
  <td><code>D=u</code></td>
</tr>

<tr>
  <td rowspan="6">19</td>
  <td rowspan="6">Linux IRQ core</td>
  <td rowspan="6">Hard interrupt exit</td>
  <td rowspan="6">Completes the TX-triggered hard-interrupt invocation after <code>stmmac_interrupt()</code> returns, leaves hard-IRQ context, and resumes the RX NAPI softirq preempted in step 12. It does not change the DMA interrupt registers.</td>
  <td colspan="2">Hard-IRQ context is active; RX NAPI is preempted, and TX NAPI is scheduled.</td>
  <td colspan="2">Hard-IRQ context is inactive; RX NAPI has resumed, and TX NAPI remains scheduled.</td>
</tr>
<tr>
  <td><code>RI=0</code></td>
  <td><code>RIE=0</code></td>
  <td><code>RI=0</code></td>
  <td><code>RIE=0</code></td>
</tr>
<tr>
  <td><code>TI=0</code></td>
  <td><code>TIE=0</code></td>
  <td><code>TI=0</code></td>
  <td><code>TIE=0</code></td>
</tr>
<tr>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=mixed</code></td>
  <td><code>D=u</code></td>
  <td><code>OWN=mixed</code></td>
  <td><code>D=u</code></td>
</tr>

<tr>
  <td rowspan="6">20</td>
  <td rowspan="6">RX NAPI</td>
  <td rowspan="6">NAPI softirq</td>
  <td rowspan="6"><code>stmmac_napi_poll_rx()</code> continues after the resumption in step 19. Because <code>stmmac_rx()</code> returned <code>work_done&lt;budget</code> and <code>napi_complete_done()</code> returns true, it calls <code>stmmac_enable_dma_irq()</code> to re-enable <code>RIE</code>. It does not call <code>stmmac_rx()</code> again before rearming the interrupt.</td>
  <td colspan="2">Hard-IRQ context is inactive; RX NAPI is active, TX NAPI is scheduled, <code>u</code> DMA-owned RX descriptors remain, and no RX wakeup is pending.</td>
  <td colspan="2">RX NAPI is idle; TX NAPI remains scheduled, <code>u</code> DMA-owned RX descriptors remain, and no RX IRQ is pending.</td>
</tr>
<tr>
  <td><code>RI=0</code></td>
  <td><code>RIE=0</code></td>
  <td><code>RI=0</code></td>
  <td><strong><code>RIE=1</code></strong></td>
</tr>
<tr>
  <td><code>TI=0</code></td>
  <td><code>TIE=0</code></td>
  <td><code>TI=0</code></td>
  <td><code>TIE=0</code></td>
</tr>
<tr>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=mixed</code></td>
  <td><code>D=u</code></td>
  <td><code>OWN=mixed</code></td>
  <td><code>D=u</code></td>
</tr>

<tr>
  <td rowspan="6">21</td>
  <td rowspan="6">RX DMA</td>
  <td rowspan="6">DMA</td>
  <td rowspan="6">After RX NAPI re-enables <code>RIE</code> in step 20, consumes the remaining <code>u</code> descriptors. Under the active RX interrupt-mitigation policy, these completions do not assert <code>RI</code>, even though <code>RIE=1</code>. The final completion reduces <code>D</code> to zero. The DMA then attempts to continue, finds no DMA-owned descriptor, and enters receive-process state 4.</td>
  <td colspan="2">RX NAPI is idle; <code>u</code> DMA-owned descriptors remain, and no RX status is pending.</td>
  <td colspan="2">No RX IRQ is pending; the RX DMA is suspended, and every descriptor is CPU-owned.</td>
</tr>
<tr>
  <td><code>RI=0</code></td>
  <td><code>RIE=1</code></td>
  <td><code>RI=0</code></td>
  <td><code>RIE=1</code></td>
</tr>
<tr>
  <td><code>TI=0</code></td>
  <td><code>TIE=0</code></td>
  <td><code>TI=0</code></td>
  <td><code>TIE=0</code></td>
</tr>
<tr>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS!=4</code></td>
  <td><code>SR=1</code></td>
  <td><strong><code>RS=4</code></strong></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=mixed</code></td>
  <td><code>D=u</code></td>
  <td><strong><code>OWN=0</code></strong></td>
  <td><strong><code>D=0</code></strong></td>
</tr>

<tr>
  <td rowspan="6">22</td>
  <td rowspan="6">TX NAPI</td>
  <td rowspan="6">NAPI softirq</td>
  <td rowspan="6">The NAPI subsystem invokes <code>stmmac_napi_poll_tx()</code>. It processes the completed TX work. In this sequence, <code>work_done&lt;budget</code> and <code>napi_complete_done()</code> succeeds, so it calls <code>stmmac_enable_dma_irq()</code> to re-enable <code>TIE</code>. TX polling does not scan the RX descriptor ring or schedule RX NAPI.</td>
  <td colspan="2">TX NAPI is scheduled; the RX path is already stalled.</td>
  <td colspan="2">TX NAPI is idle and TX interrupts are enabled; the RX path remains stalled.</td>
</tr>
<tr>
  <td><code>RI=0</code></td>
  <td><code>RIE=1</code></td>
  <td><code>RI=0</code></td>
  <td><code>RIE=1</code></td>
</tr>
<tr>
  <td><code>TI=0</code></td>
  <td><code>TIE=0</code></td>
  <td><code>TI=0</code></td>
  <td><strong><code>TIE=1</code></strong></td>
</tr>
<tr>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=0</code></td>
  <td><code>D=0</code></td>
  <td><code>OWN=0</code></td>
  <td><code>D=0</code></td>
</tr>

<tr>
  <td rowspan="6">23</td>
  <td rowspan="6">RX DMA</td>
  <td rowspan="6">DMA</td>
  <td rowspan="6">Remains suspended because it owns no receive descriptor. Although <code>SR=1</code>, it cannot complete another frame and therefore cannot create a new receive event.</td>
  <td colspan="2">RX NAPI is idle, and the RX DMA is suspended with no available descriptor.</td>
  <td colspan="2">The state is unchanged; the receive path is stalled and cannot recover through the modeled RX IRQ/NAPI path.</td>
</tr>
<tr>
  <td><code>RI=0</code></td>
  <td><code>RIE=1</code></td>
  <td><code>RI=0</code></td>
  <td><code>RIE=1</code></td>
</tr>
<tr>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
  <td><code>TI=0</code></td>
  <td><code>TIE=1</code></td>
</tr>
<tr>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
  <td><code>NIS=0</code></td>
  <td><code>NIE=1</code></td>
</tr>
<tr>
  <td><code>RS=4</code></td>
  <td><code>SR=1</code></td>
  <td><code>RS=4</code></td>
  <td><code>SR=1</code></td>
</tr>
<tr>
  <td><code>OWN=0</code></td>
  <td><code>D=0</code></td>
  <td><code>OWN=0</code></td>
  <td><code>D=0</code></td>
</tr>

</tbody>
</table>

## Effect of patch 0018

Patch 0018 changes step 17. In the modeled sequence, the combined status passed
to `dwmac_dma_interrupt()` contains `NIS=1` and `RI=1`. When the handler also
observes `RIE=0`, it removes `RI` from the local acknowledgement value. The
CSR5 write still acknowledges `NIS` and `TI`, but it leaves `RI` pending:

```text
before patched acknowledgement: RI=1; TI=1; NIS=1; RIE=0; D=u
after patched acknowledgement:  RI=1; TI=0; NIS=0; RIE=0; D=u
```

When RX NAPI performs step 20 and sets `RIE`, the preserved `RI` can invoke the
normal shared interrupt path while `u` descriptors remain DMA-owned.
`dwmac_dma_interrupt()` then observes `RI=1` with `RIE=1` and returns
`handle_rx`; `stmmac_napi_check()` schedules another RX NAPI poll. That poll
can process the CPU-owned descriptors and return them to the DMA, breaking the
terminal state even if the remaining completions do not assert another `RI`.

The preservation branch is nested under the handler's `NIS` test. If an
invocation has `RI=1`, `RIE=0`, and `NIS=0`, the branch is not reached and the
final write can still acknowledge `RI`, unless direction filtering has already
removed `RI` from the write value. This case is outside the demonstrated
sequence because the enabled `TI` supplies `NIS=1` for step 17.

The patch's temporary counters record executions of this masked-`RI`
preservation branch and the subset whose local status also contains `TI`.
