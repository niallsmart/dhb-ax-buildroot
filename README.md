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
| USB 2.0 and 1.1 | both sockets, both speeds; ~33 MB/s sustained |
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
| `kernel-port/README.md` | the authority on anything port-related. **Start here.** |
| `kernel-port/reference/` | evidence: vendor runtime probe, chip survey, hardware write-up |
| `br2-external/` | board support: defconfig, kernel config, device trees, patch queue, overlay |
| `scripts/` | fetch the sources, and the containerised Buildroot build |
| `docs/buildroot-migration-plan.md` | why Buildroot, what it replaces, stage by stage |
| `docs/investigation.md` | the reverse-engineering phase and backup procedures |
| `docs/memory-map.md` | address space, the two DRAM banks, what the vendor reserves |
| `docs/video.md` | display path, framebuffer format, putting an image on HDMI |
| `backups/` | verified flash images, one copy each + `MANIFEST.md`. **The irreplaceable content here.** |
| `rootfs/` | extracted vendor root filesystem, used constantly as reference |
| `vendor/`, `kernel/` | source trees; regenerable, not worth backing up |
| `pcb/` | photographs of the board and individual chips |
| `tools/` | raw NAND reader and validator, USB benchmark, framebuffer converter |

## Building and booting

```sh
scripts/bootstrap-sources.sh    # fetch sources, once
scripts/buildroot.sh            # configure and build
```

The build is Buildroot 2026.02.3, pinned by checksum, running in a container.
Board support lives in `br2-external/`. The migration from the previous
hand-rolled build is finished; `docs/buildroot-migration-plan.md` records what
changed and why.

The image lands in `kernel-port/build/buildroot-artifacts/`. Stage it in the
Pi's TFTP root and, from the DVR's U-Boot prompt:

```text
setenv ipaddr 192.168.7.241
setenv netmask 255.255.252.0
setenv serverip 192.168.4.34
setenv ethaddr 00:18:AE:3C:A2:49
tftp 0x82000000 uImage-hi3531-dhb-ax-ethernet
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

- `dhb_ax:0.0`: SSH connection to the Pi, running picocom on the DVR serial
  console. Keystrokes sent here go to the DVR.
- `raspberrypi:0.0`: **not a shell.** As of 2026-08-04 this pane runs an
  interactive Python TUI, unrelated to this project. There is no
  `raspberrypi:1.0`.

**Check what a pane is actually running before sending anything to it.** Not
just the DVR pane — any pane. `tmux list-panes -a -F
'#{session_name}:#{window_index}.#{pane_index} #{pane_current_command}'`
answers it in one command. A shell command line typed into a full-screen TUI
is not inert: every character is a key binding, and the trailing Enter
commits whatever the last one opened. This happened — a status query intended
for a Pi shell went into the TUI in `raspberrypi:0.0`, whose footer offers
single-key `l` and `t` actions, and the command text contains both many
times.

To reach the Pi non-interactively, SSH to it directly rather than typing into
a pane:

```sh
ssh 192.168.4.34 'ls -l /srv/tftp/'
```

Note `raspberrypi.local` does not resolve from the Mac; use the IP.

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

**The Pi's SD card is full.** It had about 580 MB free when this was first
written; on 2026-08-04 it hit 0 and picocom died mid-session with
`FATAL: write to logfile failed: No space left on device`, taking the serial
console with it. `sudo apt-get clean` recovered 87 MB, which is enough to keep
logging but not a fix.

If the console dies unexpectedly, check `df -h /` on the Pi first. `/srv/tftp`
holds about 99 MB of accumulated `uImage-*` files from past sessions, all
regenerable, and is the obvious place to reclaim space.

### Mac workspace

```text
<workspace>/dhb_ax/
```

Layout:

- `kernel-port/` — the port's documentation and evidence. Its README is the
  authority on anything port-related. **Start here for port work.** The build
  machinery it used to hold was retired once Buildroot took over.
- `br2-external/` — board support: the defconfig, kernel config, device trees,
  patch queue, rootfs overlay, and the post-build and post-image scripts.
- `kernel-port/reference/` — evidence captured from the machine and the board:
  the vendor runtime probe, the chip survey from PCB photographs, and a
  beginner-oriented write-up of the hardware survey.
- `kernel/`, `vendor/` and `buildroot/` — source trees, regenerable by
  `scripts/bootstrap-sources.sh`. **Not worth backing up**: about
  4 GB derived from three pinned inputs.
- `scripts/` — source bootstrap and the containerised Buildroot build.
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
- DRAM: **1 GiB in two banks** — DDR0 at `0x80000000` and DDR1 at
  `0xc0000000`, 512 MiB each, on separate controllers. This port declares
  DDR0 only, giving about 501 MiB after kernel overhead; DDR1 is where
  U-Boot's framebuffers live and is not claimed. The vendor kernel caps
  Linux at 224 MiB and gives the rest to its media allocator. U-Boot's
  `DRAM: 256 MiB` is a hardcoded constant, not a measurement. Full detail
  in `docs/memory-map.md`.
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
2. **Read-only SPI NOR and NAND.** Mainline has `hisi-sfc` and `hisi504_nand`;
   whether they match this SoC's `hisfc350` and `hinfc300` is the first
   question. Read-only only: this flash holds the only factory system.

   The userspace side of this is now done. `mtdinfo`, `nanddump` and
   `mtd_debug` are on the image, and `flash_erase`, `flashcp` and `nandwrite`
   are deliberately *not* — see `br2-external/board/dhb_ax/post-build.sh`,
   which fails the build if a writer reappears. `mtdinfo` currently reports
   `MTD is not present in the system`, which is correct: only the kernel-side
   driver is missing. Getting these tools was the main reason for the
   Buildroot migration.
3. **L2 cache** at `0x20700000`. Diagnosed: it is a HiSilicon proprietary
   controller, not a PL310, and mainline has no driver for it. Enabling it
   means porting the vendor's 385-line `cache-hil2v200.c`. The vendor does use
   it (`CONFIG_CACHE_HIL2V200=y`). Riskier than anything else remaining,
   because cache maintenance bugs corrupt data silently rather than failing
   visibly, and the size of the win has never been measured. Notes in
   `kernel-port/README.md`.
4. **DMA engine** at `0x100d0000`, SPI 29. Real and heavily used by the
   vendor, but clock-gated, unidentifiable by ID probe, and with no vendor
   source — only a binary module. Low value: Ethernet, SATA and USB all have
   their own DMA.

Cheap and worthwhile alongside the above:

- **Skip the empty multiplier ports.** Ports 0, 1 and 4 have no connector
  fitted and can never hold a drive, so
  `libata.force=2.00:disable,2.01:disable,2.04:disable` saves about 3.2 s of
  boot with nothing foregone.

### Open questions

- Why the SATA multiplier takes 10.6 s to answer before enumeration starts.
- Why the watchdog counts correctly but never resets the SoC. The vendor
  `wdt.ko` clears bit 23 of a register reached through a mapping absent from
  the vendor source tree.
- What the DMA and hardware-I2C blocks are; both read as all zeros, which the
  PrimeCell ID probe cannot distinguish from absent.
- Whether TX checksum offload works. Forced off, because nothing confirms the
  engine exists.
  `ethtool` is now on the image and gives the first real datapoint:
  `ethtool -k eth0` reports `rx-checksumming: off [requested on]`, so the
  driver asked for RX checksum and the hardware refused — matching the boot
  line `RX IPC Checksum Offload disabled`. That is evidence about RX, not TX,
  but it is the first time either has been observable.
- Whether `CON1`, an unpopulated 2x10 header with a square pin-1 pad, is ARM
  JTAG. The footprint matches, nothing confirms it.
- Whether the three unused ports on the fitted SATA multiplier could be
  populated. Assessed from photographs: they need connectors and coupling
  capacitors, and two assumptions want checking first. Notes in
  `kernel-port/README.md`.

## Recommended next session

1. Attach to both tmux sessions and inspect every pane before typing. The DVR
   pane may be at U-Boot (`hisilicon #`), at our kernel's shell (`/ #`), or at
   the vendor system's login prompt — the vendor root password is `1001chin`.
2. For port work, read `kernel-port/README.md` first, then run
   `scripts/bootstrap-sources.sh` if `kernel/` is missing.
3. Preserve a second copy of `backups/` on another host or storage device.
   That directory is the only irreplaceable content here.
4. Optionally derive main-area-only images on the Pi from one validated
   raw+OOB image; do not reread the DVR merely to create convenience copies.
5. Continue analysis from copies rather than modifying the verified originals.
