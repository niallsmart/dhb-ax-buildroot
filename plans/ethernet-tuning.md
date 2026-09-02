# Ethernet reliability and performance

The Hi3531 port uses the Synopsys DWMAC1000 core through the local
`hi3531-dwmac` glue.  The reliable path to higher performance is to fix
receive descriptor-exhaustion recovery, retain the verified receive checksum
engine, and establish a new benchmark baseline before changing further DMA or
network-stack settings.

Do not pursue TNK/TOE as part of this work: the vendor runs TNK in BYPASS
mode, mainline `stmmac` has no TNK data-path support, and the ordinary DWMAC
path still has measurable improvements available.

## Experiment design principles

Make each experiment configurable without rebuilding whenever the hardware
and driver lifecycle permit it.  Prefer standard kernel interfaces such as
`ethtool`, sysctls, module parameters and kernel-command-line parameters.  A
setting needed before probe should be a validated driver option that can be
passed at boot; a setting that is safe to change on a running interface
should use an existing runtime interface.  Always record the requested and
effective configuration with the result so an A/B run can be repeated.

Prefer established performance and diagnostic tooling over purpose-built
programs.  Start with `iperf3`, `ping`, `ethtool`, `ss`, `nstat`, `perf`,
ftrace and the kernel's existing statistics and tracepoints.  Scripts may
orchestrate these tools and collect their output.  Add custom instrumentation
only when the standard interfaces cannot answer the question, keep it scoped
to the missing observation, and remove diagnostic-only driver code once the
result is established.

An experiment that can wedge the board has to notice and stop. Abandon the
run at the first failed probe and ensure commands time out promptly, or run
them asynchronously and wait on them. Note that `ssh` ignores `ConnectTimeout`
while ARP resolution hangs.

## Kernel instrumentation configuration

Turn on these diagnostic aids in this branch as needed:

```text
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y
CONFIG_PERF_EVENTS=y
CONFIG_ARM_PMU=y
CONFIG_FTRACE=y
CONFIG_FUNCTION_TRACER=y
CONFIG_FUNCTION_GRAPH_TRACER=y
CONFIG_KPROBES=y
CONFIG_KPROBE_EVENTS=y
CONFIG_DEBUG_FS=y
CONFIG_DYNAMIC_DEBUG=y
```

ARM selects dynamic ftrace for this configuration, so functions that are not
being traced are patched back to no-ops.  Use tracepoints and filtered dynamic
probes before the function or function-graph tracer.  Keep the uncompressed
`vmlinux` on the development host for symbolisation; enable DWARF debug
information only when source-line or local-variable information is needed.

`CONFIG_ARM_PMU` and `CONFIG_PERF_EVENTS` provide the kernel side of `perf`.
The device tree does not describe an ARM PMU, so verify the events exposed by
`perf list` before relying on hardware cycle, instruction or cache counters.
Software events and tracepoints remain useful without a registered hardware
PMU.  Add a PMU node only after its interrupt wiring has been established.

Enable the following only when required to answer specific questions:

- `CONFIG_IRQ_TIME_ACCOUNTING=y` for finer hardirq and softirq CPU accounting;
  it adds a timestamp read at interrupt-state transitions.
- `CONFIG_SCHEDSTATS=y`, `CONFIG_SCHED_TRACER=y` and
  `CONFIG_IRQSOFF_TRACER=y` when distinguishing scheduling delay from long
  interrupt-disabled sections.
- `CONFIG_STMMAC_SELFTESTS=y` for the standard `ethtool -t` correctness tests.
- `CONFIG_NET_DROP_MONITOR=m` when ordinary interface, protocol and qdisc
  counters do not identify where the stack drops packets.
- `CONFIG_PAGE_POOL_STATS=y` when testing page allocation and recycling; its
  counters add work to the allocation and recycle paths.
- `CONFIG_DMA_API_DEBUG=y` or `CONFIG_DEBUG_NET=y` only for a suspected API or
  invariant violation, never for throughput measurements.

Do not enable lockdep, KASAN, UBSAN, KFENCE, debug page allocation or similar
heavy correctness instrumentation for performance runs.  Do not compare
throughput between different kernel configurations and attribute the result
to an Ethernet setting.

The kernel options only expose the interfaces.  Include matching standard
userspace tools such as `perf`, `trace-cmd` and, when selected, `dropwatch` in
the diagnostic userspace.

## 1. Backport the receive descriptor-exhaustion fix

Backport upstream commit `45d100ee0d6e` ("net: stmmac: dwmac: Disable
flushing frames on Rx Buffer Unavailable") to the Linux 6.18 patch queue:

<https://git.kernel.org/pub/scm/linux/kernel/git/netdev/net-next.git/commit/?id=45d100ee0d6e8b4b4ba6c48f54decd62f875cf70>

The complete fix has two required parts:

1. Set `DMA_CONTROL_DFF` whenever DWMAC1000 receive store-and-forward is
   selected.  When no descriptor is available, the frame then waits in the
   receive FIFO instead of being flushed and desynchronising the FIFO from the
   DMA.
2. Write receive poll demand after returning descriptors to DMA ownership.
   With DFF set, descriptor exhaustion suspends the receive process, and poll
   demand resumes it after refill.

Use the upstream implementation directly.  The backport can be removed when
the port moves to Linux 6.19 or later.

Keep the existing three-channel DMA reset at probe.  It is needed to clear DMA
state inherited across a warm boot independently of the receive wedge.

## 2. Preserve a regression test

The regression test must force descriptor exhaustion, with a small receive
ring under sustained inbound traffic.  Ordinary traffic that never runs the
ring dry does not test the repaired path.  Forcing it is required; observing
each occurrence is not.

Run the sender on the macOS host because a receive failure also kills
SSH to the board.  Exercise:

- four inbound TCP streams with a 64- or 256-entry receive ring;
- repeated 30-45 second runs followed by a longer soak;
- small-packet UDP and full-MTU TCP;
- simultaneous transmit and receive traffic;
- ping latency during sustained receive load;
- interface down/up and link flap; and
- CSR6 bit 24 after each interface reopen.

`rx_buf_unav_irq` cannot report exhaustion.  `dwmac1000_dma.c` writes
`DMA_INTR_DEFAULT_MASK` to CSR7, which carries NIE, RIE, TIE, AIE, FBE and
UNE and leaves RUE masked; the board reads back `0x0001A061`.
`dwmac_dma_interrupt` increments the counter inside the abnormal-interrupt
summary, and the summary bit is the OR of the enabled
abnormal sources, so a Receive Buffer Unavailable event sets CSR5 bit 7,
raises no interrupt and leaves the counter at zero however often the ring runs
dry.

The test does not have to observe exhaustion to be valid.  A ring that is not
refilled suspends the DMA, and a suspended receive path takes the board off
the network within seconds, so a run that carries its traffic through to the
end has demonstrated the repair by completing.

`tools/ethernet-rx-ring-watch.c` polls the receive-process state in CSR5 and
reports entries into state 4 and the time spent there, which no standard
interface exposes.  Use it when the question is how often or how long the
ring runs dry, not as a precondition for the regression test.  Unmasking RUE
would make the counter real, but it adds an interrupt per exhaustion event to
the path under test and so cannot be carried into the throughput baseline.

Record transferred bytes, throughput, packet rate, ring size, CPU use,
`NET_RX`, interrupt counts, retransmits, drops, checksum errors, CSR5 and the
`rx_buf_unav_irq`/`rx_process_stopped_irq` counters.

Descriptor exhaustion, an RU event, or a temporary receive state 4 is not a
failure.  The test passes when every case completes: traffic continues, the
board stays reachable, the interface reopens, and the error counters remain
clean.

Use `ethtool -G` for ring-size experiments if the operation is verified safe
on the port.  Otherwise provide a validated boot-time driver option and test
runtime resizing independently before advertising it as supported.

## 3. Retain and validate Type-2 receive checksum offload

The glue supplies `STMMAC_RX_COE_TYPE2` because CSR58 advertises the engine in
the measured DMA channel 0 and channel 1 windows, the IPC bit is writable, and
the vendor uses the same descriptor result.  At 30,000 packets per second it
reduced `NET_RX` from 71% to 36% of one CPU, approximately 24 to 12 microseconds
per packet.

Keep receive checksum offload enabled and add a negative correctness test.
Inject deliberately corrupted IPv4 header, TCP, and UDP checksums and verify
that the receiving stack rejects them.  Capture the normal cases as well:

- IPv4 TCP and UDP;
- IPv6 TCP and UDP;
- odd and even payload lengths;
- fragmented IPv4 where supported by the engine; and
- checksum and receive-error counters before and after each run.

`../dhb-ax-guide/doc/06-ethernet.md` records the CSR58 reads and the hardware
validation of Type-2 receive checksum offload.

## 4. Establish a corrected performance baseline

Establish the performance baseline with the upstream receive fix and Type-2
receive checksum offload enabled.

Measure these independent variables:

| Variable | Values |
| --- | --- |
| RX ring | 256, 512, 1024 descriptors |
| RX interrupt coalescing | approximately 27, 64, 128 and 264 microseconds |
| GRO | on, off |
| TCP flows | one and four, each direction |
| UDP | small-packet rate and full-MTU bandwidth |
| Direction | receive, transmit, simultaneous receive/transmit |

For each run record throughput, packets per second, per-CPU utilization,
`NET_RX`, Ethernet interrupt rate, TCP retransmits, drops, checksum and DMA
errors, Receive Buffer Unavailable events, and ping latency under load.  Use
repeated runs and report the median and spread rather than the best result.

Choose the smallest receive ring whose throughput and reliability match the
larger sizes.  A 1024-entry ring can absorb a longer scheduling delay, but it
must not remain merely as a workaround for a fatal descriptor-exhaustion
path.

Test RPS only if profiling shows receive work saturating a CPU, and keep it as
an independent variable because redirection adds an IPI and cache-line
migration.  If the baseline exposes unexplained receive latency, use `perf`
and filtered kernel tracing to locate it before adding driver instrumentation.

## 5. Evaluate transmit checksum offload separately

CSR58 advertises transmit checksum insertion and the vendor pairs it with TX
store-and-forward.  It may reduce transmit CPU cost, but it must not be
enabled as a simple platform-data bit.

`stmmac_dma_operation_mode()` selects TX store-and-forward from the static
`plat->tx_coe` capability.  Disabling TX checksum offload later with
`ethtool -K` does not switch the DMA back to threshold mode.  That can create
the known unsafe pairing of TX store-and-forward with checksum insertion
disabled.

Before advertising TX checksum offload:

1. Make the TX DMA mode follow the active checksum feature, or make the safe
   TSF-plus-COE pairing non-toggleable.
2. Capture packets on the peer, not the transmitting board, and validate the
   generated IPv4, IPv6, TCP and UDP checksums.
3. Repeat the large-ping size walk, NFS write, TCP, UDP and bidirectional
   tests that expose a transmit burst.
4. Test checksum toggles, interface reopen and link flap.
5. Compare CPU time, throughput, latency and error counters with software
   checksumming.

Merge TX checksum support only if the performance gain justifies the extra
mode-management and regression surface.

## Deferred features

Do not include these in the first tuning series:

- **TNK/TOE:** vendor default is BYPASS and mainline has no implementation.
- **TSO:** unavailable on this DWMAC generation through mainline `stmmac`.
- **Jumbo frames:** unvalidated and the maintained port is capped at MTU
  1500.
- **Additional DMA channels:** their presence does not establish usable
  ordinary multiqueue operation on the shared Hi3531 GMAC/TNK integration.
- **PBL changes:** the maintained value is already consistent with the
  measured vendor setup; no evidence identifies it as a bottleneck.
- **EEE:** power saving is not a throughput feature and should remain outside
  the reliability baseline.

## Delivery order

Keep each result in a separate logical change:

1. Backport the upstream DFF and receive-refill poll-demand fix.
2. Automate the standard-tool receive regression test and record target
   results.
3. Update the maintained README and the official Ethernet guide.
4. Retune ring size, interrupt coalescing and GRO from the corrected baseline.
5. Investigate TX checksum offload as an independent experimental series.

The first three steps establish a reliable maintained port.  Performance
tuning follows from that stable baseline rather than being used to avoid a
hardware state the driver must recover from correctly.

## Log

Newest entry first.

### 2026-09-02

Step 1 committed.  Step 2 built, not yet green.  Steps 3 to 5 untouched.

- The receive path corrupts kernel memory.  A run of four-stream inbound TCP
  at a 64-entry ring, followed by ten interface reopens, ended in
  `Unable to handle kernel paging request at virtual address 25242322` in
  `ext4_read_folio`, preceded by `BUG: Bad rss-counter state`.  The faulting
  registers held `0x25242322` and `0x19181717`, ascending byte sequences
  rather than pointers, which is what a data payload written over a kernel
  structure looks like.  Treat every other symptom below as downstream of
  this until it is ruled out.
- The first suspect is the ring-size patch, which sets
  `dma_conf.dma_rx_size` at probe.  A descriptor array or buffer sized from a
  different value than the DMA is programmed with would write past the end of
  the ring.  Test the stock 512-entry ring with no `stmmac.rx_ring_size`
  argument and see whether the corruption goes away.
- Exhaustion recovery works.  Thirty seconds of four-stream inbound TCP at a
  64-entry ring, sampled by busy-polling at about 8 million reads a second:
  20100 entries into receive state 4, 16.6 s suspended of 40 s, longest 26 ms,
  `rps_seen` 0, no error or drop counter moved.
- Five seconds of the same traffic at the 512-entry default, sampled every
  200 us: 105 entries, 2.0 s suspended of 13 s, longest 100 ms, `rps_seen` 0.
  Small-packet UDP produced none.
- Entry counts and the longest episode only mean something against the
  interval they were sampled at: an interval longer than an episode misses it
  entirely and merges neighbours, which is why the counts above differ by two
  orders of magnitude.  Suspended residency as a fraction of the window is the
  figure that compares across intervals.  Every result carries its interval in
  the poller's `# interval_us` line.
- `rx_buf_unav_irq` stayed 0 through that run while the poller saw `ru_seen=1`.
  CSR7 reads `0x0001A061`, so RUE is masked.
- The board also wedges outright: CSR5 `0x00680404`, receive state 4, eth0
  interrupts frozen, `dmesg` clean.  Writing poll demand to `0x101c1108` gave
  `0x00680484` and state 4 again, so the DMA was healthy and the driver was
  not refilling.  Empty ring suspends the DMA, no frame raises no interrupt,
  no interrupt schedules the refill.  Upstream's poll demand cannot break
  this: it sits inside the refill.
- `ip link set eth0 down`/`up` clears the wedge, once, on the first attempt in
  every case so far.
- Four runs of traffic plus ten reopens on one boot: runs 1 and 2 clean before
  the poller had been copied to the board, run 3 wedged with the poller
  running, run 4 oopsed after it.  Corruption surfaces when the damaged page
  is next touched, so run 4 does not clear the poller.  Nothing went wrong in
  that boot until it ran.
- To separate them, run the repro two or three times from a fresh boot with
  the poller never started.
- Read CSR5 before calling the board wedged.  State 4 with frozen interrupts is
  the wedge; state 7 with interrupts advancing is a host path problem.
- Throughput, four inbound TCP streams at a 64-entry ring: 706 to 712 Mbit/s
  clean, 534 Mbit/s with the poller, which holds a CPU at 5 to 8 million reads
  per second.
- `STMMAC_RX_COE_TYPE2` has been set since 2026-08-28, including through the
  runs that did not wedge.  A/B it once the corruption is understood.
