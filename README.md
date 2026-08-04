# DHB_AX V1.2 DVR

Running mainline Linux on a 2012 HiSilicon Hi3531 digital video recorder.

The board is a Shenzhen TVT four-channel analogue DVR, silkscreened
**`DHB_AX V1.2`**. It shipped with Linux 3.0.8 and a stack of binary-only
vendor modules. This project replaces that with Linux 6.18.42 LTS, booted
from RAM over the network, driving as much of the hardware as can be
supported without vendor blobs.

**Nothing here writes to the DVR's flash or to an attached disk.** Every
kernel is loaded into DRAM over TFTP; the factory system is untouched and
still boots.

## Status

| Working | Detail |
|---|---|
| Both CPU cores | dual Cortex-A9; device tree only, no new code |
| Gigabit Ethernet | 20000 packets at 0% loss |
| SATA and FAT32 | 1 TB disk behind a port multiplier, read-only |
| USB 2.0 and 1.1 | both sockets; storage and serial adapters |
| GPIO | all 19 banks |
| Real-time clock | external DS1307 over a bit-banged I2C bus |
| Software reset | back to U-Boot with no power cycle |

Not supported, and not planned: video capture, encode, decode, scaling and
HDMI. Those are undocumented, have no mainline support, and are the bulk of
what the vendor loads. **This port makes the box a capable general-purpose ARM
computer, not a working DVR.**

## Where things are

| Path | What it is |
|---|---|
| `kernel-port/` | the port: device trees, glue drivers, patch queue, build. **Start here.** |
| `kernel-port/README.md` | the authority on anything port-related |
| `kernel-port/reference/` | evidence: vendor runtime probe, chip survey, hardware write-up |
| `docs/investigation.md` | the reverse-engineering phase and backup procedures |
| `backups/` | verified flash images, one copy each + `MANIFEST.md`. **The irreplaceable content here.** |
| `rootfs/` | extracted vendor root filesystem, used constantly as reference |
| `vendor/`, `kernel/` | source trees; regenerable, not worth backing up |
| `pcb/` | photographs of the board and individual chips |
| `tools/` | the RAM-only raw NAND reader and its validator |

## Building and booting

```sh
kernel-port/scripts/bootstrap-sources.sh    # fetch sources, once
kernel-port/build.sh ethernet               # or: minimal
```

Then stage the image in the Pi's TFTP root and, from the DVR's U-Boot prompt:

```text
setenv ipaddr 192.168.7.241
setenv netmask 255.255.252.0
setenv serverip 192.168.4.34
setenv ethaddr 00:18:AE:3C:A2:49
tftp 0x82000000 uImage-6.18.42-dhb-ax-ethernet
bootm 0x82000000
```

Never `saveenv`. Full detail, including recovery when the board wedges, is in
`kernel-port/README.md`.

## How the hardware was worked out

No documentation for this SoC is public. Five independent sources were used,
each authoritative about something different and each wrong in a way the
others catch:

1. **A reference kernel tree** (OpenIPC's mirror of HiSilicon's 3.0.8) — what
   the chip family contains, but not this board.
2. **The vendor's own kernel and filesystem** — what was actually built and
   driven, but silent about hardware they had no use for.
3. **The factory firmware, running** — real interrupt numbers and live
   register state, but only what its drivers claimed.
4. **PrimeCell ID registers** — what a block *is*, but silent when its clock
   is gated.
5. **The board itself** — what is physically fitted, which is the only source
   that can settle a part number.

Disagreements between them were where the interesting findings came from. A
worked example, written for a general audience, is in
`kernel-port/reference/silicon-survey.html`.

## Safety rule

Do not make persistent writes to the DVR unless the owner explicitly changes
this rule.

Safe operations used so far include:

- U-Boot `printenv`, `nand info`, `nand bad`, `nand read`, `sf probe`, `sf read`,
  `md`, `ping`, and the vendor's TFTP upload command.
- U-Boot `setenv` without `saveenv`; these changes exist only in RAM.
- Loading a kernel or flash contents into DRAM and booting it with `bootm`.
- Mounting DVR filesystems read-only and putting temporary files/tools in RAM.
- Reading and writing SoC registers with `devmem` from a booted kernel. Writes
  here are volatile and were used to bring up clock-gated blocks; they touch
  no storage.
- Reading the attached hard disk, including a read-only FAT32 mount. FAT32 has
  no journal, so a read-only mount genuinely writes nothing.

Do **not** run `saveenv`, `sf write`, `sf erase`, `nand write`, `nand erase`,
`flashcp`, `flash_eraseall`, `nandwrite`, or similar commands. Do not write to
the hard disk, mount it read-write, or run `fsck` against it: it holds the
owner's recordings. Before sending anything through tmux, capture the pane and
confirm whether it is a shell or picocom connected directly to the DVR.

## Current development environment

### Shared tmux sessions on the Mac

- `dhb_ax:0.0`: SSH connection to `raspberrypi.local`, running picocom on the
  DVR serial console. Keystrokes sent here go to the DVR.
- `raspberrypi:0.0`: interactive unprivileged shell on the Pi.
- `raspberrypi:1.0`: unprivileged Pi monitoring shell.

Use the shared tmux sessions for visible work. Do not restart or kill the tmux
server; the sessions contain long-lived SSH and serial connections.

Useful commands from the Mac:

```sh
tmux attach -t dhb_ax
tmux attach -t raspberrypi
tmux capture-pane -p -t dhb_ax:0.0
tmux send-keys -t dhb_ax:0.0 "printenv" Enter
```

For automated inspection, capture only the final visible rows rather than the
whole pane repeatedly. The user can still watch every command in real time.

Two lessons learned the hard way when driving the DVR pane programmatically:

- **Bracket each command with a unique marker** and read strictly between the
  markers. The pane history has no session boundaries, so matching on content
  alone will happily return output from a previous boot. This caused at least
  one wrong conclusion.
- **Avoid multi-register `devmem` loops.** Long compound commands interleave
  with console echo and produce plausible-looking but garbled output. Single
  reads are reliable; cross-check anything surprising against a known value.

### Raspberry Pi

- Hostname: `raspberrypi` / `raspberrypi.local`
- Architecture: `armv6l`
- OS/kernel: Raspbian trixie, Linux `6.18.34+rpt-rpi-v6`
- Ethernet on 2026-08-03: `192.168.4.34/22` (recheck after DHCP changes)
- DVR UART: `/dev/serial0 -> /dev/ttyAMA0`, 115200 8N1
- Picocom process:

```sh
picocom -b 115200 --omap crcrlf --logfile dvr.log /dev/serial0
```

Before opening the DVR UART after a Pi reboot, verify that Linux has not claimed
it as a console:

```sh
grep -q '^ttyAMA0' /proc/consoles && echo "UART IS A CONSOLE - abort"
```

Installed Pi tools relevant to this project:

- `picocom` 3.1-4
- `tcpdump` 4.99.5-2+b1
- `tftpd-hpa` 5.2+20240610-3
- `nfs-kernel-server` 1:2.8.3-1 (added for the port; see below)

The TFTP daemon is normally stopped when not in use. It serves `/srv/tftp`,
which holds the port's `uImage-*` files; the DVR downloads from there with
`tftp 0x82000000 <name>`.

### NFS share for kernel-port work

`/srv/dhb-ax` is exported read-write to `192.168.7.240` only — the address the
DVR takes under our kernel:

```text
/srv/dhb-ax 192.168.7.240(rw,sync,no_subtree_check,no_root_squash)
```

From the DVR:

```sh
mkdir -p /mnt
mount -t nfs -o soft,timeo=100,retrans=3,nolock,vers=3 \
      192.168.4.34:/srv/dhb-ax /mnt
```

Use `soft` rather than the default hard mount: a hard mount blocks the shell
uninterruptibly if the link drops, which costs a reset.

This is the fast path for driver work. Kernel modules are pushed to the share
and `insmod`ed on the running board, so iterating on a driver needs no reboot
and no TFTP. Bulk output is written to the share and read on the Pi at full
fidelity rather than scraped from the serial console.

The Pi's SD card had about 580 MB free at the time of writing, so the share
cannot absorb a disk image.

### Mac workspace

```text
/Users/niallsmart/workspace/dhb_ax/
```

Layout:

- `kernel-port/` — the mainline Linux port: device trees, glue drivers, patch
  queue, build scripts, and its own README. **Start here for port work.**
- `kernel-port/reference/` — evidence captured from the machine and the board:
  the vendor runtime probe, the chip survey from PCB photographs, and a
  beginner-oriented write-up of the hardware survey.
- `kernel/` and `vendor/` — source trees, regenerable by
  `kernel-port/scripts/bootstrap-sources.sh`. **Not worth backing up**: about
  4 GB derived from two pinned inputs.
- `rootfs/` — the extracted vendor root filesystem, used constantly as a
  reference for what the vendor drives and how.
- `backups/` — the verified flash images described below. **The irreplaceable
  part of this workspace.**
- `pcb/` — photographs of the board and individual chips.
- `tools/` — `nandrawdump.c`, the RAM-only raw NAND/OOB reader, and
  `inspect_nand_raw.py`, its structural validator.
(An earlier revision of this file listed `dvr-spi-boot.bin`,
`dvr-spi-boot.elf` and `dvr-stmmac.ko` at the top level. They are not present;
the SPI NOR image lives in `backups/`, and the vendor Ethernet module in
`rootfs/hitoe/stmmac.ko`.)

## DVR hardware and software

- Vendor/family: Shenzhen TVT, four-channel analog DVR.
- SoC: HiSilicon Hi3531.
- DRAM: 256 MiB; vendor kernel is given 224 MiB and reserves 32 MiB for media.
- Bootloader: vendor U-Boot 2010.06, built 2012-11-01.
- U-Boot prompt: `hisilicon #`.
- Kernel: Linux 3.0.8 for ARM, uncompressed legacy uImage, built 2013-03-11.
- Kernel load and entry address: `0x80008000`.
- Root filesystem: YAFFS2.
- SPI NOR: 2 MiB S25FL216K on chip select 1, 64 KiB eraseblocks.
- NAND: 128 MiB SLC, 128 KiB eraseblocks, 2 KiB pages, 64-byte OOB, 1-bit
  ECC, ID `01 F1 00 1D`.
- Runtime hardware MAC: `00:18:AE:3C:A2:49`.
- Stored U-Boot `ethaddr`: placeholder `00:00:23:34:45:66`.

Established later, from the vendor's running kernel and from the board itself
(details and evidence in `kernel-port/reference/`):

- The SoC is **dual-core**; the vendor schedules both Cortex-A9s.
- The board carries **three** Hi3531 chips: the main SoC plus two more on
  PCIe (`19e5:3531`) that drive additional video channels.
- Ethernet PHY is a **Realtek RTL8211CL** — it reports the RTL8211B ID, so
  Linux binds the B driver.
- Storage is **ten SATA positions**, two connectors fitted, behind a
  **JMicron JMB321** five-port multiplier on controller port 1.
- Video decode is a **Nextchip NVP1104B** (four channels). The vendor rootfs
  ships drivers for several other decoders that are not fitted.
- A **Lattice ECP3-17EA FPGA** is fitted but never programmed on this variant.
- An **Atmel AT89S52** 8051 runs its own firmware, most likely the front
  panel, and is the probable peer on UART1.
- Timekeeping is an external **DS1307** on a bit-banged I2C bus; the on-chip
  PL031 is clock-gated and unused. The coin cell is good across cold boots.

The normal vendor application and modules live mainly on the `user` partition.
Important names include `td3531`, `XDVRStart.hisi`, `libhi3531.so`, `boot.sh`,
`config/`, `product/`, `ui/`, `language/`, and `modules/extdrv/`.
## Roadmap

The port carries nine local patches, two glue drivers and one PHY driver.
Full detail in `kernel-port/README.md`; status is the table at the top of this
file.

### Planned next steps

In order of value per unit of work:

1. **Extra serial ports.** UART1 (SPI 9) and UART2 (SPI 10) are the same PL011
   as the console, so this is two device tree nodes. Worth doing first because
   UART1 is the probable link to the AT89S52, and listening to it would tell
   us how the front panel and IR remote actually work.
2. **SD/MMC** at `0x10020000`, SPI 35. The vendor's controller is Synopsys
   DesignWare — its register map matches mainline `dw_mmc.h` offset for
   offset — so this should be `snps,dw-mshc` plus a clock and reset step, not
   a new driver.
3. **Read-only SPI NOR and NAND.** Mainline has `hisi-sfc` and `hisi504_nand`;
   whether they match this SoC's `hisfc350` and `hinfc300` is the first
   question. Read-only only: this flash holds the only factory system.
4. **L2 cache** at `0x20700000`. Needs diagnosis before it can be scheduled —
   it currently reads `CTRL = 0` (disabled) and `CACHE_ID = 0`, which a PL310
   should not do, and the vendor platform code contains no L2 init at all.
5. **DMA engine** at `0x100d0000`, SPI 29. Real and heavily used by the
   vendor, but clock-gated, unidentifiable by ID probe, and with no vendor
   source — only a binary module. Low value: Ethernet, SATA and USB all have
   their own DMA.

Cheap and worthwhile alongside the above:

- **Skip the empty multiplier ports.** Ports 0, 1 and 4 have no connector
  fitted and can never hold a drive, so
  `libata.force=2.00:disable,2.01:disable,2.04:disable` saves about 3.2 s of
  boot with nothing foregone.
- **Measure USB properly.** The only device tested tops out around 2 MB/s on
  the Raspberry Pi too, so it is the device, not the port. A faster device
  would establish the real figure.

### Open questions

- Why the SATA multiplier takes 10.6 s to answer before enumeration starts.
- Why the watchdog counts correctly but never resets the SoC. The vendor
  `wdt.ko` clears bit 23 of a register reached through a mapping absent from
  the vendor source tree.
- What the DMA and hardware-I2C blocks are; both read as all zeros, which the
  PrimeCell ID probe cannot distinguish from absent.
- Whether TX checksum offload works. Forced off, because nothing confirms the
  engine exists.
- Whether `CON1`, an unpopulated 2x10 header with a square pin-1 pad, is ARM
  JTAG. The footprint matches, nothing confirms it.

## Recommended next session

1. Attach to both tmux sessions and inspect every pane before typing. The DVR
   pane may be at U-Boot (`hisilicon #`), at our kernel's shell (`/ #`), or at
   the vendor system's login prompt — the vendor root password is `1001chin`.
2. For port work, read `kernel-port/README.md` first, then run
   `kernel-port/scripts/bootstrap-sources.sh` if `kernel/` is missing.
3. Preserve a second copy of `backups/` on another host or storage device.
   That directory is the only irreplaceable content here.
4. Optionally derive main-area-only images on the Pi from one validated
   raw+OOB image; do not reread the DVR merely to create convenience copies.
5. Continue analysis from copies rather than modifying the verified originals.
