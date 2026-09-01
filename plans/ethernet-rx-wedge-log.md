# Hi3531 RX wedge — record

Supporting record for [ethernet-rx-wedge.md](ethernet-rx-wedge.md).  Verified
on kernel 6.18.42, Debian initramfs, GMAC1 on DMA channel 1, against the
vendor Linux 3.0.8 with Hisilicon `stmmac` build 201206191703.

The cause was CSR6 bit 24, DFF.  The dead ends below are kept because they
are what the search actually cost, and because several of them stay true:
poll demand is necessary alongside DFF without being the cause of anything.

## Dead ends

Do not spend time on these again.

- **Unmasking RU on the vendor to make its counters record exhaustion.**  Two
  independent reasons it cannot work.  `dwmac_enable_dma_irq()` writes a
  constant mask from the NAPI completion path, so any received packet reverts
  the change within milliseconds; and `dwmac_dma_interrupt()` nests the RU and
  RPS counters inside its AIS test, and AIS is the OR of only those abnormal
  causes enabled in CSR7, so with RU masked the counter cannot move whatever
  CSR7 held at the time.  Sample the CSR5 receive-state field instead.
- **Polling for the RU status bit.**  It is an edge the handler clears on its
  next write-back, so a sampler races the acknowledgement.  The state field at
  CSR5 bits 19:17 persists for as long as the stall does.
- **Single-flow UDP as a reproducer.**  Does not stress the descriptor path.
  At 400 Mbit/s offered the received rate pins near 230 Mbit/s on both kernels,
  with the excess dropped upstream of the DMA and the ring almost entirely
  DMA-owned.
- **Smaller frames to provoke the wedge.**  They push it away.  Received pps
  saturates near 38k whatever the frame size, so shrinking frames only lowers
  the byte rate and the ring drains less.
- **A bigger ring as the fix.**  Mitigation only.  1024 is rarer, not immune.
- **Threaded NAPI.**  Worse: nine wedges in 30 s as `SCHED_OTHER` and ten at
  `SCHED_FIFO` 50, against three for the default softirq poll.
- **Raising the NAPI budget.**  Cycle time scales with batch size, so the
  descriptor return rate is roughly unchanged.
- **Refilling inside the receive loop.**  `stmmac_rx_refill()` already runs
  before `stmmac_rx()` returns, so a poll's descriptors are back with the DMA
  before the slow stretch starts.  There is nothing to move.  What upstream
  omits on this DMA is the notification rather than the refill: the tail
  pointer register it publishes to belongs to DWMAC4 and later, so
  `stmmac_set_rx_tail_ptr()` is a no-op here, and `DMA_RCV_POLL_DEMAND` is
  declared in `dwmac_dma.h` and written nowhere in the driver.  Supplying that
  notification is patch 0017, and it does not help.
- **Closing and reopening the interface to recover.**  Works, but leaks a
  poolful of RX pages per cycle — `dev_close` cannot reclaim pages the wedged
  DMA still holds — and the board stalls in `stmmac_napi_poll_rx` after a few
  recoveries, needing `sysrq-b`.  Superseded by the in-place rebuild.
- **`net:netif_receive_skb_list_entry` to see the GRO flush.**  Wrong function:
  that tracepoint is in the external API, and the flush calls
  `netif_receive_skb_list_internal()` directly.  Filtered function tracing on
  the internal name works and is cheap.
- **Receive poll demand, in every form tried.**  Written by hand to CSR2 on a
  wedged channel with the vendor's own write value, with inbound traffic
  present, and with all 256 descriptors confirmed DMA-owned in physical
  memory: CSR5 and CSR19 do not move.  Issued from a 50 ms timer mirroring the
  vendor's `stmmac_poll_func()`, with the outer cache enabled and at full link
  speed: the wedge arrives on schedule anyway.  Issued from the refill path
  itself, where the vendor issues it, preceded by the vendor's own
  `isb(); dsb(); dmb()` barrier: 54 poll demands during the failing run, and
  the wedge arrives anyway.  The counter is what makes that last reading
  usable — without it a null result cannot be told from a call site that never
  fired.
- **Mirroring the vendor's poll timer as a fix.**  Patch 0016 reproduces it
  faithfully and changes nothing.  Whatever keeps the vendor's receive process
  alive, this is not it.
- **Mirroring the vendor's refill-path kick as a fix.**  Patch 0017 adds
  `enable_dma_receive` to `stmmac_dma_ops`, calls it at the end of
  `stmmac_rx_refill()`, and reproduces the vendor's barrier sequence ahead of
  the write.  Confirmed firing by its own counter, 54 times in a run that
  wedged at 3.75 MB.  This was the last untested placement of a poll demand.
  A dead end as a fix on its own, but not discardable: with DFF set the DMA
  suspends instead of flushing and needs exactly this to resume, which is why
  upstream's fix carries both halves.
- **16-byte descriptors with ATDS clear.**  Patch 0018.  Wedges exactly as
  32-byte descriptors do, at 3.12 MB against 3.75 MB, with CSR19 in bounds of
  a ring 4096 bytes long.  It also brought CSR0 to functional parity with the
  vendor — `0x00A01000` against `0x00201000`, differing only in USP, which
  chooses between an RPBL and a PBL that both hold 16 — so CSR0 accounts for
  nothing.
- **Disabling the L2 cache in the device tree.**  Reproduced the wedge
  unchanged, and re-confirms by a second route what `L2_CTRL` already showed.
  It also costs an order of magnitude of throughput, which changes the shape
  of a run without changing its outcome.
- **Ruled out as contributors:** L2 cache (wedge reproduced with `L2_CTRL` both
  ways, `L2_RINT` clear, and again with the device-tree node disabled), RPS,
  CPU frequency scaling (no `cpufreq` driver), TCP buffer sizing, scheduling
  latency (`time_squeeze` zero on both CPUs).

## Traps

- **`ethtool -G eth0 rx <n>` wedges receive by a second, unrelated route.**
  CSR19 walks addresses outside the ring CSR3 points at.  Select the ring at
  probe instead.  This failure is itself unexplained and may share a cause
  with the main wedge.
- **Unmasking RU without re-masking it at the wedge storms the board.**  The
  condition survives the interrupt being acknowledged, so the channel
  re-interrupts as fast as the handler clears it.  0016 masks both sources
  when it asks for the reset; `hi3531_dma_init_chan()` re-arms on reopen.
- **The in-place reset must stop in the order `__stmmac_release()` uses:**
  `napi_disable`, then the transmit timers, then `netif_tx_disable`, with
  `priv->lock` held only across the rebuild.  Taking the transmit queue first
  hangs the board between `rtnl_lock()` and `stmmac_hw_setup()`, with a
  console that stops answering even a serial break.
- **The three-channel reset clears GMAC1's control register.**  A 1000/full
  interface reads `0x0061080c` there and zero afterwards.  Opening the
  interface does not care because phylink reprograms on link-up, but an
  in-place reset never gets that call.
- **`GMAC_CORE_INIT` asserts port select unconditionally, selecting MII.**
  Restoring the link bits before `stmmac_core_init()` is not enough — the
  register came back `0x0061880c` and receive stayed dead against a gigabit
  link.  0016 overrides `core_init` to put the three bits back afterwards.
- **`rx_desc_low_water` resets on read** and `stmmac_reset_rx_queue()`
  reinitialises it, so a run that wedges reports only the interval since its
  last recovery.
- **DMA register addresses are the channel base plus the CSR index times
  four.**  Channel 1 starts at `0x101c1100`, so CSR2 receive poll demand is
  `0x101c1108` and CSR1 transmit poll demand is `0x101c1104`.  A poll-demand
  test written to `0x101c1104` reports a negative result about transmit.
  Confirm a derived address against `dwmac_dma.h` before writing to it.
- **State 7 in CSR5 bits 19:17 is not a fault.**  A healthy idle interface on
  this integration reads `0x006e0000`.  State 4 is the wedge; the vendor's own
  `stmmac_poll_func()` mask of `0x680000` matches state 7 as well, which is
  why its timer fires more or less continuously.
- **Bring-up intermittently hangs at `eth0: Register MEM_TYPE_PAGE_POOL RxQ-0`**
  and needs a power cycle.  Seen at least twice, not tied to a ring size or to
  any one change.

## Scope of the recovery matrix

Poll demand, SR toggling, MAC receiver disable, channel software reset and
`ip link` down/up were each applied **by hand over serial, once, to a channel
already wedged for seconds**.  No driver has ever issued a receive poll
demand, on the refill path or anywhere else.  The matrix shows those
mechanisms do not rescue a settled wedge; it does not show that a prompt poll
demand fails to prevent one.

## Vendor access

- The vendor root is yaffs2 on NAND, so `/tmp` is NAND-backed and files
  written there persist.  `/nfsdir` is the only tmpfs; put run output there.
- Reloading the vendor module needs its boot arguments:
  `insmod /hitoe/stmmac.ko macsorts=1 phyid0=2 phyid1=1 [dma_rxsize=<n>]`.
  Without `macsorts=1`, eth0 binds GMAC0 on DMA channel 0, comes up with no
  valid MAC and receives nothing.  The reloaded driver never has a MAC
  address, so set it before the address:

      ifconfig eth0 down
      /tmp/vendor-module-unload stmmac
      insmod /hitoe/stmmac.ko macsorts=1 phyid0=2 phyid1=1 dma_rxsize=<n>
      ifconfig eth0 hw ether 00:18:AE:3C:A2:49
      ifconfig eth0 192.168.4.77 netmask 255.255.252.0 up
      route add default gw 192.168.4.1

  Omit `dma_rxsize` to roll back to the stock 256.  Reloading drops the
  network, so drive it from UART.
- `/tmp/rx-ring-watch <entries> 16 1 <seconds>` samples CSR5 to a CSV.  It
  busy-polls a CPU, so it perturbs the workload — a positive state-4
  observation survives that, a throughput number does not.

## Building for the vendor system

Anything loaded into vendor Linux has to match `3.0.8 SMP mod_unload ARMv7`
vermagic, which means building against the vendor kernel tree with the vendor
toolchain.  Both are present:

- Kernel tree and driver source:
  `../dhb-ax-guide/Hi3531_V100R001C01SPC0D1/01.software/board/Hi3531_SDK_V1.0.D.1/osdrv/kernel/linux-3.0.y`,
  configured with `godnet_defconfig`.  Note the shipped `stmmac.ko` is a later
  build than this source — it prints version 201206191703 and carries
  `macsorts`, `phyid0` and `phyid1` parameters the tree does not have.
- Toolchain tarballs under `osdrv/toolchain/`: `arm-hisiv100-linux`,
  `arm-hisiv100nptl-linux`, `arm-hisiv200-linux`.  The sidecar was built with
  GCC 4.4.1, which is `arm-hisiv100-linux` — unverified, check `cross.install`
  if it matters.
- Docker image `vendor-sdk-probe:tools` is the build environment.  It is a
  `linux/386` Debian, because the vendor toolchain binaries are 32-bit x86, so
  it needs `--platform linux/386` on an arm64 host.  It carries no ARM cross
  compiler itself and has an empty `/probe` mount point, so the toolchain is
  mounted in from the guide rather than baked in.  The exact run line was not
  recorded and needs reconstructing.

The vendor BusyBox `rmmod` cannot run because `/lib/modules` is absent; use
the `/tmp/vendor-module-unload` helper, which calls the unload syscall
directly.

## Vendor configuration

Channel 1, captured 2026-08-29:

    CSR0  bus mode  0x00201000   PBL 16, RPBL 16, ATDS clear, FB off
    CSR6  op mode   0x03202002   RSF, TSF, DFF on; thresholds unused
    CSR7  mask      0x0001A061   RU and RPS masked; only UNF and FBI enabled
    CSR8  missed    0x00000000
    CSR9  RIWT      0x00000000   no receive watchdog
    CSR10 AXI       0x00110001
    CSR11 status    0x00000000
    CSR22 feature   0x016DEF37   tx_coe and rx_coe_type2 present
    MAC config      0x00000C8C   RE, TE, ACS, IPC on, full duplex, GMII
    flow control    0x00000000   pause off both directions
    RDES1           0x1FFF1FFF   DIC clear, interrupt on every descriptor

ATDS is clear, so the vendor runs 16-byte descriptors despite the driver
logging "Enhanced descriptor structure".

`stmmac_poll_func()`, a 50 ms timer, reads CSR5 for both channels and writes
transmit and receive poll demand where the state field matches `0x680000`.
The RX half of that mask is bit 19, set for states 4 through 7, so it fires
during healthy running too — a periodic kick, not a stall detector.  A second
50 ms timer, `stmmac_check_func()`, counts out-of-order descriptor events.
Neither is upstream `stmmac`.

## Measurements

**Vendor receive state, CSR5 sampled at 1 ms, 45 s four-stream TCP, 55,001
samples.**  No wedge at any ring size; CSR8 zero throughout.

    ring 256   337 Mbit/s   state 4 in  1.3% of samples    310 episodes, longest  6
    ring  32   167 Mbit/s   state 4 in 31.4% of samples   3660 episodes, longest 21

**Vendor throughput against ring size**, 45 s four-stream TCP:

    ring 256   342 Mbit/s   29.1k pps    ~1.8k retransmits    27 irq/s
    ring  64   167 Mbit/s   18.0k pps     84k retransmits   1050 irq/s
    ring  32   137 Mbit/s   14.4k pps     66k retransmits   1857 irq/s

CSR8 is zero in every run, so the loss driving those retransmits is above the
DMA.  At ring 256 `normal_irq_n` rose by 1234 while `rx_pkt_n` rose by 1.31M
— about 1060 packets per interrupt.  NAPI keeps finding work and never
completes, so the vendor polls continuously rather than being interrupt-paced.
Mainline completes constantly at ~2165 polls a second of 13 packets each,
paced by the `rx-usecs 264` coalescing timer.

**Mainline free descriptors, median / minimum / wedges per 30 s.**  Sampled
once a second, full MTU, four streams.

    received      pps     ring 256        ring 512        ring 1024
     96 Mbit/s    7.9k    204 / 194 / 0   459 / 428 / 0   969 / 953 / 0
    190 Mbit/s   15.7k    201 / 175 / 0   454 / 426 / 0   963 / 916 / 0
    283 Mbit/s   23.5k    182 / 102 / 0   450 / 387 / 0   955 / 903 / 0
    370 Mbit/s   30.8k    181 /  70 / 4   431 / 101 / 1   952 / 473 / 0
    unthrottled    33k    177 /   4 / 8   384 /  67 / 3   874 / 533 / 0

The medians barely move: across a 4.4x rise in rate the steady backlog goes
from 52 to 128 descriptors, and at a given rate it is the same at all three
ring sizes.  Arrival rate alone sets the steady depth.  The minima collapse
instead — at 370 Mbit/s on a 512 ring, twenty-eight seconds read 365 to 452
free and one reads 101.  Nothing fills the ring up; something empties it.  The
largest excursion visible is on the 1024 ring: 551 descriptors of backlog
against a median of 72, which at 31k pps is 18 ms in which nothing was handed
back to the DMA.

**Frame size sweep**, ring 512, four streams, 30 s, MTU set on the board:

    MTU 1500   348 Mbit/s   30353 pps   1435 B   low-water  24   wedged at 1.3 s
    MTU 1000   293 Mbit/s   36144 pps   1014 B   low-water  34   no wedge
    MTU  600   192 Mbit/s   39058 pps    614 B   low-water  91   no wedge
    MTU  400   126 Mbit/s   38181 pps    414 B   low-water 162   no wedge

**Receive checksum offload.**  The MAC implements it and the port had it off —
`plat->rx_coe = STMMAC_RX_COE_NONE`, on the stated grounds that CSR58 is
unusable.  It reads `0x016DEF37`, decoding to tx_coe and rx_coe_type2 present,
and setting IPC in `GMAC_CONTROL` sticks.  With `STMMAC_RX_COE_TYPE2` the
NET_RX softirq falls from 71% of a CPU to 36% at 30k pps, about 24 us per
packet to 12, with TCP `InCsumErrors` at zero.  Wedges per 30 s:

    ring 256   400 Mbit/s    4 -> 2
    ring 256   unthrottled   8 -> 5
    ring 512   unthrottled   3 -> 1
    ring 1024  unthrottled   0 -> 0, worst second 142 -> 659 free

A mitigation: 256 and 512 still wedge.

**Where the excursion comes from.**  The receive poll is never starved —
tracing 11,107 NET_RX windows over 10 s, the 33 that exceed 4 ms all have both
CPUs in `swapper` with no eth0 interrupt waiting, so they are the sender
pausing.  `rx_refill_starved` is zero throughout, so the page pool never comes
up short.  The poll interval at the emptiest moment is the ordinary 1.5 to
3 ms.

What the trace does show: the driver poll returns work 64 against a budget of
64, NAPI is therefore not completed, and `net_rx_action` runs 2.9 to 4.0 ms
without another poll before the softirq exits to `ksoftirqd/0`.  The next
driver poll comes 4.8 to 8.4 ms after the previous one.  That stretch is the
batch going up the stack, outside `stmmac_rx()`.  Over 15 s the receive NAPI
polled 32,469 times for 416,332 packets, median 13 per poll, and only 27 polls
reached the full budget — the full-budget poll is what an excursion looks like
from inside, not what causes one.

Each cycle returns 64 descriptors, so cycle time is what matters: at 1.5 ms
that is 42k descriptors per second against 30k arriving; at the 4 to 12 ms of
an excursion it is 5 to 16k, losing about 50 descriptors per cycle.  NET_RX
costs 71% of one CPU at 364 Mbit/s and 30k pps, capping the drain near 42k pps
against a burst arrival rate of 81k pps at line rate.

**In-place recovery.**  0016 rebuilds the DMA around the rings it already has,
so the page pool survives and the link is never dropped.  Six 45 s four-stream
runs at ring 512 took 15 wedges and recovered from all of them, at 463-489
Mbit/s and 38-40k pps, against 319-360 Mbit/s when each recovery cost a PHY
renegotiation.  Three wedges fell inside 105 ms of each other.  No RCU stall,
no page-pool message, memory flat.

**Mainline at the wedge, patches 0015 and 0016, ring 256, four-stream TCP.**
Read through `/dev/mem` with the recovery removed, so the state is as the
hardware left it.

    CSR3   81a80000    ring base, extent 81a80000-81a81fff
    CSR19  81a80640    frozen, inside the ring
    CSR5   00680404    receive state 4, suspended
    CSR8   00000000    no missed frames, no overflow
    CSR11  00000000    no bus error
    OWN    256 / 256   every descriptor DMA-owned in physical memory

**Poll timer against the wedge**, four-stream TCP, ring 256, 45 s.  Runs 2 and
3 are one boot with `rx_poll_ms` toggled at runtime.

    L2   rx_poll_ms   transferred   outcome
    off      50          3.88 MB    wedged, state 4
    on       50          7.50 MB    wedged, state 4
    on        0          5.00 MB    wedged, state 4

Every run wedges on its first RU episode and stays wedged, so the transferred
figure is time to first wedge rather than throughput.  `rx_buf_unav_irq` reads
1 in each, with the interrupt source re-armed every 50 ms — RU asserts on a
failed descriptor fetch, so a channel still retrying would raise it again.

**Refill-path poll demand against the wedge**, four-stream TCP, ring 256, L2
on, 45 s, `rx_poll_ms` 0 throughout so the timer cannot confound it.

    rx_kick_on_refill   kicks issued   transferred   outcome
    (baseline, off)          --           5.00 MB    wedged, state 4
    on, no counter           --           3.50 MB    wedged, state 4
    on, counted              54           3.75 MB    wedged, state 4

Wedge signature `CSR5 006884c4`, unchanged from every earlier run.  The
counted run is the one that matters: 54 poll demands reached the hardware,
each preceded by the vendor's barrier, and the receive process wedged all the
same.  After `ip link` down and up the counter resumes climbing, so the path
is live in steady state and not only under load.  Read the three transferred
figures as time to first wedge on a noisy reproducer, not as throughput —
the spread between them carries no signal.

**DFF against the wedge**, four-stream TCP, ring 256, L2 on, 45 s,
`rx_poll_ms` 0 and `rx_kick_on_refill` on throughout.  All three runs are one
boot with `rx_dff` toggled live and the interface bounced between them.

    rx_dff   CSR6         transferred   receiver   outcome
    Y        0x03002902      3.75 GB    714 Mbit/s  no wedge
    Y        0x03002902      3.71 GB    706 Mbit/s  no wedge
    N        0x02002902      5.12 MB      0         wedged, state 4

The successful runs suspend and recover.  The first logged
`CSR5 006884c4 CSR19 822f2ac0 CSR21 823b6040 GMAC debug 00000137` at t=138 s
— the wedge signature exactly — and went on to 3.75 GB.  CSR7 read
`0x0001A061` afterwards, so RUE and RSE were masked after that one report and
later episodes were not recorded.  Across the pair: CSR8 zero, `rx_errors`
zero, `rx_dropped` 24, 2.78M packets, 4.21 GB.

The failing run's state matches every earlier wedge: CSR5 `0x00680404`,
CSR6 back to `0x02002902`.

**What resumes the channel**, CSR5 sampled at 1 ms for 50 s by
`tools/ethernet-rx-ring-watch.c`, four-stream TCP for 45 s, ring 256, DFF set
throughout, console quiet.  An episode is a run of consecutive samples in
state 4.

    kick  timer   episodes   longest      mean   state 4   received   rate
    off   off            1   43283 ms         -    86.6%     2.3 MB   terminal
    off   50 ms        677      61 ms   30.4 ms    41.2%    2.40 GB   452 Mbit/s
    on    off         4881      83 ms    3.2 ms    31.7%    3.77 GB   719 Mbit/s

The first row is the clearest evidence that a poll demand is needed alongside
DFF: one episode, entered at 6.74 s and still running when the window closed
43 s later.  DFF leaves the channel in a state it can be brought out of, and
with nothing to bring it out the run ends there.

The mean episode lengths say which source is better and why.  The timer's
30.4 ms is half its 50 ms period, which is what periodic polling of a
uniformly distributed suspension gives.  The refill kick's 3.2 ms is bounded
by NAPI refill latency instead, and throughput follows: 719 against
452 Mbit/s.  Either source keeps the interface alive; only the kick keeps it
fast.

Sampling at 1 ms merges or misses episodes shorter than the interval, so the
counts are lower bounds and the percentages estimates.

**Time to the first suspend**, one boot, `rx_kick_on_refill` on, uptime
recorded at run start and taken from the report's dmesg timestamp:

    rx_dff   first suspend   outcome
    Y             6.0 s      recovered, 3.75 GB
    N             4.2 s      terminal, 5.50 MB

Exhaustion arrives at the same point either way.  DFF changes only what
follows it, not how soon or how often the ring empties.  One sample each, and
both figures overstate time into the transfer by the second or two between
starting the server and the client connecting.

**An earlier attempt at the middle row was void.**  It ran with
`ignore_loglevel` on the boot line and the 50 ms timer re-arming RUE and RSE
every tick, so each tick logged a suspend report to a 115200 serial console
synchronously — 547 of them, in the same path that refills descriptors.  It
measured 598 MB and a 1200 ms longest episode.  Quieting the console with
`ignore_loglevel=0` and `dmesg -n 1` moved the same configuration to 2.40 GB
and 61 ms.  Diagnostics that log per episode need the console off the serial
port before anything is read from the run.

**Vendor and mainline CSR6**, channel 1:

    vendor    0x03202002   RSF, DFF, TSF
    mainline  0x02002902   RSF, EFC, RFD
    with 0019 0x03002902   RSF, DFF, EFC, RFD

TSF and the DMA flow control fields still differ and account for nothing
known.

## History

- **2026-08-28** — Fault characterised.  Wedge reproduced with four-stream
  inbound TCP at ring 512, 4 runs out of 4.  Receive state 4 identified, and
  the recovery matrix established that only a three-channel DMA reset clears
  it.  A 10 ms sampler caught the transition and confirmed descriptor
  exhaustion as the trigger.
- **2026-08-28** — Ring raised to 1024 (patch 0014).  Looked like a fix, was
  not: a later run wedged at 1024 too, and the original "RU never set" reading
  was the 10 ms sampler missing it.
- **2026-08-28** — Step 1 landed (0015, 0016).  RU and RPS unmasked, registers
  latched, three-channel reset installed, `rx_desc_low_water` added, ring size
  moved to the kernel command line.  Recovery worked; the interrupt storm from
  unmasking RU without re-masking was the surprise.
- **2026-08-28** — Recovery moved in place.  Two hardware facts came out of
  it: the three-channel reset clears GMAC1's control register, and
  `GMAC_CORE_INIT` then re-asserts port select, so the link bits have to be
  carried across and restored after `core_init`.  A teardown-ordering bug hung
  the board until it was reordered to match `__stmmac_release()`.
- **2026-08-28** — Step 3: the ring is emptied by a rare excursion, not a
  rising steady load.  Five rates by three ring sizes; medians flat, minima
  collapsing.
- **2026-08-28** — Nothing stalls the refill.  Patch 0017 added poll-gap and
  refill-starvation statistics; all three candidate stalls ruled out.  The
  drain rate is the ceiling, and receive checksum offload was found disabled.
- **2026-08-28** — Receive checksum offload enabled.  Halved per-packet cost
  and roughly halved the wedge count.
- **2026-08-28** — Patch 0018 anchored the low-water reading in the trace and
  split the interval.  The unaccounted 3 to 4 ms is batch delivery up the
  stack, outside `stmmac_rx()`.  Two earlier claims corrected: descriptors are
  not held across the stack work, and refilling inside the receive loop would
  buy nothing.
- **2026-08-29** — Vendor sidecar trial.  A loadable module changed channel-1
  CSR7 to unmask RU and RPS.  The run showed no RU and no wedge, and both
  conclusions were void: the mask did not survive the run, and the counters
  are unreachable while RU is masked in any case.
- **2026-08-29** — Step 4 closed.  Sampling CSR5 directly instead of chasing
  RU showed the vendor suspended in state 4 for 1.3% of samples at the stock
  ring and 31.4% at ring 32, recovering from all 3,970 episodes across the two
  runs while throughput held and CSR8 stayed at zero.  Its `stmmac_poll_func()`
  timer is a periodic kick rather than the cure — episodes average ~5 ms
  against a 50 ms period.  Descriptor exhaustion is therefore ordinary and
  recoverable on this silicon, which retires the premise the plan opened with
  and moves the question to why mainline's refill does not bring the receive
  process back.
- **2026-08-29** — Patch queue reduced to what the open question needs.  0015,
  0017 and 0018 deleted, and 0016 rewritten as a report with the in-place
  recovery removed, renumbered 0015.  `DMA_CUR_RX_DESC_ADDR` had to come with
  it: the register define lived in the deleted patch.  `dma_ops->reset` stays
  the three-channel reset, which is what makes an interface down and up a
  working recovery.
- **2026-08-29** — Both candidates closed by direct measurement.  With the
  recovery gone the wedge is permanent, so it can be read at leisure: CSR19
  frozen inside the ring, and all 256 descriptors DMA-owned in physical memory
  through `/dev/mem`.  Neither a wrong fetch address nor an unseen OWN bit.
- **2026-08-29** — Poll demand exhausted.  A write to CSR2 on a wedged channel
  does nothing, with the vendor's write value and with traffic present.  An
  earlier attempt at `0x101c1104` had tested transmit poll demand instead and
  was void.  `stmmac_poll_func()` was then confirmed a HiSilicon addition
  absent from stock 3.0, mirrored as patch 0016, and made no difference at
  50 ms with the outer cache on and at full speed.
- **2026-08-29** — Question reframed.  One RU interrupt is raised per run with
  the source re-armed every 50 ms, so the channel is not retrying and failing;
  it has stopped fetching.  Nothing done to a suspended channel restarts it,
  which moves the question from what the vendor does at runtime to how the
  vendor's channel is configured.
- **2026-08-29** — The vendor's refill-path kick found and reproduced.  Its
  `stmmac_rx_refill()` ends with a barrier and a receive poll demand on every
  pass that handed a descriptor back; upstream ends with a tail pointer write
  that no DWMAC1000 implements, so mainline notifies the DMA of a refill by no
  means at all.  Patch 0017 supplies the notification, with the vendor's exact
  barrier.  It does not prevent the wedge.  A counter added afterwards proved
  the call site fires — 54 kicks in the failing run — so the null result is
  the poll demand's and not dead code's.  That was the last untried placement,
  and it closes poll demand as the difference between the two drivers.
- **2026-08-30** — Solved.  CSR6 bit 24, DFF, is the difference: clear, the
  receive DMA flushes a frame it has no descriptor for and the MTL receive
  FIFO goes out of sync with it; set, the frame waits in the FIFO and the
  channel resumes.  One boot, toggled live, 3.75 GB and 3.71 GB with the bit
  against 5.12 MB and a wedge without it, and 706-714 Mbit/s where 468 was
  the recorded ceiling.  The successful runs still suspend in state 4 and
  recover, as the vendor's do.  Found by comparing CSR6 register by register
  after CSR0 had been brought to parity and accounted for nothing.
- **2026-08-30** — Already fixed upstream, one release out of reach.
  `45d100ee0d6e` by Rohan G Thomas, merged to net-next 2025-11-27, first
  released in 6.19, reported on SoCFPGA parts with the same DWMAC1000 IP
  where it shows as one-ping-interval latency rather than a permanent stop.
  It pairs DFF with a refill-path poll demand for the same reason patch 0017
  exists.  Never backported to 6.18.y and will not be: net-next, no `Fixes:`
  tag, no `Cc: stable`.  This port targets 6.18 LTS, the last release without
  it.
- **2026-08-30** — The TNK attribution corrected.  HiSilicon ships two
  drivers for this MAC whose `dwmac1000_dma.c` differ only in an include, a
  Kconfig symbol and one comment: the stmmac fork credits DFF to the TNK
  offload engine, `higmacv300` carries no offload code and calls the same bit
  required by the GMAC.  The requirement is the MAC's.
- **2026-08-30** — The poll demand's role established by measurement.  DFF
  alone leaves the channel suspended indefinitely: one episode, entered at
  6.74 s and unbroken 43 s later, 2.3 MB transferred.  Either poll demand
  source revives it, and the two differ only in latency — the 50 ms timer
  averages 30 ms per episode for 452 Mbit/s, the refill kick 3.2 ms for
  719 Mbit/s.  So 0017 is necessary and 0016 is a worse substitute for it
  rather than an addition to it.  Exhaustion itself is unchanged by DFF,
  arriving 4 to 6 s into a run either way.
- **2026-08-30** — A measurement lost to its own instrumentation.  The 50 ms
  timer re-arms RUE and RSE each tick against a handler that reports and
  masks, which put 20 `netdev_err` lines a second onto a synchronous serial
  console because `ignore_loglevel` is on the boot line.  It cost a factor of
  four: the same configuration read 598 MB with the console noisy and 2.40 GB
  with it quiet.
