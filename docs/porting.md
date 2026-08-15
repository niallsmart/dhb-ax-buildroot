# Linux 6.18 LTS bring-up for the LTS LTD2704XE-P DVR

This document records the Linux 6.18.42 LTS port for the LTS LTD2704XE-P DVR,
built on a Shenzhen TVT `DHB_AX V1.2` motherboard around the HiSilicon Hi3531
(`godnet`) platform, replacing the vendor's Linux 3.0.8.

The board identifies itself as **`DHB_AX V1.2`**, silkscreened on the PCB.
That string appears nowhere in the vendor filesystem or kernel, so the board
revision is only knowable from the hardware itself. Filenames and device tree
nodes throughout use the hyphenated `dhb-ax`, which suits paths and DT naming;
the silkscreen text is the authority for what the board actually is.

Working and verified on hardware: both Cortex-A9 cores, 1 GiB of RAM, gigabit
Ethernet, SATA behind a port multiplier, USB host, all nineteen GPIO banks,
bit-banged I2C reaching the board's battery-backed clock, loadable modules,
NFS, and a software reset that returns to U-Boot without a power cycle. U-Boot
loads the normal kernel from a FAT32 USB drive and Linux mounts a writable ext4
root filesystem from the 1 TB SATA HDD.

Two device-tree variants build from the same tree:

- **minimal** — the original CPU, GIC, SP804 and PL011 bring-up description.
  It is retained as historical scaffolding, but the current external-root
  kernel needs the full device tree to reach its SATA root.
- **full** — the normal full-system image: both CPU cores, GMAC1 Ethernet,
  SATA behind a port multiplier, FAT32, all nineteen GPIO banks, bit-banged
  I2C with the board's real-time clock, loadable modules, USB and NFS.

The media hardware — capture, encode, decode, scaling, HDMI — is out of scope
throughout: undocumented, unsupported by mainline, and the bulk of what the
vendor loads. This port is a general-purpose ARM system on DVR hardware, not
a working DVR.

Nothing in this tree writes the DVR's SPI NOR or NAND. The USB drive and SATA
HDD were explicitly repurposed as Linux storage on 2026-08-14. Automatic boot
is not configured yet; the USB image is selected manually at U-Boot.

## Hardware source

The Hi3531 platform definitions came from OpenIPC's mirror of the HiSilicon
vendor-derived Linux 3.0.8 tree:

```text
repository: https://github.com/OpenIPC/linux.git
branch:     hisilicon-hi3520dv200-3.0.8
commit:     a3bfde54cdcf641cc061206f5d2ba6e9ddbad324
platform:   arch/arm/mach-godnet/
```

The branch contains multiple HiSilicon platforms. Its `mach-godnet/Kconfig`
explicitly identifies `godnet` as Hi3531. The platform addresses and interrupts
were checked against the running DVR's `/proc/iomem`, `/proc/interrupts`,
`/proc/cpuinfo`, and early boot log.

Important confirmed values used by the device trees:

| Block | Physical address | Interrupt/rate |
|---|---:|---:|
| RAM (DDR0) | `0x80000000` | 512 MiB; all of it used |
| RAM (DDR1) | `0xc0000000` | 512 MiB; all of it used, see `memory-map.md` |
| GIC CPU interface | `0x20300100` | — |
| GIC distributor | `0x20301000` | — |
| SP804 timer pair | `0x20000000` | GIC SPI 3 / 155 MHz |
| PL011 UART0 | `0x20080000` | GIC SPI 8 / 155 MHz |
| CRG | `0x20030000` | — |
| System controller | `0x20050000` | reset register at `+0x4` |
| GMAC/DMA/TNK block | `0x101c0000` | GIC SPI 87 |

## Ethernet hardware layout

The board has two DWMAC1000 MACs sharing one MDIO block, one three-channel
DMA and one interrupt aggregator, with a single external Realtek PHY at MDIO
address 1 wired to GMAC1:

```text
shared MDIO and register base   0x101c0000
GMAC0 control registers         base + 0x0000
GMAC1 control registers         base + 0x4000
DMA channel n                   base + 0x1000 + n * 0x100
TNK interrupt aggregator        base + 0x9000
```

The vendor source for this driver is available and is the better reference:
`drivers/net/stmmac/` in the OpenIPC tree named under "Hardware source"
(clone it locally; it also carries the TNK/TOE sources this port ignores).
Its `stmmac_dvr_probe()` states the register layout outright:

```c
/*  GMAC1 CTRL registers are at offset 0x4000 */
priv->ioaddr = stmmac_base_ioaddr + (i * 0x4000);
priv->dma_channel = i;
/*  DMA access for both MACs is via GMAC 0 register space */
priv->dma_ioaddr = stmmac_base_ioaddr;
/*  MDIO access for both MACs is via GMAC 0 register space */
priv->mii_ioaddr = stmmac_base_ioaddr;
```

That is the same three-window split this port implements, and it confirms
MAC *n* is paired with DMA channel *n*. Their `stmmac_reset()` loops all
three channels writing the software-reset bit at
`base + channel * 0x100`, which is what the glue does at probe;
`reset_mac_interface_dual()` is the interface reset/config/readback/release
sequence in `fix_mac_speed`; `mdio_clk_init()` returns half the bus clock,
so 310/2 = 155 MHz, which `get_clk_csr()` maps to index 4 — the same
`STMMAC_CSR_150_250M` mainline derives from the device tree clock. Their
`dwmac_dma_flush_tx_fifo()` takes a channel index for exactly the reason
patch 0005 exists.

The values below were originally recovered from the vendor `stmmac.ko`
(`rootfs/hitoe/stmmac.ko`) before that source was to hand, and the source
has since confirmed each one:

| Value | Where it comes from in the vendor binary |
|---|---|
| MAC*n* at base + *n* × `0x4000` | `stmmac_dvr_probe`: `add r4, r0, r4, lsl #14` |
| DMA channels at `+0x1000`, `+0x1100`, `+0x1200` | probe resets each in turn, stopping at `0x1300` |
| IRQ 119, i.e. GIC SPI 87 | `mov r0, #119` before `request_irq`, stored to `dev->irq` |
| Aggregator status `0x9000`, enable `0x9004` | probe writes `0xffffffff` to `+0x9004`; remove writes 0 |
| DMA channel *n* → bit 2 + *n*, MAC *n* → bit 5 + *n* | vendor ISR gates dev0 on `0x24`, dev1 on `0x48` |
| CRG `0xc8` interface reset, `0xec` mode/speed | `stmmac_adjust_link` write sequence |
| Field shift 16 and mask `0xffff` for MAC 1 | `movne r1, #16`; `movw r2, #0xffff` |
| Speed 10 = `0x1`, 100 = `0x3`, 1000 = `0` | `moveq r9, #1` / `moveq r9, #3` / `movne r9, #0` |
| LINK + TX enable, full duplex, RGMII bits | `orr r9, #12`, `orrne r9, #16`, `orreq r9, #32` |

The restart register was taken from the vendor's own `arch_reset()` rather
than from the binary; see the restart section below.

## How the shared block is driven

A stock one-queue stmmac instance drives hardware channel 1. Three register
windows have to be told apart, which mainline assumes are all the same:

- `priv->ioaddr` — the resource base, kept at offset 0 so the generic MDIO
  code keeps using the shared MDIO window.
- `mac_device_info::pcsr` — GMAC1's control registers at `+0x4000`.
- `priv->dmaaddr` — channel 1's DMA registers, `+0x100` from the DMA base.

Patches 0004, 0005 and 0006 make the core honour those three separately. The
vendor TNK/TOE acceleration engine is not used.

The glue also resets all three DMA channels at probe, mirroring the vendor
driver. The SoC reset register does not clear this block, so a kernel started
by a warm restart inherits whatever the previous kernel left running.
Resetting only the channel this instance owns is not enough: the receive
engine comes up wedged, reporting descriptors unavailable with a
`CUR_HOST_RX_DESC` that never latches, and stays that way until the interface
is taken down and brought back up. This only became reachable once the board
had a working soft reset.

## Files

- `../br2-external/board/dhb_ax/dts/hisilicon/hi3531-dhb-ax.dtsi`: shared board
  description.
- `../br2-external/board/dhb_ax/dts/hisilicon/hi3531-dhb-ax.dts`: minimal
  variant.
- `../br2-external/board/dhb_ax/dts/hisilicon/hi3531-dhb-ax-full.dts`: full
  validated hardware description.
- `../br2-external/board/dhb_ax/patches/linux/`: the patch queue, applied in
  order. Three patches add a glue driver as a new file alongside the Kconfig
  and Makefile entries that build it, so a driver and its build wiring cannot
  drift apart:
  - `0003`: `dwmac-hi3531.c`, DWMAC glue for the shared MDIO/DMA integration.
  - `0007`: `ahci_hi3531.c`, AHCI glue; clock, reset and PHY bring-up.
  - `0009`: `phy-hi3531-usb.c`, USB 2.0 PHY; clock and reset bring-up.

  To change a driver, edit it in the kernel build tree and regenerate the
  patch; do not add a separate source copy outside the patch queue.
- `reference/vendor-runtime-probe.md`: read-only capture of the stock
  firmware's `/proc`, and the authoritative record of what this board runs.
- `reference/board-chips.md`: part numbers read off the PCB, and the
  authoritative record of what is physically fitted.

The pre-Buildroot build machinery was retired at Stage 6 of
`buildroot-migration-plan.md`. What it did is now Buildroot's job:

| Was | Is now |
|---|---|
| `configs/dhb_ax_*.config` | `../br2-external/board/dhb_ax/linux.config` |
| `initramfs/init*` | `../br2-external/board/dhb_ax/rootfs-overlay/init` |
| `Dockerfile`, `build.sh`, `scripts/build-in-container.sh` | `../scripts/` |
| `scripts/bootstrap-sources.sh` | `../scripts/bootstrap-sources.sh` |
| the device trees and the patch queue | `../br2-external/board/dhb_ax/` |

Port documentation and evidence now live under `docs/`; maintained board
support lives under `../br2-external/`.

Patch queue, applied in numeric order:

| Patch | What it does |
|---|---|
| 0001 | build both DHB-AX DTBs |
| 0002 | select the 155 MHz APB UART clock during early OF clock init |
| 0003 | `DWMAC_HI3531` Kconfig symbol and Makefile entry |
| 0004 | address the MAC block through `pcsr` |
| 0005 | per-instance DMA register base (`priv->dmaaddr`) |
| 0006 | derive the PTP and MMC bases from the MAC block |
| 0007 | `AHCI_HI3531` Kconfig symbol and Makefile entry |
| 0008 | do not register a PL061 irqchip when no parent interrupt exists |
| 0009 | `PHY_HI3531_USB` Kconfig symbol and Makefile entry |

All of these are local hardware-enablement changes, marked `[LOCAL ONLY]`,
and are not in submittable shape.

Both DTBs are added in a single hunk on purpose. Split across two patches,
neither could apply nor reverse-apply once the other was in the tree, which
broke the second build against the same source.

## Build

```sh
scripts/bootstrap-sources.sh    # fetch sources, once
scripts/buildroot.sh            # configure and build
```

Bootstrapping is idempotent and only fetches what is missing. It produces
three things under the workspace, none needing backup because all of it is
reproducible from two pinned inputs:

```text
kernel/linux-6.18.42.tar.xz      official upstream tarball
kernel/linux-6.18.42-pristine/   never modified; the patch queue is diffed
                                 against this
buildroot/buildroot-2026.02.3/   verified against its signed sha256
```

Buildroot extracts and patches its own copy of the kernel every build, so
there is no persistent build tree and no reverse-apply idempotency check. A
tree carrying a superseded patch is no longer a failure mode that exists.

Patches are applied with `patch -F0`, zero fuzz. Anything that only applies
with fuzz is a broken patch, and will be rejected rather than quietly slid
into place — which is how a real defect in patch 0002 was found.

Object files and the whole Buildroot output tree live in Docker named
volumes, not the bind-mounted workspace, which on macOS is much faster. The
volumes persist between runs: a rebuild after no change takes seconds rather
than rebuilding the toolchain. `scripts/buildroot.sh --clean` discards them.

Finished artifacts land in the repository-root `artifacts/buildroot/`:

```text
uImage-hi3531-dhb-ax-full               U-Boot-ready image
zImage                                  bare zImage
hi3531-dhb-ax-full.dtb                  device tree blob
rootfs.tar                              userspace installed on the SATA root;
                                        also usable for an NFS recovery root
```

The U-Boot-ready result is a legacy ARM `uImage` loaded and entered at
`0x80008000`. Its payload is an ARM `zImage` with the DTB appended, allowing
the old U-Boot to continue passing ATAGs without needing explicit FDT
commands. `br2-external/board/dhb_ax/post-image.sh` does that wrapping;
Buildroot's own `BR2_LINUX_KERNEL_APPENDED_UIMAGE` cannot be used here, for
reasons recorded in that script. Whole-file hashes are not reproducible: the
legacy image header carries a build timestamp. The current full DTB is
reproducible with SHA-256
`2470b0f971e305904211f05192fb31183c41682fdcefcef6e703398f33c28afc`.

To change a driver or the device tree, edit it under
`br2-external/board/dhb_ax/` and rebuild. To change a patch, regenerate it
against `kernel/linux-6.18.42-pristine/`.

## Verified RAM boot

Linux 6.18.42 booted successfully from DRAM on 2026-08-03 and entered the
built-in BusyBox shell. No persistent U-Boot environment, NAND, or SPI NOR
writes were made.

The old U-Boot leaves UART0 on a roughly 3 MHz source. Read-only U-Boot probes
showed `CRG_E4=0x0000e060`, `IBRD=1`, and `FBRD=40`. PLL registers
`CRG0=0x09000000`, `CRG1=0x006c209b`, and bus-scale register `0x23` confirm a
310 MHz system bus and 155 MHz peripheral clock. The vendor 3.0.8 platform code
clears CRG bit 13 before PL011 registration; patch 0002 performs the same
volatile selection early enough for the modern console handoff.

The SP804 block was also captured before boot. U-Boot left timer channel 0
running with `LOAD=0xffffffff`, a decreasing `VALUE`, and `CONTROL=0xca`;
channel 1 had `CONTROL=0x20` and was disabled.

Runtime validation showed:

```text
Linux (none) 6.18.42 ... armv7l GNU/Linux
16: ... GIC-0 35 Level timer
17: ... GIC-0 40 Level uart-pl011
```

Only `rootfs`, `devtmpfs`, `proc`, and `sysfs` were mounted. `/proc/iomem`
contained the SP804, PL011, and `0x80000000-0x8dffffff` system RAM; no flash
controller or flash filesystem was enabled.

## Booting an image

The normal manual boot loads the installed USB image. The helper handles the
fast autoboot interruption and does not save any environment variables:

```sh
tools/dvr-boot.exp --usb
```

The equivalent commands at the U-Boot prompt are:

```text
setenv bootargs console=ttyAMA0,115200 earlycon=pl011,0x20080000 keep_bootcon ignore_loglevel mem=512M@0x80000000 mem=512M@0xc0000000
setenv bootargs ${bootargs} root=PARTUUID=ca264b64-5738-4e60-a0ab-b3c3a4c789c1 rootfstype=ext4 rootwait rw
usb reset
fatload usb 0:1 0x82000000 uImage
bootm 0x82000000
```

The split keeps each input line below the old U-Boot console-buffer limit.
`dvr-boot.exp` reads `bootargs` back and compares the complete value before it
loads or boots an image.

The first verified boot read 3,542,217 bytes from FAT32, discovered the WDC
disk through the JMicron port multiplier, and mounted
`PARTUUID=ca264b64-5738-4e60-a0ab-b3c3a4c789c1` as writable ext4. Buildroot
then obtained `192.168.4.77` by DHCP and started OpenSSH. The root filesystem
reported 915.8 GiB available. SATA, SCSI disk, GPT and ext4 support are built
into the kernel; they are available before the root filesystem and do not
depend on `insmod`.

For TFTP development or recovery, the original procedure remains available:

Stage the image in the Pi's TFTP root and start the temporary TFTP server.
Cold-reset the DVR and interrupt autoboot, recheck the Pi address, then set
only volatile environment values:

```text
setenv ipaddr 192.168.7.241
setenv netmask 255.255.252.0
setenv serverip 192.168.4.34
setenv ethaddr 00:18:AE:3C:A2:49
setenv bootargs console=ttyAMA0,115200 earlycon=pl011,0x20080000 keep_bootcon ignore_loglevel mem=512M@0x80000000 mem=512M@0xc0000000
setenv bootargs ${bootargs} root=/dev/nfs nfsroot=192.168.4.34:/srv/dhb-ax/rootfs,vers=3,tcp,nolock ip=::::dhb-ax:eth0:dhcp rw
tftp 0x82000000 uImage-hi3531-dhb-ax-full
bootm 0x82000000
```

Loading and root selection are independent. `tools/dvr-boot.exp --usb --root
nfs` loads the installed USB kernel but mounts the Pi's NFS export, which is
useful when U-Boot Ethernet is unavailable after a warm restart. USB defaults
to the HDD root; TFTP defaults to the NFS root.

`ping` is deliberately absent from that sequence: it has crashed this U-Boot
mid-session. Go straight to `tftp`, which reports its own errors.

On this vendor U-Boot, the two-argument `tftp <address> <filename>` form is the
normal download; the three-argument form with an explicit size is the vendor's
upload extension. `iminfo` is unavailable, so the transfer byte count must
match the staged file exactly before `bootm`.

Do not use `saveenv`, `nand write`, `nand erase`, `sf write`, `sf erase`, or any
other persistent-write command.

To get back to U-Boot for another image, `echo b > /proc/sysrq-trigger` and
interrupt autoboot. Autoboot has to be interrupted *densely* — Enter every
0.2 s from the moment of reset — or the vendor system boots instead. If it
does, log in as `root` / `1001chin` on the console (or over telnet) and
`reboot`.

If the kernel panics rather than reaching a shell, sysrq over the serial
console still works: send a BREAK, then `b`. In picocom that is `C-a C-\`
followed by `b`.

## Verified Ethernet bring-up

The full image booted from DRAM on 2026-08-03 and passed Ethernet traffic. Full
console log in `../artifacts/legacy/boot-log-ethernet-r2.txt`. What the hardware
confirmed:

```text
GMAC0 ver=00001036 GMAC1 ver=00001036 TNK id=000100ff stat=00000000
CRG cc=0000000a interface reset=00000000 config=003c003c
TNK interrupt enable 0000000c -> 00000048
PHY [stmmac-0:01] driver [RTL8211B Gigabit Ethernet] (irq=POLL)
GMAC1 RGMII speed 1000, syscfg 003c003c -> 003c003c
eth0: Link is Up - 1Gbps/Full - flow control rx/tx
```

- Both MAC blocks answer, so GMAC1 at `+0x4000` is addressed correctly.
- `CRG cc` bit 4 is clear, so MDIO runs from the PLL source the device tree
  assumes and the alternate-clock warning correctly stays quiet.
- U-Boot leaves `0x0c` in the aggregator mask, so the old OR-ing behaviour
  would have produced `0x4c` and left GMAC0's DMA channel 0 interrupt
  enabled. Writing the mask outright yields exactly `0x48`.
- MDIO through the shared window reaches the PHY at address 1.
- IRQ 119 (GIC SPI 87) appears as `18: ... GIC-0 119 Level eth0` and is
  serviced normally, with no spurious-interrupt storm.

Channel ownership read back with `devmem` while the link was up:

```text
0x101c100c 0x00000000     channel 0 RX list   (untouched)
0x101c1010 0x00000000     channel 0 TX list   (untouched)
0x101c110c 0x80FB8000     channel 1 RX list
0x101c1110 0x80FC0000     channel 1 TX list
0x101c1118 0x03202906     channel 1 op mode, RX/TX started, store-and-forward
```

Only channel 1 is driven, which is what patch 0006 exists to guarantee: the
TX FIFO flush on the descriptor error path now lands on `0x101c1118` rather
than channel 0's `0x101c1018`.

Floods of 1472-byte payloads from the Pi ran with no loss, both on a
cold-booted board and after a warm restart:

```text
20000 packets transmitted, 20000 received, 0% packet loss, time 33069ms
15000 packets transmitted, 15000 received, 0% packet loss, time 24897ms
RX packets:20937 errors:0 dropped:78 overruns:0 frame:0
TX packets:20184 errors:0 dropped:0 overruns:0 carrier:0
```

Two full warm-restart cycles — `sysrq-b`, interrupt autoboot, TFTP, `bootm`,
`ifconfig up` — each reached the network on the first interface up.

Patch 0006 is correct but latent on this board: with no usable feature
register the driver reports "No MAC Management Counters available" and "PTP
not supported by HW", so neither block is touched at runtime.

## Restart method

`sysrq-b` and any kernel restart go through the stock `hisi-reboot` driver,
which writes `0xdeadbeef` to the system controller's reset register:

```text
system-controller@20050000  compatible = "hisilicon,sysctrl"
                            reboot-offset = <0x4>
```

The vendor 3.0.8 `arch_reset()` writes `~0` to `SYS_CTRL_BASE +
REG_SC_SYSRES`, which its `include/mach/platform.h` defines as `0x20050000 +
0x4`. Confirmed on hardware twice over: from U-Boot with
`mw.l 0x20050004 0xdeadbeef 1`, which resets the SoC immediately, and from a
booted kernel with `echo b > /proc/sysrq-trigger`, which resets and lands
back in U-Boot. The value mainline already writes is accepted, so no driver
patch is needed.

An earlier revision of this tree tried to reset through the watchdog at
`0x20040000`, clearing bit 23 of `0x20050000`. That does not work: it hangs
the CPU in the restart handler and needs a power cycle. It was wrong on every
count — the reset register is at offset 4, which the old node's 4-byte
mapping did not even cover, and the `bic #0x00800000` found in the vendor
`wdt.ko` is watchdog housekeeping unrelated to resetting the SoC. The
watchdog patch has been removed.

Note that BusyBox `reboot` still does nothing here: it signals PID 1, which
in this initramfs is the shell. Use `echo b > /proc/sysrq-trigger`.

## What this tree deliberately does not do

- **No clock or reset management.** The `stmmaceth` clock in the device tree is
  a `fixed-clock`, so enabling it does nothing to the hardware. The driver
  relies on the boot loader having released the GMAC/TOE block, exactly as the
  vendor module does. It logs CRG `0xcc` at probe and warns when the bit the
  vendor uses to select a roughly 1 MHz MDIO clock is set.
- **No TX checksum offload, and therefore no forced TX store-and-forward.**
  The `snps,dwmac-3.40a` compatible turns COE on, but this integration reports
  no usable feature register, so nothing confirms the engine exists. The glue
  forces `tx_coe = 0`.

  These two are coupled, and getting the pair wrong wedges the hardware. The
  vendor enables TX store-and-forward *only* on the COE path and otherwise
  runs TX in threshold mode with RX store-and-forward. Mainline selects the
  same way (`force_sf_dma_mode || tx_coe`), so with COE off the device tree
  must not carry `snps,force_sf_dma_mode`. If TX COE is ever enabled after
  measurement, mainline will pick store-and-forward on its own, which is the
  configuration the vendor uses in that case. See the TX wedge note below.
- **`phy-mode = "rgmii"`**, no delay. This matches the vendor, which programs
  no PHY delays, so the PHY's delays must be strapped in hardware. If the
  link comes up but no traffic passes, `rgmii-id` is the first thing to try.

## The TX store-and-forward wedge

Forcing TX store-and-forward while TX checksum insertion is disabled wedges
the transmit DMA. It survives light traffic and fails once a single burst
exceeds roughly four MTU-sized frames:

```text
ping payload 1400 / 2000 / 4000    pass
ping payload 8000 / 16000 / 65000  wedge
```

Once wedged the whole interface is dead, not just large frames, and
`ifconfig down`/`up` does not recover it; only a reset does. `DMA_STATUS`
reads `0x003E0000` — transmit process state 3, "reading data from host
memory" — with no underflow, no bus error, and no transmit timeout, so the
driver never notices.

This hid for a long time because every earlier test was ICMP echo *replies*
driven by a flood from the Pi: the board only ever transmitted one frame at a
time, paced by arrivals. Nothing made the board burst until an NFS write did.

The fix is to leave `snps,force_sf_dma_mode` out of the device tree, which
puts TX in threshold mode at 64 bytes with RX store-and-forward, matching the
vendor. Confirmed by `OP_MODE 0x02002902` (TSF clear, RSF set), the full size
walk above passing, a 4 MiB NFS write arriving with a matching MD5, and a
20000-packet flood at 0% loss.

Note that the FIFO depths in the device tree are *not* involved: dwmac1000
ignores the FIFO size when programming the DMA operation mode.

## SATA

The controller is a stock AHCI 1.2 block with two ports at `0x10080000`
(`SATA_BASE` in the vendor `mach-godnet/include/mach/platform.h`), reached
through GIC SPI 36. It comes out of chip reset with its clocks gated and its
PHY unconfigured, so `ahci_hi3531.c` (patch 0007) reproduces the vendor
`hi_sata_init()`: enable the three SATA clocks in CRG `0x200300b4`, select
the PHY clock, apply the port erratum, release the controller and PHY
resets, program both PHYs, the OOB timing and the per-port PHY config, then
toggle the PHY and release the lane resets.

Only one drive port is wired: **a JMicron JMB321 port multiplier sits on
controller port 1**, fanning out to five drive slots. `CONFIG_SATA_PMP` is
therefore mandatory, not optional.

The board is laid out for ten drives — two controller ports, each behind a
five-port multiplier — but only one multiplier is fitted, and only two of the
ten SATA connectors are soldered. See `reference/board-chips.md`: the
silkscreen mapping accounts for every link-up and link-down libata reports,
and identifies which multiplier ports can be skipped safely at probe time.

Every register the glue programs was checked against the vendor kernel while
it was running and mounting the disk, and they match exactly:

```text
                    vendor      this port
CRG 0xb4            0x00000700  0x00000700
GHC                 0x80000002  0x80000002
port1 +0x44         0x00000724  0x00000724   erratum, "fetch bypass"
port1 +0x74         0x0E262709  0x0E262709   PHY config, 1.5 Gbps
```

Verified on 2026-08-03 with a WD10EURX attached to multiplier port 2:

```text
ata2.15: Port Multiplier 1.2, 0x197b:0x0325 r0, 5 ports, feat 0x5/0xf
ata2.02: ATA-9: WDC WD10EURX-63C57Y0, 01.01A01, max UDMA/133
ata2.02: 1953525168 sectors, multi 0: LBA48 NCQ (depth 32)
sda: sda1 sda2 sda3 sda4
```

256 MiB read at roughly 128 MB/s, which is close to the 1.5 Gbps line rate,
with no I/O errors and 302 interrupts delivered — the latter also confirming
the interrupt number, which had been inferred rather than read from a header.
The only error-shaped log lines are `hard resetting link` and `failed to
resume link` for the four empty multiplier slots, which are expected.

Those results describe the original recording layout. On 2026-08-14 the owner
explicitly approved destroying it: the disk was repartitioned as GPT with one
full-capacity Linux partition and formatted ext4 for the Buildroot root.

### Populating the unused drive bays — notes, not yet acted on

The board has ten SATA positions and two fitted connectors. Whether the other
three ports on the *fitted* multiplier could be brought into use was assessed
from photographs (`pcb/PCB.heic`); this records the conclusion so it does not
have to be re-derived.

**What is missing.** Every unpopulated position lacks *both* the connector and
its AC coupling capacitors. The cap pads are bare throughout: `C539`, `C542`,
`C546`, `C561` at SATA1/2; `C359`, `C360` at SATA5/6; `C242`, `C243`, `C249`,
`C251`, `C549`, `C550`, `C560`, `C562` at SATA7/8; `C541`, `C544`, `C552`,
`C563`, `C543`, `C547`, `C556`, `C558` at SATA9/10. The capacitors are not
optional — SATA requires series AC coupling on the differential pairs, and a
link will not train without them.

Two useful negatives: nothing *else* around those footprints is unpopulated —
no missing ESD arrays or termination networks — and the footprints are intact
and tinned. The BOM difference between board variants looks like exactly
"connectors plus capacitors".

Each position appears to carry four capacitor pads in two groups of two,
implying both differential pairs are coupled. Confirm by counting the caps on
a fitted port rather than trusting a photograph; likewise read the value off a
fitted one, though SATA coupling caps are typically 10 nF.

**So the work would be** roughly three connectors and twelve capacitors, all
standard hand-solderable parts — *if* two assumptions hold.

**Assumption 1: the port mapping.** SATA *n* maps to multiplier port *n-1*.
This reproduces every link-up and link-down libata reports, but it is an
inference. A plausible alternative is that the two multipliers were intended
to split the positions odd/even, in which case some of SATA1, SATA2 and SATA5
belong to the multiplier that is *not* fitted, and populating them would
achieve nothing.

*Test, and it is free:* put a drive in the empty fitted connector, SATA4. If
it enumerates as `ata2.03` the mapping is confirmed. This uses hardware
already to hand and needs no rework.

**Assumption 2: the differential pairs are routed.** Pads and silkscreen
exist, which strongly suggests a shared PCB across variants with only the BOM
differing — the usual arrangement — but the traces are on inner layers and no
photograph can settle it.

*Test:* because the capacitors sit in series, check continuity in two hops —
JMB321 pin to the near-side cap pad, then the far-side cap pad to the matching
connector pin. Both continuous means the port is wired and only components are
missing. The first hop failing means that port was never routed.

**Payoff, and its ceiling.** All five ports share one link to the SoC,
currently negotiated at 1.5 Gbps, so roughly 150 MB/s across every drive
attached. Ample for sequential recording, a real constraint otherwise. Note
this port hardcodes 1.5 Gbps only because the vendor does; their source
carries 3 Gbps constants behind a `mode_3g` parameter
(`CONFIG_HI_SATA_PHY0_CTLL_3G_VAL`, `CONFIG_HI_SATA_3G_PHY_CONFIG`), so
doubling the link is a two-constant change testable on its own, without any
soldering.

Adding the *second* multiplier to reach ten drives is a different and much
larger job: a whole additional chip plus its support circuitry, which is why
`ata1` reports link down today. Not assessed.

### Original filesystem (historical)

The four original partitions really were FAT32, not just the type byte: the boot
sector carries the standard `EB 58 90` jump, an OEM name of `MSDOS5.0` and
`FAT32   ` at offset 82. FAT32 has no journal, so a read-only mount cannot
replay anything, which makes `-o ro` genuinely read-only here.

All four mounted and read correctly before they were intentionally erased:

```text
sda1..sda4   232.8G, 99% full, vfat ro
```

Each holds a flat set of 512 MiB `NNNNNNNN.dat` recording chunks plus
`PictMan.dat`, `diskver`, `eventlog.bin`, `operlog.bin` and `reclog.bin`.
The chunks are a TVT container, not raw video: they begin `FHDR` and carry
`FTVT` at offset 12.

Extraction to the Pi over NFS is verified byte-for-byte — 32 MiB read from a
chunk and written to the share produced the same MD5 computed on the DVR and
on the Pi, with no I/O errors.

Two traps worth knowing:

- **`vfat` needs `/sbin/modprobe`.** The mount pulls in its NLS codepage
  through `request_module()`, which runs `/sbin/modprobe` — not
  `/bin/modprobe`. Without that path the mount fails with `EINVAL` and
  *nothing is logged*, because it fails before the filesystem driver starts.
  The initramfs now creates the symlink.
- **`ls` and `find` report "Value too large for defined data type"** for most
  chunks and omit them, so a listing shows only a handful of entries.

  The cause is the **2038 problem**, not file size and not the inode number.
  Reading the raw FAT directory entries shows every pre-created chunk carries
  a placeholder write date of `0xEC21`, which decodes to 1 January 2098:

  ```text
  00000041.DAT  size 0x20000000 (512 MiB)  WrtDate 0xEC21 -> 2098-01-01
  normals.bin   size 0x00100000 (1 MiB)    WrtDate 0xEC21 -> 2098-01-01
  00000462.dat  size 0x20000000 (512 MiB)  real date 2015 -> stats fine
  ```

  A signed 32-bit `time_t` ends on 19 January 2038, so glibc's `stat` wrapper
  refuses the conversion and returns `EOVERFLOW`. The kernel is not involved:
  `cp_new_stat()` truncates timestamps silently, and `i_ino` is `unsigned
  long`, so on a 32-bit kernel the inode number cannot overflow at all.

  Note that **`_FILE_OFFSET_BITS=64` (large file support) does not fix this** —
  that covers sizes and offsets. Timestamps need `_TIME_BITS=64`, which
  requires a libc built for it. Debian's armhf time64 transition landed in
  trixie, and the BusyBox here comes from bookworm. Taking BusyBox from a
  trixie `.deb` would fix the listings.

  Data access is unaffected either way: `open` and `read` never look at
  timestamps, which is why `dd` reads these files and the extraction checksums
  match.

### Recovering a wedged board

In order of preference:

1. `echo b > /proc/sysrq-trigger` — needs a responsive shell.
2. **Serial BREAK, then a sysrq key.** In picocom that is `C-a C-\` then the
   key. `b` resets, and `w` (blocked tasks) or `t` (all tasks) will say
   *where* it is stuck before you throw the state away. This works when the
   shell is blocked in uninterruptible I/O, which is the usual filesystem
   failure. It needs `CONFIG_MAGIC_SYSRQ_SERIAL`, which the seed originally
   dropped.
3. Power cycle.

The SP805 watchdog is present and its clock is now described correctly, but
**it does not currently reset the SoC** — see below.

### The L2 cache — notes, not yet acted on

The L2 cache at `0x20700000` is off under this port. Enabling it is a real
piece of work, not a device tree node, and this records what was learned so it
does not have to be re-derived.

**It is not a PL310.** It is a HiSilicon proprietary controller with its own
driver in the vendor tree, `arch/arm/mm/cache-hil2v200.c` (385 lines plus a
207-line header). The register map differs completely from ARM's:

| Offset | HIL2V200 | PL310, for contrast |
|---|---|---|
| `0x000` | `L2_CTRL` | Cache ID |
| `0x004` | `L2_AUCTRL` | Cache Type |
| `0x008` | `L2_STATUS` | — |
| `0x100` | `L2_INTMASK` | Control |
| `0x200` | `L2_SYNC` | — |
| `0x210` / `0x214` | `L2_INVALID` / `L2_CLEAN` | — |

Two consequences. First, reading `0x20700000` and finding zero does **not**
mean a missing cache ID — it is the control register correctly reporting
disabled. An earlier revision of these notes drew that wrong conclusion by
assuming a PL310. Second, `0x004` reading `0x01800000` is a live auxiliary
configuration value, so the block is present and answering.

**The vendor does enable it.** `godnet_defconfig` carries
`CONFIG_CACHE_HIL2V200=y`, which is what claims `l2cache.0` in the vendor's
`/proc/iomem` and what the three L2 error interrupts (SPI 37-39) belong to.
An earlier note here claimed the vendor had no L2 init; that came from
grepping only `arch/arm/mach-godnet/`, while the driver lives in
`arch/arm/mm/`.

**Mainline has nothing for this controller.** The only outer-cache
implementation remaining in 6.18 is `cache-l2x0.c`, for ARM's own designs.

### What porting it would involve

The `outer_cache_fns` interface the vendor hooks into still exists in 6.18
with the same shape, so the port is structurally feasible:

```c
outer_cache.inv_range   = l2cache_inv_range;
outer_cache.clean_range = l2cache_clean_range;
outer_cache.flush_range = l2cache_flush_range;
outer_cache.sync        = l2cache_sync;
outer_cache.disable     = l2cache_disable;
```

Two mismatches to resolve: the vendor also sets `flush_all` and `inv_all`,
and neither is a member of the 6.18 `struct outer_cache_fns`. Those call sites
need rework rather than translation.

### Why this is riskier than anything else in this tree

Every function above is cache maintenance, and cache maintenance bugs do not
announce themselves. A missed flush on a DMA path means Ethernet delivers
subtly wrong bytes or SATA writes corrupt data, with no error reported
anywhere. Every other subsystem here fails visibly; this one fails silently.

It also interacts with SMP, which this port now enables — both cores share the
L2.

### If it is attempted

1. **Measure first.** Nothing has established that this board is memory-bound,
   so the size of the win is currently an assumption. A memory-heavy benchmark
   before and after would make it a number. A network and storage box is often
   I/O-bound, in which case L2 may buy little.
2. **Detach anything valuable from SATA.** The disk normally attached holds
   the owner's recordings.
3. **Validate with checksums, not just "it boots".** The NFS transfer with an
   MD5 compared on both ends, already used for the filesystem work, is exactly
   the right tool because it detects silent corruption.

### The watchdog does not reset yet

`CONFIG_ARM_SP805_WATCHDOG` builds and binds, and with the corrected 3 MHz
clock the driver programs a real 30 s per stage instead of clamping. Opening
`/dev/watchdog` and not petting it does expire the first stage (`RIS` becomes
1), but the second expiry never resets the SoC.

The missing piece is almost certainly reset *routing*: the vendor `wdt.ko`
clears bit 23 of a register reached through a separate mapping, which was
dismissed earlier as unrelated once the sysctrl software reset was found.
The register is not in `0x20050000`, and the vendor's `hidog` source is not
in the OpenIPC tree, so finding it needs more work on the binary.

Until then the serial BREAK above is the safety net.

### Two traps in the Kconfig seed

The build starts from `allnoconfig` plus the seed file, so **any symbol not
named in the seed is off, including ones mainline defaults to `y`**. This has
now cost several debugging sessions: `CONFIG_BLOCK`; `CONFIG_SATA_PMP`, whose
absence made a healthy drive look like a dead one for an hour;
`CONFIG_MAGIC_SYSRQ_SERIAL`, which left no way to recover a wedged board; and
`CONFIG_WATCHDOG_SYSFS`. When a
subsystem behaves as though hardware is missing, check the generated
`config-*` artifact before suspecting the hardware.

## What this board actually has

`reference/vendor-runtime-probe.md` records a read-only inspection of the stock
firmware's `/proc`, captured 2026-08-04. It is the authoritative statement of
this board's hardware, and it corrects assumptions the reference source tree
alone would leave standing:

- **The SoC is dual-core.** The vendor kernel schedules two Cortex-A9s. This
  port originally declared one CPU and built `CONFIG_SMP=n`, using half the
  machine; the probe is what revealed it, and both cores now run.
- **The board is multi-SoC.** The two PCIe endpoints are further Hi3531 chips
  (`19e5:3531`), which is what the cascade/host/slave modules in the vendor
  rootfs are for.
- **USB runs on stock mainline drivers** under a thin `hiusb-*` platform
  wrapper — the same shape as the AHCI glue here, so the work is a clock and
  PHY init step, not a driver.
- **SD/MMC is real and wired** (`hi_mci` at `0x10020000`, SPI 35), which the
  `sd` mount point in the vendor rootfs corroborates.
- Both interrupt numbers this port had *inferred* rather than read — SATA
  SPI 36 and GMAC SPI 87 — are confirmed correct.

It also resolves the two blocks that read all zeros during PrimeCell ID
probing: DMA is real but clock-gated, and the hardware I2C is genuinely unused
because the vendor bit-bangs I2C over GPIO instead.

Photographs of the board (`reference/board-chips.md`) then added what no
software source could:

- **A Lattice ECP3-17EA FPGA**, which accounts for the otherwise unexplained
  `fpga_jtag.ko` in the vendor rootfs.
- **An Atmel AT89S52**, an 8051 microcontroller running its own firmware. It
  is almost certainly what UART1 talks to — that port carried traffic under
  the vendor firmware while UART2 carried none.
- Corrections to two part numbers this tree had inferred rather than read:
  the port multiplier is a **JMB321**, and the Ethernet PHY is an
  **RTL8211CL** that reports the RTL8211B ID and so binds to the B driver,
  missing a gigabit-slave-mode quirk. Both are recorded there in full.

### Enumerating hardware: five sources, not one

No single source is sufficient, and each fails in a way the others catch.

| Source | Answers | Fails by |
|---|---|---|
| OpenIPC 3.0.8 tree | what the SoC family contains | describing a reference platform, not this board |
| Vendor kernel + rootfs | what TVT actually built and drove | understating hardware that exists but went unused |
| Runtime `/proc` on stock firmware | what is really wired, with IRQs | needing the original firmware bootable |
| PrimeCell ID registers | what a block *is* | silent when a clock is gated |
| The PCB itself | what is physically fitted | needs the case open, and worn markings |

The last one is worth the trouble because the vendor kernel contains no
`pl061`, `pl022` or `pl031` code at all — TVT wrote their own — yet the
hardware reports exactly those part numbers. Consulting only the vendor kernel
would have led to writing drivers that already exist in mainline.

## Memory: the board has 512 MiB, not 256

The device tree declared 256 MiB and reserved 32 of it, leaving the kernel
216 MiB. The board actually carries **512 MiB** and the port now uses all of it:

```text
Memory: 511012K/524288K available (12208K reserved)
MemTotal: 513148 kB          ~501 MiB after kernel overhead
80000000-9fffffff : System RAM    one contiguous region
```

524288K is exactly 512 MiB. About 12 MiB goes to the kernel image, the
`struct page` array and early reservations before the allocator sees it.

### How it was established

Two Nanya `NT5CB128M16` packages are fitted, at U1 and U2 either side of the
SoC. Each is 128M x 16 bits = 2 Gbit = 256 MB, so 512 MB in the usual two-x16
arrangement giving a 32-bit bus.

Probing confirmed it, and the first attempt was unsound in a way worth
recording. Writing distinct patterns to a handful of addresses and reading
them back proves little: with the MMU on, four words are four cache lines and
the test may never reach DRAM at all. The reads must be forced out of cache:

```text
mw.l 0x9f000000 44444444
mw.l 0x84000000 deadbeef 0x20000    512 KiB, 16x the L1 D-cache
md.l 0x9f000000 1        -> 44444444    survived eviction, so it is real DRAM
md.l 0x8f000000 1        -> 80808080    different, so no alias at 256 MiB
```

The wrap is at exactly `0x20000000`: `0xa8000000` and `0x88000000` resolve to
the same storage. **The device tree must declare no more than 512 MiB** —
beyond that Linux would be handed aliased addresses and corrupt itself.

U-Boot reports `DRAM: 256 MiB`, which is a hardcoded constant in the vendor
board file rather than a measurement. It should not be trusted.

### The trap: ATAGs silently override the device tree

The first 512 MiB build changed nothing — still 220 MB. `atags_to_fdt.c`
copies U-Boot's `ATAG_MEM` into the FDT, **overwriting the memory node**, so
the vendor's hardcoded 256 MiB beat the device tree. The initial workaround
disabled `CONFIG_ARM_ATAG_DTB_COMPAT` and forced a compiled command line.

The current boot design deliberately enables ATAG-to-DTB compatibility so
one kernel can accept either HDD or NFS root arguments from U-Boot. Every boot
first replaces `bootargs` with the console and verified memory ranges:

```text
mem=512M@0x80000000 mem=512M@0xc0000000
```

The ARM `mem=` parser discards the automatically discovered map when it sees
the first argument, then adds DDR0 and DDR1 explicitly. A second `setenv`
appends the selected root arguments. The helper verifies the resulting value
with `printenv bootargs` before `bootm`; no environment change is saved.
`CONFIG_ATAGS` remains disabled; only the decompressor's appended-DTB
compatibility converter is needed.

Both root modes were validated with the same kernel. `/proc/cmdline` matched
the value assembled by U-Boot, `/proc/iomem` reported the two 512 MiB banks,
and `MemTotal` was 1,032,240 KiB. HDD mode mounted `/dev/sda1` as ext4; NFS
mode mounted `192.168.4.34:/srv/dhb-ax/rootfs` over NFSv3/TCP.

### No memory is reserved

The former 32 MiB reserve at `0x8e000000` is gone. It was described as the
vendor's media carveout, but the vendor's carveout is everything above
`0x8e000000` — 288 MiB on a 512 MiB board. The 32 MiB figure was an artefact
of believing the board had 256 MiB, and this port already claims 256 MiB
inside that same region.

It also guarded the wrong place. U-Boot's video buffers at `0xc0000000` and
`0xc1000000` alias onto `0x80000000` and `0x81000000` with the 512 MiB wrap —
the bottom of DRAM, where the kernel loads. Nothing ever protected those, and
video output is read-only DMA.

### Validation

With the reserve removed and 462 MB pinned in tmpfs, so buffers must come from
the previously unavailable range:

```text
450 MiB filled and checksummed   41a5c18732255022b922da40ad5a7edb   matches
same, re-checked after 90 s      41a5c18732255022b922da40ad5a7edb   unchanged
network flood, 20000 packets     0% loss
memory re-checked after flood    41a5c18732255022b922da40ad5a7edb   unchanged
USB DMA, 128 MiB read twice      a9b9e693c998c54e5dfaf02c875ce161   identical
SATA DMA, 128 MiB read twice     78360580f94b4e084c1ae5e3bb04cd23   identical
kernel log                       no new warnings
```

The 90-second re-check matters: an immediate checksum would not catch a
periodic writer such as a display refresh. Nothing is writing there.

## SMP, GPIO, I2C and the clock

All verified on hardware 2026-08-04.

### Both CPU cores

`CONFIG_SMP=y`, `NR_CPUS=2`, and `enable-method = "hisilicon,hi3620-smp"` on
the `cpus` node with `smp-offset = <0x134>` on the sysctrl node. **No new
code**: the vendor releases CPU1 by writing the secondary entry point to
`SYS_CTRL + 0x134` and sending a soft interrupt, which is exactly what
mainline's hi3620 method does. Its CPU power-control step no-ops here because
there is no `hisilicon,hi3620-cpu-ctrl` node.

Confirmed live: `/proc/cpuinfo` reports two processors, `IPI1` shows ~21000
timer broadcasts reaching CPU1, and rescheduling IPIs flow both ways. Held up
under two busy loops plus a 8000-packet flood at 0% loss, with no BUG, oops or
lockup.

### GPIO

All nineteen PL061 banks bind and expose `/dev/gpiochip0..18`, so every bank's
clock is live. No interrupts are described — the vendor uses none either — and
patch 0008 stops the driver registering an irqchip in that case, which was
producing nineteen backtraces at boot.

### I2C and the real-time clock

The on-chip **PL031 is unusable**: it binds, but the counter never advances
and neither the control nor the load register accepts a write, which is how a
clock-gated block behaves here. The vendor ships `hi_rtc.ko` for it and never
loads it. There is no PL031 node in the device tree, deliberately.

Real timekeeping is an external **DS1307 on a bit-banged I2C bus**. Finding
the pins took the vendor binary plus the live board:

- `gpioi2c_hi.ko` drives PL061 data offsets `0x40` and `0x80` — the
  address-masked window for bits 4 and 5 — and writes `0x400`, the direction
  register.
- Of the nineteen banks, **only bank 12** had direction `0x30` under the
  vendor firmware, with both pins reading high at rest: an idle bus with
  pull-ups.

```text
i2c-gpio soc:i2c-gpio: using lines 612 (SDA) and 613 (SCL)
rtc-ds1307 0-0068: registered as rtc0
rtc-ds1307 0-0068: setting system clock to 2026-08-04T16:17:36 UTC
```

Two things to know:

- **Reads are cached within a shell invocation.** Successive `hwclock -r` or
  `/proc/driver/rtc` reads in one command return an identical value; a later
  command shows a later time. The chip advances correctly in real time. This
  only matters if you are trying to observe it ticking.
- **The battery is good.** The clock has survived multiple cold reboots with
  the time intact, which is the test that matters: an external RTC exists
  precisely to keep counting while the board is unpowered, and a flat cell
  would have shown up as 2000-01-01 on the next power-on.
- **The chip is not synchronised to anything.** It holds whatever the vendor
  firmware last wrote and currently reads about 30 minutes ahead of the Pi.
  Nothing here writes to it, so the offset persists until something does.

## USB

Both host controllers work. EHCI at `0x100b0000` (SPI 31) and OHCI at
`0x100a0000` (SPI 32) are stock Synopsys blocks that mainline drives
unchanged; the only board-specific part is the PHY, which comes out of chip
reset clock-gated and held in reset.

`phy-hi3531-usb.c` (patch 0009) reproduces the vendor `hiusb_start_hcd()`: set the
USB clock enable and clear seven reset bits in CRG `0x200300b8`, then select
an 8-bit UTMI interface with the ULPI wrapper bypassed in sysctrl
`0x20050080`, disabling EHCI burst-16 as the vendor does. Both windows are
shared with other peripherals, so the driver maps without claiming them.

Expressing this as a **PHY provider** rather than a glue driver is what makes
the rest fall out for free. The USB core initialises the PHYs named in each
controller's `phys` property before the controller starts, and refcounts them
across both — which is exactly what the vendor's `dev_open_cnt` in
`hiusb-godnet.c` did by hand.

Verified on hardware 2026-08-04 with an FTDI adapter in the rear socket:

```text
ehci-platform 100b0000.usb: USB 2.0 started, EHCI 1.00
ohci-platform 100a0000.usb: Generic Platform OHCI controller
usb 2-2: new full-speed USB device number 2 using ohci-platform
        idVendor 0403  idProduct 6001  "FT232R USB UART"
usb 2-2: FTDI USB Serial Device converter now attached to ttyUSB0
27:  2  GIC-0 63  ehci_hcd:usb1
28: 35  GIC-0 64  ohci_hcd:usb2
```

The interrupt numbers match the vendor runtime probe exactly, and there were
no USB errors.

Both sockets and both controllers are exercised. There are two physical
sockets, each wired to both controllers, and the hardware routes by speed:

```text
front socket = port 1    usb 1-1: new high-speed device using ehci-platform
rear socket  = port 2    usb 2-2: new full-speed device using ohci-platform
```

Both sockets have been exercised at both speeds: a microSD card reader and a
Corsair Flash Voyager at high speed on EHCI, in each socket, and an FTDI
serial adapter at full speed on OHCI.

The front-panel Corsair drive is now the boot medium. Vendor U-Boot 2010.06
recognises its MBR partition as FAT32, and `fatload usb 0:1 0x82000000 uImage`
loaded and booted the 3,542,217-byte kernel successfully. Linux does not need
USB mass-storage support to mount the SATA root, so `usb_storage` remains a
normal module rather than part of the built-in root path.

### On USB throughput

That device reads at roughly 1.8 MB/s, which looks alarming next to SATA's
128 MB/s. It is the device, not this port. Established without a reboot:

- `PORTSC1 = 0x1005` — connected, enabled, powered, and **EHCI-owned**. Bit 10
  clear means the controller kept the port rather than releasing it to the
  companion, which only happens for a genuine high-speed link.
- `USBCMD` interrupt threshold is already 1 micro-frame, the most aggressive
  setting, so there is no coalescing penalty to remove.
- `sys` time stays near zero, so nothing is CPU-bound.
- 4 KB versus 1 MB blocks give 1.58 versus 1.79 MB/s — eight times the
  requests for the same throughput, so this is a bandwidth ceiling and not
  per-transfer overhead.
- Enabling `SS_BURST16_EN`, the one bit the vendor deliberately clears, made
  it slightly *worse* (19.04 s versus 17.89 s for 32 MiB). Reverted.
- Throughput varies by region — 2.37 MB/s at an 8 GiB offset versus 1.79 MB/s
  at the start. A host-side limit would be flat.

Confirmed by moving the same device to the Raspberry Pi:

| | this board | Raspberry Pi |
|---|---|---|
| 32 MiB at offset 0 | 1.79 MB/s | 1.6 MB/s |
| 16 MiB at 8 GiB | 2.37 MB/s | 2.6 MB/s |

Within noise of each other, with the same positional variation on both hosts.
The Pi also names the device: a *Super Top microSD card reader*, so this is a
microSD card behind a cheap bulk-only bridge.

A Corsair Flash Voyager then settled what the board can actually do:

| Device | 32 MiB at offset 0 | 256 MiB from 1 GiB |
|---|---|---|
| microSD card reader | 17.89 s — 1.79 MB/s | — |
| Flash Voyager, rear port | 0.96 s — 35 MB/s | 7.68 s — **33.3 MB/s** |
| Flash Voyager, front port | 0.96 s — 35 MB/s | 7.71 s — **33.2 MB/s** |

**Roughly 33 MB/s sustained**, with 22350 EHCI interrupts and no USB errors.
USB 2.0 tops out at 60 MB/s in theory and real hosts typically reach 30-40, so
this controller is performing normally and the card reader was 18x slower
entirely on its own account.

The two sockets are equivalent to within 0.4%, which is expected — they are
both EHCI root-hub ports — but it is now measured rather than assumed.

One caution for anyone reading the earlier evidence: `ANSI: 0` appears for the
Flash Voyager too. It is what bulk-only mass storage reports, not a sign of a
poor bridge, and should not have been cited as supporting evidence that the
card reader was cheap.

## Next milestones

Grounded in `reference/vendor-runtime-probe.md` and the silicon-ID results, in
rough order of value per unit of work. Everything above the line is done.

| Done | Notes |
|---|---|
| Both CPU cores | device tree only; no new code |
| GPIO, 19 banks | mainline PL061 plus patch 0008 |
| I2C and wall-clock time | bit-banged bus to an external DS1307 |
| Ethernet and SATA | ext4 HDD root; original FAT32 layout retained as history |
| USB 2.0 and 1.1 | PHY driver; controllers are stock |
| USB kernel and ext4 SATA root | manual U-Boot load; automatic boot deferred |

Remaining, in order:

1. **L2 cache** at `0x20700000` — not a device tree node. It is a HiSilicon
   proprietary controller with no mainline support, so this means porting the
   vendor's 385-line `cache-hil2v200.c`. Cache maintenance code fails
   silently when wrong, and the size of the win is unmeasured. See the L2
   notes above before starting.
2. **Extra serial ports** — UART1 (SPI 9) and UART2 (SPI 10) are the same
   PL011 as the console; UART3 is registered but shows no interrupt in use.
3. ~~**SD/MMC**~~ — **dropped: there is no card slot on this board.** The
   controller exists in the SoC at `0x10020000` and the vendor compiles a
   driver for it, but nothing is attached. The enclosure has no slot, the
   vendor's `hi_mci` interrupt (SPI 35) shows **zero** counts after hours of
   uptime, and no vendor init script or application references `mmcblk` or
   `/mnt/sd`. `CONFIG_MMC=y` is generic in `godnet_defconfig`, not
   board-specific.

   Recorded because the analysis is still useful if this SoC turns up on a
   board that *does* have a slot: the vendor's `himciv100` is a Synopsys
   DesignWare MMC controller, its register map matching mainline `dw_mmc.h`
   offset for offset (`CTRL 0x00, PWREN 0x04, CLKDIV 0x08, CLKSRC 0x0c,
   CLKENA 0x10, TMOUT 0x14, CTYPE 0x18, BLKSIZ 0x1c, BYTCNT 0x20,
   INTMASK 0x24, CMDARG 0x28, CMD 0x2c, FIFOTH 0x4c`). It would be
   `snps,dw-mshc` plus a clock and reset step, not a new driver.

   An unpopulated slot footprint on the PCB has not been ruled out; nobody has
   looked for one.
4. **Read-only SPI NOR and raw NAND** — `drivers/mtd/devices/hisfc350` and
   `drivers/mtd/nand/hinfc300` in the vendor tree. Both hold the factory
   system, so read-only is the only safe target.
5. **DMA engine** at `0x100d0000` (SPI 29) — real and heavily used by the
   vendor, but clock-gated at boot and there is no vendor source, only a
   binary module.

Not worth attempting: the hardware I2C block (the board bit-bangs instead, so
there is nothing to gain), the on-chip PL031 (clock-gated, and it has no
battery backing so it cannot hold time across a power cycle), and the
media engines — undocumented, unsupported, and the bulk of what the vendor
loads. The two companion Hi3531 chips on PCIe are reachable in principle but
exist to run those same engines.

## Open questions

Things this port has not established, recorded so they are not silently
assumed:

- **Why does the watchdog not reset the SoC?** It counts correctly at 3 MHz
  and expires, but the reset never reaches the chip. The vendor's `wdt.ko`
  clears bit 23 of a register reached through a mapping that is not in the
  vendor source tree.
- **What are the DMA and hardware-I2C blocks?** Both read as all zeros, which
  means clock-gated or not PrimeCell; the ID probe cannot distinguish.
- **Does TX checksum offload work?** Forced off, because nothing confirms the
  engine exists.
  `ethtool` is now on the image and gives the first real datapoint:
  `ethtool -k eth0` reports `rx-checksumming: off [requested on]`, so the
  driver asked for RX checksum and the hardware refused — matching the boot
  line `RX IPC Checksum Offload disabled`. That is evidence about RX, not TX,
  but it is the first time either has been observable.
- **Does the SATA link run at 3 Gbps?** The PHY is programmed for 1.5 Gbps
  because the vendor programs it that way, but their source carries 3 Gbps
  constants behind a `mode_3g` parameter. Two constants in
  `ahci_hi3531.c` (patch 0007); would double the bandwidth shared by every drive.
- **Does the empty fitted SATA connector work?** Putting a drive in SATA4
  would confirm the multiplier port mapping, which is currently inferred. Free
  — see the drive-bay notes above. Enabling it also flips the driver to store-and-forward, which
  is the vendor's own pairing — see the TX wedge section.
