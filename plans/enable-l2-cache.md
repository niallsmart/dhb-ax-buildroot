# Enabling the L2 cache

The Hi3531 has a 256 KB unified L2 cache that this port does not use. The
block is a HiSilicon "L2 Cache V200", not an ARM PL310, so no mainline driver
binds to it. The vendor 3.0.8 SDK ships a complete driver for it
(`arch/arm/mm/cache-hil2v200.c`), and that driver is what has to be
forward-ported.

This is a performance change only. The board boots and runs correctly with
the outer cache off.

## Established state

| Fact | Evidence |
|---|---|
| Controller sits at `0x20700000` | `REG_BASE_L2CACHE` in the SDK `platform.h`; the datasheet address map gives `0x2070_0000`–`0x207F_FFFF` as "L2 cache space" |
| 256 KB, 32-byte lines | datasheet §3.11.2, and `cache-hil2v200.h` |
| 8 ways | `L2_WAY_NUM` in `cache-hil2v200.h`. The datasheet does not state associativity |
| Error interrupts are GIC SPI 37, 38, 39 (Linux IRQ 69/70/71) | `INTNR_L2CACHE_*` = `GODNET_IRQ_START + 37/38/39`, seen in vendor `/proc/interrupts` |
| The SDK's Godnet U-Boot leaves the block off | Godnet's `cleanup_before_linux()` contains disable/enable call sites, but `include/configs/godnet.h` defines `CONFIG_L2_OFF`, which compiles those calls and the Godnet L2 implementation out |
| Vendor Linux enables the block | The running 3.0.8 kernel logs `L2cache cache controller enabled`; individual `devmem` reads show `L2_CTRL=0x1`, `L2_AUCTRL=0x01803000`, `L2_INTMASK=0x3fff`, `L2_RINT=0`, and both lockdown registers zero |
| `CONFIG_CACHE_L2X0=y` in `linux.config` | force-selected by `ARCH_HI3xxx` in `arch/arm/mach-hisi/Kconfig` |
| Nothing binds in the maintained kernel | no L2 node in `hi3531.dtsi`, and `init_IRQ()` only calls `l2x0_of_init()` when the machine descriptor sets `l2c_aux_val`/`l2c_aux_mask`, which the generic DT machine does not |

`CONFIG_CACHE_L2X0=y` is therefore inert, not wrong. It cannot be turned off
without patching `mach-hisi/Kconfig`, and leaving it on costs a few KB of
unreachable text. Do not point an `arm,pl310-cache` compatible at
`0x20700000`: the register layouts do not overlap, and PL310's control
register offset is this block's `L2_AUCTRL`.

Full hardware detail, including the register map and the evidence that this
is not a PL310, is in the guide's
[SoC overview](https://github.com/niallsmart/dhb-ax-guide/blob/main/doc/01-soc-overview.md#l2-cache-controller).

### What the vendor documents, and where

Datasheet §3.11.2 (p. 3-279) describes the cache: size, line length,
write-back and write-through behaviour, lockdown, exclusive mode, ECC on the
tag and data RAMs with single-bit correction, and clean/invalidate by way,
by way+index, or by address. It publishes no register map. §3.11 is the only
section in chapter 3 without "Register Summary" and "Register Description"
subsections; §3.2–§3.9 each have both, and no L2 register name appears in any
of the SDK's 63 PDFs. The Chinese edition is the same document.

Register offsets and bit assignments therefore come only from vendor source,
of which there are four relevant copies:

| Source | Bears on |
|---|---|
| `linux-3.0.y/arch/arm/mm/cache-hil2v200.{c,h}` | this hardware; the driver being ported |
| `linux-3.0.y/arch/arm/mm/cache-hil2v100.{c,h}` | the previous controller generation; cross-checks the V200 encoding |
| `u-boot-2010.06/arch/arm/include/asm/arch-godnet/l2_cache.h` | carries the **V100** layout (`INVALID` `0x204`, `CLEAN` `0x208`) and the wrong `0x16800000` base, not V200's `0x210`/`0x214` at `0x20700000` |
| `u-boot-2010.06/arch/arm/cpu/godnet/godnet/cache.c` | an independent enable/disable implementation, compiled out by Godnet's `CONFIG_L2_OFF` |

The U-Boot header also declares `L2_SIZE` as 128 KB, disagreeing with both the
V100 kernel header and the datasheet. Treat that file as stale; it is dead
code aimed at the wrong offsets.

## Where the kernel lets a non-PL310 outer cache hook in

`arch/arm/kernel/irq.c:148` ends `init_IRQ()` with an unconditional
`uniphier_cache_init()`, stubbed to `-ENODEV` through
`asm/hardware/cache-uniphier.h` when `CACHE_UNIPHIER` is off. That is the
template: a DT-probed outer cache that is not an l2x0, initialised right
after `irqchip_init()`, before any DMA and while the system is still
single-CPU. Copy the shape exactly — one call added to `init_IRQ()`, one
header with a stub, one file under `arch/arm/mm/`.

No machine descriptor is needed. The board matches
`__mach_desc_GENERIC_DT` and should keep doing so.

The vendor's own ordering — a platform device and driver bound at
`device_initcall`, after `smp_init()` — is proven on this silicon, but it is
later than necessary and carries platform-device boilerplate that buys
nothing here.

## What has to change from the vendor driver

The `outer_cache` hooks the vendor fills still exist. The work is API drift
and a handful of defects, not reverse engineering.

| Vendor code | Problem | Port to |
|---|---|---|
| `outer_cache.inv_all = l2cache_inv_all` | the field no longer exists in `struct outer_cache_fns` | drop the assignment; keep `__l2cache_inv_all()` as an internal helper for init |
| `l2cache_disable()` writes `0` to `L2_CTRL` and nothing else | `outer_disable()` is contracted to clean *and* invalidate before disabling; dirty lines would be dropped whenever the hook is used, including ARM's single-CPU soft-restart path. This is a regression against the vendor's own U-Boot, whose `l2cache_disable()` cleans and invalidates every way first | flush all ways, write `0`, then `dsb(st)`, as `l2c_disable()` does |
| `l2cache_handle()` clears with `writel_relaxed(0, ..INTCLR)` | the maintenance path proves that `AUTO_END` is write-1-to-clear: both kernel generations and U-Boot read `L2_RINT` and write it back after every operation. The header gives each error bit the same position in `RINT` and `INTCLR`, although those error bits remain untested. If they share the established semantics, writing `0` clears nothing and a latched error re-fires forever | read `L2_RINT` and write it back to `L2_INTCLR`. The same applies to the init path's "clean last error int" write |
| `l2cache_inv_range()` rounds `start` down and invalidates every touched line | for an unaligned DMA buffer, invalidating a partial first or last line can discard dirty bytes belonging to an adjacent object. Mainline's `l2c210_inv_range()` clean-invalidates partial boundary lines for exactly this reason | clean then invalidate each partial boundary line; invalidate only fully covered interior lines. Handle a range contained in one line without letting the interior loop wrap or overrun |
| range ops return without a sync | `l2c210_{inv,clean,flush}_range()` all end in `__l2c210_cache_sync()`; `arch/arm/mm/dma-mapping.c` calls `outer_*_range()` with no sync of its own | end each range op with `cache_sync()` inside the lock |
| `DEFINE_SPINLOCK` | outer-cache ops run from atomic context; l2x0 uses `raw_spinlock_t` for PREEMPT_RT | `DEFINE_RAW_SPINLOCK` |
| `IO_ADDRESS(REG_BASE_L2CACHE)` | no `mach/platform.h` | find the DT node, reject an unavailable node, then use `of_iomap()` |
| `request_irq()` inside init | too early, and it unmasks `0x3fff` before a handler is reliable | leave `L2_INTMASK` at `0` and register no handlers; see [Error reporting is deferred](#error-reporting-is-deferred) |
| never writes `L2_DLOCKWAY` or `L2_ILOCKWAY` | the datasheet documents way lockdown, and firmware may leave ways locked, silently reducing capacity. Mainline clears both unconditionally (`l2c_unlock`) | zero both at init |
| `l2cache_flag` guards printing on every op | ops are only installed after a successful init | delete |
| `sync_writel(val, reg, complete_mask)` | the mask argument is ignored — it is just `writel_relaxed` | use `writel_relaxed` directly |
| `#ifdef CONFIG_ARCH_HI3520D` sizing | not this SoC | 256 KB fixed |

Keep the vendor's register encodings, but not its defective range-boundary or
disable behaviour. In particular,
`l2cache_inv_range()` writes `addr | BIT_L2_INVALID_BYADDRESS`, where that
constant is `1` used as a literal mask even though the neighbouring
`WAYADDRESS` and `LINEADDRESS` constants in the same header are bit positions.
`l2cache_flush_range()` writes the same `addr | 1` to both `L2_CLEAN` and
`L2_INVALID`. The V100 driver, written for different silicon, contains the
identical construction, so this is a stable vendor convention: bit 0 selects
the by-address operation, and only the constant's name alongside two genuine
bit positions makes it look wrong. Reproduce it.

The `L2_MAINT_AUTO` encoding is self-consistent and can be trusted: bit 0
start, bit 1 clean, way number from bit 2. Completion is polled on
`L2_RINT` bit 14 (`AUTO_END`) and cleared write-1. U-Boot's `L2CleanAuto()`
and `L2InvalidAuto()` use the same encoding.

## `OUTER_CACHE_SYNC` is required, and it is not free

The SDK settles whether the sync is needed: `CACHE_HIL2V200` selects
`OUTER_CACHE_SYNC`, and the driver supplies `outer_cache.sync` by reading
`L2_SYNC`. Datasheet §3.11.2 explains the hardware behind that choice: three
eviction buffers hold lines destined for main memory and three write buffers
sit between L1 and the L2. The unpublished register specification prevents a
stronger claim about exactly what a CPU `dsb` drains, but dropping the vendor's
sync would violate the ARM outer-cache contract. It is a correctness
requirement, not a tuning choice, and the build ships with it.

The cost is real but narrower than the register's placement suggests.
`OUTER_CACHE_SYNC` selects `ARM_HEAVY_MB`, making `mb()` and `wmb()` call
`outer_cache.sync()` (`arch/arm/mm/flush.c:24`). On ARM `writel()` contains
`wmb()` and so pays it; `readl()` contains `rmb()`, which is a plain `dsb()`
and does not. The overhead therefore lands on every MMIO *write* and on
explicit barriers, not on all MMIO traffic.

That still falls on the Ethernet path, which is already CPU-bound on software
checksums (see
[optimizing-network-throughput.md](optimizing-network-throughput.md)).
Measure what it costs — the benchmark section describes how — but read the
result as sizing a mandatory cost, not as a choice about whether to pay it.

## Shared memory must be allowed to allocate

§3.11.2: "Supports shared mode. By default, the shared operation is cacheable
but cannot be allocated." An SMP kernel maps kernel and user memory as
Shared, so on the reset default most of what this board runs would never
populate the L2 at all. The measurement would come back flat, and would look
exactly like a cache that does not help.

`L2_AUCTRL` bit 15 (`SHARED_ATTRIBUTE_OVER_EN`) overrides this. PL310 carries
the same control at `L2C_AUX_CTRL_SHARED_OVERRIDE`, exposed as the
`arm,shared-override` device-tree property and set by several mainline
platforms (`arch/arm/mm/cache-l2x0.c:1065`).

The vendor driver leaves the bit clear, and the recorded `L2_AUCTRL` value
from the running vendor system, `0x01803000`, confirms it clear in practice.
Whether that cost them most of the cache or the default behaves better than
§3.11.2 reads cannot be settled from the documentation. Set the bit, and make
it a separately measured variable rather than a silent init step.

Two further `L2_AUCTRL` controls stay off: forcible write-allocate (bit 16),
and exclusive caching (bit 11), which would need a matching Cortex-A9 setting
to be coherent.

## Implementation

Kernel patches go in `br2-external/board/dhb-ax/patches/linux/`, continuing
after `0011`. Device trees are not patches — they live in
`br2-external/board/dhb-ax/dts/hisilicon/`.

**1. `0012-arm-mm-add-hisilicon-l2-cache-v200-driver.patch`**

- `arch/arm/mm/cache-hil2v200.c` — the ported driver.
- `arch/arm/mm/cache-hil2v200.h` — the vendor register header, trimmed to the
  offsets and bits actually used.
- `arch/arm/include/asm/hardware/cache-hil2v200.h` — `int hil2v200_cache_init(void);`
  plus the `-ENODEV` stub, mirroring `cache-uniphier.h`.
- `arch/arm/mm/Kconfig` — `config CACHE_HIL2V200`, `depends on ARCH_HI3xxx`
  (not `ARCH_HISI`, which also covers the ARMv5 SD5203), `select OUTER_CACHE`,
  `select OUTER_CACHE_SYNC`.
- `arch/arm/mm/Makefile` — `obj-$(CONFIG_CACHE_HIL2V200) += cache-hil2v200.o`.
- `arch/arm/kernel/irq.c` — add `hil2v200_cache_init();` beside
  `uniphier_cache_init();`.

Init sequence, following the vendor apart from the corrections above:

1. Find the compatible node. Return `-ENODEV` if it is absent or disabled, and
   fail without installing any hooks if `of_iomap()` fails.
2. Read `L2_CTRL`. The SDK's normal Godnet U-Boot path hands Linux a disabled
   cache, but if another firmware leaves it enabled, clean and invalidate all
   ways before writing `0`; never discard an enabled cache's dirty contents.
   Clear any stale `AUTO_END` status before starting this maintenance.
3. Set `EVENT_BUS_EN`, `MONITOR_EN` and `SHARED_ATTRIBUTE_OVER_EN` in
   `L2_AUCTRL`.
4. Zero `L2_DLOCKWAY` and `L2_ILOCKWAY`.
5. Clear the special-check registers, and clear `L2_RINT` by writing back
   what it reads.
6. Leave `L2_INTMASK` at `0`.
7. Invalidate all eight ways. Put `cpu_relax()` in each completion-poll loop,
   matching mainline's non-timeout cache-maintenance polling style.
8. Write `1` to `L2_CTRL`.
9. Install the `outer_cache` pointers and log one line.

Use unlocked internal all-way helpers beneath both `flush_all` and `disable`;
calling the public, locking `flush_all` while `disable` already holds the raw
spinlock would deadlock.

**2. `0013-dt-bindings-add-hisilicon-hi3531-l2-cache.patch`**

`Documentation/devicetree/bindings/cache/hisilicon,hi3531-l2-cache.yaml`,
following the pattern of the existing `0011` platform-binding patch. Reference
`/schemas/cache-controller.yaml#`, require exactly one register region and
three interrupts, and constrain the standard cache properties used below.

**3. `hi3531.dtsi`** — add under `soc`, `status = "disabled"`:

```
l2: cache-controller@20700000 {
	compatible = "hisilicon,hi3531-l2-cache";
	reg = <0x20700000 0x1000>;
	interrupts = <GIC_SPI 37 IRQ_TYPE_LEVEL_HIGH>,
		     <GIC_SPI 38 IRQ_TYPE_LEVEL_HIGH>,
		     <GIC_SPI 39 IRQ_TYPE_LEVEL_HIGH>;
	cache-unified;
	cache-level = <2>;
	cache-size = <262144>;
	cache-sets = <1024>;
	cache-line-size = <32>;
	status = "disabled";
};
```

Both CPU nodes gain `next-level-cache = <&l2>;`. Without it the L2 node is an
orphan that nothing references, and `cacheinfo` cannot find it.

The register file ends at `0x80C`, so `0x1000` covers it. The three SPI
numbers follow the same `vendor IRQ - 32` rule already used for SATA and
Ethernet in this file. `cache-size` and `cache-line-size` are from datasheet
§3.11.2; `cache-sets` is derived from the SDK's `L2_WAY_NUM`, which the
datasheet does not corroborate. Say which is which in the node comment.

**4. `hi3531-dhb-ax.dts` and `hi3531-dhb-ax-minimal.dts`** — `&l2 { status = "okay"; };`

Keeping the node disabled in the `.dtsi` and enabling it per board follows
the existing convention and gives a one-line, no-rebuild-of-the-kernel way to
turn the cache off for A/B measurement and bisection. The init helper must call
`of_device_is_available()` explicitly: compatible-node searches include
disabled nodes, so the DT switch is otherwise ineffective.

**5. `linux.config` and `linux-minimal.config`** — `CONFIG_CACHE_HIL2V200=y`.

The 32-byte L2 line is smaller than `L1_CACHE_BYTES` (64, from
`ARM_L1_CACHE_SHIFT_6`), so DMA allocation and bounce alignment need no
config change. Streaming DMA mappings can still begin or end part-way through
an L2 line; that is why `inv_range` needs the boundary handling above.

## Verification

**Both CPUs online is the first check, and the cheapest.**
`arch/arm/kernel/smp.c:156` calls `sync_cache_w(&secondary_data)` immediately
before `smp_boot_secondary()`, and that reaches `outer_clean_range()` through
`asm/cacheflush.h:393`. CPU1 reads `secondary_data` with its MMU and caches
off, so if `clean_range` does not actually push the line to DRAM, CPU1 never
starts. A missing sync therefore announces itself on the first SMP boot,
loudly, before any data is at risk. Check `nproc` before anything else.

`hi3531_boot_secondary` itself needs no `outer_clean_range`: it writes one
MMIO register, unlike the socfpga and rockchip SMP operations, which clean a
trampoline they placed in DRAM. Do not add one.

Then:

1. The driver's own boot line, and no `l2x0:` line.
2. `devmem 0x20700000` reads `0x00000001`. `0x20700004` reads with bits 12,
   13 and 15 set — the vendor system shows `0x01803000`, which has 12 and 13
   but not 15, so this value is expected to differ from the recorded one.
3. `0x20700108` (`L2_RINT`) stays `0` under load — no latched bus or ECC
   errors. Read it by hand; no interrupt handler is installed.
4. `/sys/devices/system/cpu/cpu0/cache/index2/` should report level 2,
   unified, size 262144, line 32, sets 1024. `CLIDR` does not describe an
   external L2, but `init_cache_level()` extends the level count from the
   device tree via `of_find_last_cache_level()`, so this entry comes from the
   `next-level-cache` phandle. Unverified on hardware. Note that the phandle
   walk ignores `status`, so the entry appears even with the controller
   disabled: it confirms the description, never that the cache is running.
5. Boot once with the node disabled and confirm that the driver line is absent
   and `L2_CTRL` remains `0`. This proves that the A/B switch controls
   hardware, rather than only changing the cache description.

Before hardware boot, build both normal and minimal configurations and run the
new schema through `dt_binding_check`; compile success alone does not validate
the binding or the two DT instances.

Then exercise the DMA masters hard, because a missing sync in the range ops
shows up as silent corruption and nowhere else:

- SATA: write and re-read a multi-GB file on the HDD, compare.
- Ethernet: long `scp`/`iperf3` runs plus varied small packet lengths, then
  compare transferred payloads. Non-line-sized RX lengths exercise the
  partial-last-line invalidation path.
- Initramfs root: boot `buildroot-tftp` and run a CPU-intensive workload.
- USB: the production kernel lives on the USB drive; re-read it.

## Benchmarks

Baselines already exist in
[optimizing-network-throughput.md](optimizing-network-throughput.md) — reuse
them so the comparison is against recorded numbers rather than fresh ones.
Debian trixie is available as a root filesystem, so `sysbench`, `lmbench` and
`openssl` are one `apt install` away.

| Measurement | Why it should move |
|---|---|
| `lmbench` `lat_mem_rd` / `bw_mem` | direct read of whether a 256 KB working set now hits |
| `iperf3` TCP single stream (231 Mbit/s baseline) | software checksums are per-byte memory work |
| `scp` 256 MB, both directions (27.84 s / 30.06 s baseline) | same, plus SATA |
| `openssl speed -evp aes-128-cbc`, `sha256` | CPU-bound with a small working set; isolates the L2 from the network path |
| kernel decompression / boot to login | coarse, but free |

Run the ordinary measurements three ways: cache off (`status = "disabled"`),
cache on, and cache on without `SHARED_ATTRIBUTE_OVER_EN`. The third isolates
how much the shared-attribute default costs.

A temporary driver build that omits the `outer_cache.sync` assignment is
intentionally incorrect. It leaves `ARM_HEAVY_MB` compiled in but makes its
pointer check a no-op, which isolates the global barrier cost without fighting
the force-selected `CACHE_L2X0` dependency. If that measurement is still
useful, boot the build only as a TFTP-loaded minimal initramfs, leave the HDD
and USB filesystems unmounted, and restrict the run to disposable network
traffic and CPU/memory tests. Do not use `scp`, write storage, or boot either
production root with it.

Treat the controller counters as exploratory until their semantics are
established. §3.11.2 says the block can count access, write-back, loss, and
loss-and-wait events, while the source only gives address ranges: internal
`0x600`–`0x628`, external `0x700`–`0x76C`. It does not map registers to
events, document reset/overflow behaviour, or say whether each register is a
counter.

The running vendor system confirms that raw reads cannot yet be interpreted as
hit rates. With `MONITOR_EN` set, several internal words change but are not
monotonic over a one-second interval, while every external word reads
`0xffffffff`. Establish selection, reset, direction and overflow/saturation
semantics with controlled workloads before using any of them in benchmark
results. Until then, throughput and `lat_mem_rd` working-set knees are the
primary evidence that the cache allocates and helps.

## Risk and rollback

The failure mode that matters is silent DMA corruption from an incorrect
clean/invalidate, which will not announce itself. Stage the kernel alone
during iteration and keep a known-good path available:

```sh
tools/dvr-stage.sh --kernel-only buildroot-usb-hdd
```

If the board stops booting, `tools/dvr-stage.sh minimal-tftp` followed by
`tools/dvr-boot.sh minimal-tftp` recovers without touching the HDD, and the
minimal image can be built with the L2 node disabled to rule the cache in or
out in one step.

Nothing in this work goes near the SPI NOR, the NAND or the saved U-Boot
environment.

The diagnostic build without the `outer_cache.sync` hook is subject to the
stricter isolation in the benchmark section; it must never run against a
writable production filesystem.

## Error reporting is deferred

The first cut leaves `L2_INTMASK` at `0` and registers no handlers for SPI
37, 38 and 39. The datasheet establishes ECC on the tag and data RAMs, with
single-bit correction; the vendor header identifies parity/ECC, bus-error and
maintenance-completion interrupt sources.

Deferring them costs little and avoids a specific hazard. The vendor's
handler clears the wrong way, so if the write-1-to-clear reading is right, an
error would re-fire indefinitely; because the handler returns `IRQ_HANDLED`,
genirq's spurious detection would not shut it down. A storm at boot is worse
than no error reporting. `L2_RINT` is read by hand during verification
instead.

Wiring them up later means fixing the clear, registering the three lines from
an `arch_initcall`, and only then unmasking.

## Open questions

- Whether the non-`AUTO_END` bits in `L2_INTCLR` are also write-1-to-clear.
  `AUTO_END` is settled by every working vendor maintenance implementation;
  the error bits are inferred from the header's matching `RINT`/`INTCLR`
  positions. Confirm them on hardware by latching an error through
  `L2_INTTEST` (`0x404`) before relying on the deferred error path. Nothing
  in the first cut depends on the error-bit answer.
- What sets `L2_AUCTRL` bits 23 and 24. The recorded vendor value is
  `0x01803000`; the vendor driver only ORs in bits 12 and 13, so those two
  come from reset or from earlier firmware. Read `L2_AUCTRL` on the minimal
  image, before anything touches the block, to find out which.
- Performance-counter programming. Vendor Linux proves that the internal
  block is active and the external range reads all ones, but neither source nor
  documentation defines event selection, reset, or overflow. Do not attach
  event names or hit-rate meaning to those words without a controlled hardware
  correlation.
- Suspend/resume. The vendor implements `l2cache_suspend`/`l2cache_resume`;
  mainline expects `outer_cache.resume`. This board has no working suspend
  path, so leave the hook unimplemented and note it.

## Follow-up

On success, update the `L2 cache` row in [remaining-work.md](remaining-work.md)
and move the reusable hardware conclusions — the interrupt-clear semantics,
what the shared-attribute override is worth, the measured gain, the sync cost
— into the guide's SoC overview, which currently ends its L2 section at "the
work is adapting it to device tree probing and current locking conventions".

The guide's SoC overview also needs two corrections regardless of outcome: it
cites the SDK as the only source for the L2's size and line length, which
datasheet §3.11.2 states directly, and its porting-implications paragraph
lists the `outer_cache` hooks to fill without noting that `inv_all` no longer
exists.
