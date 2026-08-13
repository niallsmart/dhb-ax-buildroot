# Memory and address space map

HiSilicon Hi3531 (`godnet`) as fitted to the LTS LTD2704XE-P's TVT
`DHB_AX V1.2` motherboard. Written 2026-08-04, after the memory expansion from
216 MiB to 501 MiB usable.

Peripheral addresses are from the pinned OpenIPC
[`mach-godnet` platform header](https://github.com/OpenIPC/linux/blob/a3bfde54cdcf641cc061206f5d2ba6e9ddbad324/arch/arm/mach-godnet/include/mach/platform.h).
DRAM figures are measured on the board, not inferred — see *Evidence* at the
end.

## Physical address space

```text
0x00000000  ┌──────────────────────────────────────────────┐
            │                                              │
0x04000000  │  Boot ROM                                    │
0x04010000  │  Internal SRAM                               │
            │                                              │
0x10000000  ├──────────────────────────────────────────────┤
            │  NAND controller            0x10000000       │  not yet
            │  SPI NOR controller         0x10010000       │  not yet
            │  SD/MMC  (no slot fitted)   0x10020000       │  n/a
            │  Serial audio SIO0-3        0x10030000       │
            │  eFUSE                      0x10070000       │
            │  SATA / AHCI                0x10080000       │  ● USED
            │  USB OHCI                   0x100a0000       │  ● USED
            │  USB EHCI                   0x100b0000       │  ● USED
            │  Cipher engine              0x100c0000       │
            │  DMA controller             0x100d0000       │  gated
            │  Serial audio SIO4-5        0x100e0000       │
            │  Smartcard SCD0/1           0x10150000       │
            │  JPEG decoder               0x10170000       │
            │  GMAC + DMA + TNK           0x101c0000       │  ● USED
            │                                              │
0x20000000  ├──────────────────────────────────────────────┤
            │  Timer 0 / 1  (SP804)       0x20000000       │  ● USED
            │  CRG  clocks & resets       0x20030000       │  ● USED
            │  Watchdog  (SP805)          0x20040000       │  partial
            │  System controller          0x20050000       │  ● USED
            │  RTC  (PL031, clock-gated)  0x20060000       │  dead
            │  Infrared receiver          0x20070000       │
            │  UART0  console             0x20080000       │  ● USED
            │  UART1 / 2 / 3              0x20090000       │  next up
            │  SPI  (PL022)               0x200c0000       │
            │  I2C  (unused by vendor)    0x200d0000       │  n/a
            │  Pin mux                    0x200f0000       │
            │  DDR controller 0 / 1       0x20110000       │
            │  Timer 2 / 3                0x20130000       │
            │  GPIO banks 0-18  (PL061)   0x20150000       │  ● USED
            │  GIC interrupt controller   0x20300000       │  ● USED
            │  CoreSight debug            0x20400000       │
            │  ── media engines ──────────────────────     │
            │  VICAP, VDP, HDMI, IVE,     0x20580000       │
            │  VPSS, TDE, VENC, VDH,        ...            │  OUT OF
            │  VOIE, JPGE, VCMP, MD, BSD  0x206d0000       │  SCOPE
            │  L2 cache  (HIL2V200)       0x20700000       │  disabled
            │  PCIe 0 / 1 registers       0x20800000       │
            │                                              │
0x30000000  ├──  PCIe 0 memory window  ────────────────────┤
0x40000000  ├──  PCIe 0 config         ────────────────────┤
0x50000000  ├──  NAND data window      ────────────────────┤
0x58000000  ├──  SPI NOR data window   ────────────────────┤
0x60000000  ├──  PCIe 1 memory window  ────────────────────┤
0x70000000  ├──  PCIe 1 config         ────────────────────┤
            │                                              │
0x80000000  ╞══════════════════════════════════════════════╡
            ║                                              ║
            ║   DDR0   —   512 MiB real                    ║
            ║   this port's memory node lives here         ║
            ║                                              ║
0xa0000000  ╞══════════════════════════════════════════════╡
            │  aliases DDR0.  Wrap period is 0x20000000.   │
            │  0xa8000000 == 0x88000000   (measured)       │
            │                                              │
0xc0000000  ╞══════════════════════════════════════════════╡
            ║                                              ║
            ║   DDR1   —   512 MiB real                    ║
            ║   SEPARATE memory, not an alias of DDR0.     ║
            ║   Unused by this port; the vendor gives      ║
            ║   all of it to MMZ for video buffers.        ║
            ║                                              ║
0xe0000000  ╞══════════════════════════════════════════════╡
            │  aliases DDR1.  Same 0x20000000 period.      │
            │  0xe0000000 == 0xc0000000   (measured)       │
            └──────────────────────────────────────────────┘
```

**The board carries 1 GiB of DRAM across two banks**, one per DDR controller
(`DDRC0` at `0x20110000`, `DDRC1` at `0x20120000`). Four `NT5CB128M16` at
256 MB each; U1 and U2 are on the top side, the other two are presumably on
the underside, which has not been photographed.

Registers and RAM never overlap. Every peripheral sits below `0x70000000`;
DRAM starts at `0x80000000`. That is why extending memory to the full 512 MiB
could not collide with anything — the question worth checking before booting a
larger memory node.

## Inside DRAM

```text
0x80000000  ┌──────────────────────────────────────────────┐  ─┐
            │  vectors, early boot                         │   │
0x80008000  ├──────────────────────────────────────────────┤   │
            │  Kernel code            4,604 K              │   │
            │    + rodata             1,048 K              │   │  ~7.5 MiB
0x805aefff  ├──────────────────────────────────────────────┤   │  kernel
            │  (gap)                                       │   │  image
0x806ba000  ├──────────────────────────────────────────────┤   │
            │  Kernel data  rwdata 523K, bss 188K          │   │
0x8076bfcf  ├──────────────────────────────────────────────┤  ─┘
            │  init  1,068 K   ← freed after boot          │
            ├──────────────────────────────────────────────┤   ~4 MiB
            │  struct page array                           │   memory to
            │  512 MiB / 4 KiB = 131,072 × 32 bytes        │   track memory
            ├──────────────────────────────────────────────┤
            │  page tables, early allocations   ~700 K     │
            ╞══════════════════════════════════════════════╡
            │                                              │
            │                                              │
            │         free for the allocator               │
            │              501 MiB                         │
            │           (MemTotal 513,148 KiB)             │
            │                                              │
            │                                              │
0x9fffffff  └──────────────────────────────────────────────┘

            reserved total 12,208 KiB  ≈ 12 MiB
            no reserved-memory node — the old 32 MiB media
            carve-out at 0x8e000000 is gone
```

The kernel and data boundaries above are `/proc/iomem` on the running board:

```text
80000000-9fffffff : System RAM
  80008000-805aefff : Kernel code
  806ba000-8076bfcf : Kernel data
```

## The numbers

Linux reports memory in **kilobytes**. `MemTotal: 513148` is 513,148 KiB ≈
**501 MiB** — it is not 513 MB, and reading it that way makes it look
impossibly larger than a 512 MiB board.

| | KiB | MiB |
|---|---:|---:|
| DRAM on the board, both banks | 1,048,576 | 1024 |
| DDR0, the bank this port uses | 524,288 | **512** |
| Before this work — kernel was given | 229,376 | 224 |
| Before this work — `MemTotal` | 220,736 | **216** |
| Now — kernel is given | 524,288 | 512 |
| Now — `MemTotal` | 513,148 | **501** |

Two separate deductions, which are easy to conflate:

1. **Board → what the kernel is told.** This was the bug, and it is now zero.
   See *What was wrong* below.
2. **What the kernel is told → `MemTotal`.** About 12 MiB, unavoidable, and
   present on every Linux system.

## What the 12,208 KiB is

The kernel prints most of its own breakdown at boot:

```text
Memory: 511012K/524288K available (4604K kernel code, 523K rwdata,
        1048K rodata, 1068K init, 188K bss, 12208K reserved, 0K cma-reserved)
```

| Component | Size | What it is |
|---|---:|---|
| Kernel code | 4,604 K | the executable itself |
| rodata | 1,048 K | constants, string tables |
| rwdata | 523 K | initialised variables |
| bss | 188 K | zeroed variables |
| init | 1,068 K | setup code, freed after boot |
| **subtotal — the image** | **~7,431 K** | |
| `struct page` array | **~4,096 K** | memory used to track memory |
| page tables, early allocations | ~700 K | |
| **total** | **~12,208 K** | |

It is **not** MMIO registers — those are a separate address range and consume
no RAM. It is **not** DMA buffers — those are allocated at runtime out of
`MemTotal`. The initramfs is unpacked into tmpfs and its original copy freed,
which is part of why `MemTotal` ends up slightly above the boot-time
"available" figure.

### The `struct page` figure, verified by differencing

Linux keeps a record for every 4 KiB page of RAM, allocated before the page
allocator exists. Comparing the two boots isolates it:

| | Total | `MemTotal` | Overhead |
|---|---:|---:|---:|
| 224 MiB boot | 229,376 K | 220,736 K | 8,640 K |
| 512 MiB boot | 524,288 K | 513,148 K | 11,140 K |
| difference | +288 MiB | | **+2,500 K** |

2,500 K over 288 MiB is **8.68 KiB of overhead per MiB of RAM**.

Predicted: 1 MiB ÷ 4 KiB = 256 pages × 32 bytes per `struct page` = **8 KiB
per MiB**. Close enough to confirm the mechanism. For 512 MiB that is ~4 MiB,
and it scales linearly — doubling RAM again would cost another ~4 MiB.

## What was wrong

Three things stacked, together costing 296 MiB:

**U-Boot's ATAG overwrote the device tree.** `arch/arm/boot/compressed/atags_to_fdt.c`
copies `ATAG_MEM` into the FDT, replacing the memory node. The vendor U-Boot
hardcodes 256 MiB, so the correct 512 MiB in our DTS was silently discarded.
Fixed by turning off the compatibility shim, with the reason recorded at the
setting:

```text
# Deliberately OFF. atags_to_fdt.c copies U-Boot's ATAG_MEM into the FDT,
# overwriting the memory node in our device tree...
CONFIG_ARM_ATAG_DTB_COMPAT=n
```

**A 32 MiB media reserve nobody used.** Carried over from the vendor layout for
video buffers this port does not allocate. Removed; `dmesg` now confirms
`No reserved-memory node in the DT` and `/proc/iomem` shows one contiguous
`80000000-9fffffff`.

**The device tree itself.** Now:

```dts
memory@80000000 {
        device_type = "memory";
        reg = <0x80000000 0x20000000>;
};
```

## Each bank wraps, but the banks are distinct

Addresses from `0xa0000000` to `0xbfffffff` are the same silicon as
`0x80000000`. Declaring more than 512 MiB **in one node** would hand Linux
aliased addresses, and the corruption would be silent — two "different" pages
writing over each other with no fault raised.

The wrap period is `0x20000000` (512 MiB) and it applies *within* each bank.
It does **not** carry across the `0xc0000000` boundary, which selects a
different DDR controller. Measured in one U-Boot session:

```text
mw.l 0x88000000 11111111
mw.l 0xa8000000 22222222
mw.l 0x94000000 deadbeef 0x20000    # evict
md.l 0x88000000  ->  22222222       # same memory: DDR0 wraps
md.l 0xa8000000  ->  22222222

mw.l 0x80000000 aaaa5555
mw.l 0xc0000000 12345678
md.l 0x80000000  ->  aaaa5555       # different memory: DDR1 is its own bank
md.l 0xc0000000  ->  12345678

mw.l 0xe0000000 e0e0e0e0
md.l 0xc0000000  ->  e0e0e0e0       # same memory: DDR1 wraps too
```

An earlier revision of this document claimed `0xc0000000` aliased down to
`0x80000000`. That was wrong: it extrapolated a wrap measured inside DDR0
across a boundary the wrap does not cross. U-Boot's splash buffers at
`0xc0000000`/`0xc1000000` are in DDR1, not aliased onto the bottom of DDR0.

## What the vendor does with the gigabyte

The vendor kernel reports only ~215 MiB, which looks like most of the board
being wasted. It is not. The cap is explicit on the command line:

```text
mem=224M console=ttyAMA0,115200 root=/dev/mtdblock2 rootfstype=yaffs2 ...
```

`mem=224M` tells Linux to ignore everything above 224 MiB. The rest goes to
**MMZ** (Media Memory Zone), HiSilicon's proprietary allocator, which lives
entirely outside Linux's memory management. From `/proc/media-mem` on the
running vendor system:

```text
+---ZONE: PHYS(0xC0000000, 0xDF7FFFFF), nBYTES=516096KB, NAME="ddr1"
+---ZONE: PHYS(0x9FA00000, 0x9FEFFFFF), nBYTES=5120KB,   NAME="jpeg"
+---ZONE: PHYS(0x8E000000, 0x9F9FFFFF), nBYTES=288768KB, NAME="anonymous"

total size=809984KB(791MB), used=366956KB(358MB), zone_number=3,
block_number=139
```

Note `0x8E000000` — exactly 224 MiB. MMZ picks up precisely where the Linux
cap ends. Accounting for the whole board:

| Region | Size | Bank |
|---|---:|---|
| Linux (`mem=224M`) | 224 MiB | DDR0 |
| MMZ `anonymous` | 282 MiB | DDR0 |
| MMZ `jpeg` | 5 MiB | DDR0 |
| MMZ `ddr1` | 504 MiB | DDR1 |
| **total** | **~1015 MiB** | of 1024 |

So the vendor uses about 99% of the DRAM. Linux only ever sees 22% of it.

**Why split it this way.** Video encoding needs large physically contiguous
buffers — one live allocation observed here is 61 MB. Linux's allocator
fragments over time and cannot promise that indefinitely; a DVR that fails to
allocate a frame buffer after weeks of uptime is a dead product. Taking the
memory off Linux at boot, when contiguity is free, trades flexibility for a
guarantee. For a DVR that is the right trade — video is the product.

Allocations carry names that make the use obvious: `vb` (video buffer),
`AODMA`/`AIDMA` (audio out/in DMA), `VDA`, and a 5 MiB `jpeg` zone matching
the boot splash.

## The second bank is unclaimed by this port

This port declares one 512 MiB node in DDR0 and never touches DDR1. That is
512 MiB sitting idle, because nothing here runs a video pipeline.

Claiming it is not a one-line change. 1 GiB on ARM32 runs into the kernel's
address-space split: with the default 3G/1G user/kernel split, lowmem tops out
around 760 MiB, so a second bank needs either `CONFIG_HIGHMEM` or
`VMSPLIT_2G`. Untested as of this writing.

## Evidence

The DRAM parts are Nanya `NT5CB128M16` — 128M × 16 bits = 256 MB each. U1 and
U2 are visible on the top side; the electrical evidence above requires four,
so two more are presumably on the underside, which has not been photographed.
See `reference/board-chips.md`.

Memory above 256 MiB was proven real in U-Boot before any kernel change, and
the first attempt at this was unsound. Writing a four-word pattern and reading
it back proves nothing with the MMU on: four words is four cache lines inside
a 32 KB L1, so the read can be satisfied entirely from cache without the
transaction ever reaching DRAM. The valid test writes 512 KB to evict:

```text
mw.l 0x84000000 deadbeef 0x20000     # 512 KB, larger than L1
```

Then reading back at the high address confirms real storage. The wrap was
confirmed separately by writing at `0xa8000000` and observing the value appear
at `0x88000000`.

Validated after the change with 462 MiB pinned: a 450 MiB region checksummed
`41a5c18732255022b922da40ad5a7edb`, stable after 90 s and after a
20,000-packet flood at 0% loss. USB (`a9b9e693…`) and SATA (`78360580…`) reads
were identical across repeats with memory under pressure.

## Related

- `reference/board-chips.md` — what is physically fitted
- `reference/vendor-runtime-probe.md` — what the vendor kernel
  reports at runtime
- `investigation.md` — the bring-up narrative
