# Step 3: Hi3531 SMP reconciliation

Date: 2026-08-13

This is a local reconciliation record and is intentionally excluded from source
control. The test kernel was loaded over TFTP and booted from DRAM. No test
command wrote flash or SATA, and the test kernel mounted neither device. The
first U-Boot-interrupt attempt missed and briefly allowed the factory system to
boot; it was then rebooted normally before the successful TFTP boot.

## Source comparison

Linux 6.18.42's existing `hisilicon,hi3620-smp` implementation is not a
jump-address-only method. `hi3xxx_boot_secondary()` calls `hi3xxx_set_cpu()`,
which finds the generic `hisilicon,sysctrl` node already present in the board
DTS and performs Hi3620-specific writes at offsets `0xf4`, `0x410`/`0x414`, and
`0x200`. It then writes the secondary entry and sends a wakeup IPI. The same SMP
operations structure installs Hi3620 CPU-hotplug callbacks.

This disproves the maintained DTS comment that the Hi3620 power-control step
would no-op in the absence of a separate `hisilicon,hi3620-cpu-ctrl` node.

Patch `0010-arm-hisi-add-hi3531-smp-operations.patch` therefore adds a dedicated
`hisilicon,hi3531-smp` method. Its prepare callback enables the Cortex-A9 SCU
and maps `hisilicon,hi3531-sysctrl`. Its boot callback accepts CPU1 and writes
`__pa_symbol(secondary_startup)` to sysctrl offset `0x134`. It performs no
power, reset, WFI-mask, or IPI operation and exposes no hotplug callbacks.

## Build validation

The full Buildroot build applied all ten Linux patches with zero fuzz and
compiled the kernel, both DTBs, and both appended-DTB uImages successfully.
The generated minimal DTB contains:

```text
enable-method = "hisilicon,hi3531-smp"
compatible = "hisilicon,hi3531-sysctrl", "hisilicon,sysctrl"
```

It contains no `smp-offset` property. The linked kernel contains the Hi3531 CPU
method and `secondary_startup` at physical address `0x80013000`.

Test image:

```text
artifacts/buildroot/uImage-hi3531-dhb-ax
SHA-256 4f7bc4c42a49502cee539d9e486a954fe00ae00448032cfe93e4d6b179902cc9
```

The staged TFTP copy had the same digest.

## Runtime validation

Immediately before `bootm`, U-Boot read:

```text
SYS_CTRL + 0x0f4 = 0x00000000
SYS_CTRL + 0x410 = 0x00000000
SYS_CTRL + 0x414 = 0x00000000
SYS_CTRL + 0x200 = 0x00000000
CRG      + 0x028 = 0x00000023
SYS_CTRL + 0x134 = 0x00000000
```

Linux 6.18.42 then reported:

```text
smp: Bringing up secondary CPUs ...
CPU1: Spectre v2: using BPIALL workaround
smp: Brought up 1 node, 2 CPUs
SMP: Total of 2 processors activated (3706.06 BogoMIPS).
online=0-1
present=0-1
possible=0-1
nproc=2
MemTotal: 1032968 kB
```

Post-boot reads were identical except for the intended jump word:

```text
SYS_CTRL + 0x0f4 = 0x00000000
SYS_CTRL + 0x410 = 0x00000000
SYS_CTRL + 0x414 = 0x00000000
SYS_CTRL + 0x200 = 0x00000000
CRG      + 0x028 = 0x00000023
SYS_CTRL + 0x134 = 0x80013000
```

Two concurrent `dd if=/dev/zero bs=1M count=256 | sha256sum` workers both
exited zero and produced the same digest:

```text
a6d72ac7690f53be6ae46ba88506bd97302a093f7108472bd9efc3cefda06484
```

From the `/proc/stat` snapshots, CPU0 gained 1,222 user and 343 system ticks;
CPU1 gained 1,258 user and 307 system ticks. Each gained exactly 1 idle tick,
so both cores were concurrently busy for essentially the entire workload. Both
CPUs remained online afterward, and the kernel log contained no CPU bring-up,
RCU stall, watchdog, lockup, Oops, or panic diagnostic.

The post-load interrupt table also showed CPU1 actively servicing cross-core
work: 18,437 timer-broadcast IPIs, 46 rescheduling IPIs, and 193 function-call
IPIs. The interrupt error count was zero. The hardware timer IRQ remained on
CPU0 and Linux delivered CPU1's ticks through the broadcast IPI path.

## Conclusion

The guide is correct for this discrepancy: the Hi3620 method performs unsafe,
SoC-specific operations even with this board's node layout. The dedicated
Hi3531 method is statically minimal and the target hardware validates its only
secondary-release write. CPU1 is stable under concurrent computational load.
CPU hotplug remains deliberately unsupported because no safe return-to-polling
sequence has been established.
