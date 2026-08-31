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

## Kernel instrumentation configuration

The maintained and minimal kernel configurations enable `stmmac` but disable
perf events, ftrace, kprobes, dynamic debug, debugfs, page-pool statistics and
the stmmac self-tests.  Build a separate diagnostic configuration fragment so
these facilities can be selected without changing the production baseline.
Run `olddefconfig` and retain the resolved configuration with every result.

The first diagnostic layer should provide standard profiling and tracing:

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

Enable the following only for the question each one answers:

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
to an Ethernet setting.  Use the same diagnostic kernel for both sides of an
A/B test, disable active tracing while collecting the throughput baseline,
and measure the diagnostic configuration once against the production kernel
to quantify its own overhead.

The kernel options only expose the interfaces.  Include matching standard
userspace tools such as `perf`, `trace-cmd` and, when selected, `dropwatch` in
the diagnostic userspace.  Use `pktgen` on the load-generator host when a
kernel packet source is required rather than spending target CPU on traffic
generation.

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

The regression test must force descriptor exhaustion.  Ordinary traffic that
never raises Receive Buffer Unavailable does not test the repaired path.

Run the sender on the development host because a receive failure also kills
SSH to the board.  Exercise:

- four inbound TCP streams with a 64- or 256-entry receive ring;
- repeated 30-45 second runs followed by a longer soak;
- small-packet UDP and full-MTU TCP;
- simultaneous transmit and receive traffic;
- ping latency during sustained receive load;
- interface down/up, link flap, and warm reboot; and
- CSR6 bit 24 after each interface reopen.

Record transferred bytes, throughput, packet rate, ring size, CPU use,
`NET_RX`, interrupt counts, retransmits, drops, checksum errors, CSR5 and the
`rx_buf_unav_irq`/`rx_process_stopped_irq` counters.

Descriptor exhaustion, an RU interrupt, or a temporary receive state 4 is not
a failure.  The test passes when the driver refills the ring, poll demand
resumes the DMA, traffic continues, and error counters remain clean.

Use `ethtool -G` for ring-size experiments if the operation is verified safe
on the port.  Otherwise provide a validated boot-time driver option and test
runtime resizing independently before advertising it as supported.

## 3. Retain and validate Type-2 receive checksum offload

The glue supplies `STMMAC_RX_COE_TYPE2` because CSR58 reports the engine at
both MAC instances, the IPC bit is writable, and the vendor uses the same
descriptor result.  At 30,000 packets per second it reduced `NET_RX` from 71%
to 36% of one CPU, approximately 24 to 12 microseconds per packet.

Keep receive checksum offload enabled and add a negative correctness test.
Inject deliberately corrupted IPv4 header, TCP, and UDP checksums and verify
that the receiving stack rejects them.  Capture the normal cases as well:

- IPv4 TCP and UDP;
- IPv6 TCP and UDP;
- odd and even payload lengths;
- fragmented IPv4 where supported by the engine; and
- checksum and receive-error counters before and after each run.

Update `../dhb-ax-guide/doc/06-ethernet.md`.  Its capability section still
says that CSR58 is unusable and checksum offload is disabled, which
contradicts the maintained glue and target measurements.

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

CSR58 reports transmit checksum insertion and the vendor pairs it with TX
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
4. Test checksum toggles, interface reopen, link flap and warm reboot.
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
