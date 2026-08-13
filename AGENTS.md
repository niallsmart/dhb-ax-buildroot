# Working on this repo

Start with `README.md` for the project overview, and `docs/porting.md`
for anything about the port itself. This file captures the repository and
operational context needed to work on the code and board safely.

The target is an LTS `LTD2704XE-P` DVR built on a Shenzhen TVT `DHB_AX V1.2`
motherboard around the HiSilicon Hi3531 platform. The factory system is Linux
3.0.8 with binary vendor modules; the port is Linux 6.18.42 LTS with Buildroot.
The goal is a useful general-purpose ARM system. Video capture, encode/decode,
scaling and HDMI are undocumented, have no mainline support, and are
deliberately out of scope.

## Repository map and build

- `docs/porting.md` is the authority on port status, implementation and
  remaining work. Read it before changing the port.
- `docs/reference/` contains evidence captured from the vendor system,
  PCB and SoC.
- `br2-external/` is the maintained board support: defconfig, kernel config,
  device trees, patch queue, rootfs overlay, and post-build/image scripts.
- `scripts/` contains the source bootstrap and containerised Buildroot build.
- `artifacts/buildroot/` contains ignored current build outputs;
  `artifacts/legacy/` preserves ignored pre-Buildroot outputs for comparison.
- `docs/buildroot-migration-plan.md` explains the current build architecture;
  `docs/investigation.md` records the reverse-engineering and backup process;
  `docs/memory-map.md` covers DRAM and reserved regions; and `docs/video.md`
  documents the unsupported display path.
- `rootfs/` is the extracted vendor filesystem and is a reference, not the
  rootfs built for the port.
- `backups/` contains the only verified copies of the factory flash. It is the
  irreplaceable part of the workspace. Analyse copies; do not modify the
  verified originals.
- `kernel/` and `buildroot/` are derived source trees. They are regenerated
  from pinned inputs by `scripts/bootstrap-sources.sh` and are not worth
  backing up.
- `pcb/` contains board/chip photographs; `tools/` contains the raw NAND reader
  and validator plus other investigation utilities.

Fetch and build with:

```sh
scripts/bootstrap-sources.sh    # once, or when a derived tree is absent
scripts/buildroot.sh
```

The output image is
`artifacts/buildroot/uImage-hi3531-dhb-ax-ethernet`.

## Reasoning from hardware evidence

No public documentation for this SoC is available. Cross-check conclusions
instead of treating any one source as complete:

1. The reference HiSilicon 3.0.8 tree describes the chip family, not
   necessarily this board.
2. The vendor kernel and filesystem show what was built and driven, but omit
   hardware the product did not use.
3. A running factory system gives real interrupts and register state, but only
   for drivers that claimed the hardware.
4. PrimeCell IDs identify accessible blocks, but a clock-gated block can read
   like an absent one.
5. PCB inspection settles fitted parts, but not their runtime configuration.

The board can run either the vendor 3.0.8 kernel or the mainline port. Check
`uname -r` before interpreting runtime results. Avoid multi-register `devmem`
loops over the serial console: echo interleaving can produce plausible but
garbled output. Prefer individual reads and cross-check surprising values.

Facts that affect low-level work:

- The SoC has two Cortex-A9 cores and 1 GiB of DRAM in two 512 MiB banks:
  DDR0 at `0x80000000`, DDR1 at `0xc0000000`. The port intentionally declares
  DDR0 only; U-Boot framebuffers occupy DDR1. See `docs/memory-map.md`.
- Vendor U-Boot is 2010.06, its prompt is `hisilicon #`, and the kernel load
  and entry address is `0x80008000`.
- The runtime MAC is `00:18:AE:3C:A2:49`; the value stored in U-Boot is only a
  placeholder.
- The attached 1 TB SATA disk contains the owner's recordings and must remain
  read-only.

## Talking to the DVR

The board's serial console is a picocom session running under tmux, started by
`just dvr`. Drive it with:

```sh
tools/dvr-console.sh 'cat /proc/mtd'
```

**Do not use `tmux capture-pane` directly.** It returns the entire scrollback,
so each read pulls in hundreds of lines of stale output from earlier commands —
it wastes context and makes it easy to read an old result as a new one. The
script brackets the command in start/end markers and prints only the text
between the last pair, so you get exactly one command's output. It polls for
completion rather than sleeping a fixed interval, so slow commands are not
truncated.

`SESSION` and `TIMEOUT` are environment overrides; the defaults are `dvr` and 20
seconds.

The console might be at U-Boot (`hisilicon #`), the mainline shell (`/ #`), or
the vendor login prompt (vendor root password: `1001chin`). Confirm which
before sending a command. Reach the Pi non-interactively with SSH rather than
typing shell commands into an arbitrary tmux pane. In particular,
`raspberrypi:0.0` may be an unrelated interactive TUI, not a shell. Do not
restart or kill the shared tmux server.

The DVR UART is `/dev/serial0` (normally `/dev/ttyAMA0`) at 115200 8N1 on the
Pi. Before reopening it after a Pi reboot, make sure Linux has not claimed it
as a console:

```sh
grep -q '^ttyAMA0' /proc/consoles && echo "UART IS A CONSOLE - abort"
```

## Booting a kernel over TFTP (the Raspberry Pi)

Kernels are RAM-booted from a Raspberry Pi that acts as the TFTP server and hosts
the serial console. Reach it over SSH as `raspberrypi` (192.168.4.34 — this is
U-Boot's `serverip`). Its TFTP root is `/srv/tftp`, owned by root, so staging an
image needs `sudo`:

```sh
scp artifacts/buildroot/uImage-hi3531-dhb-ax-ethernet \
    raspberrypi:/tmp/img
ssh raspberrypi 'sudo install -m0644 /tmp/img /srv/tftp/uImage-hi3531-dhb-ax-ethernet'
```

Then, at the DVR's U-Boot prompt (`hisilicon #`), over the serial console:

```text
setenv ipaddr 192.168.7.241
setenv netmask 255.255.252.0
setenv serverip 192.168.4.34
setenv ethaddr 00:18:AE:3C:A2:49
tftp 0x82000000 uImage-hi3531-dhb-ax-ethernet
bootm 0x82000000
```

**`bootdelay` is 1 second.** To catch U-Boot you have to reboot the board
(`reboot` from Linux, or power-cycle) and spam a key on the serial line through
the whole reset — reacting to "Hit any key to stop autoboot" is too slow. Send a
space every ~0.25 s for 30 s, then look for `hisilicon #`.

### The TFTP gotcha: start tftpd-hpa first

`tftpd-hpa` on the Pi is not enabled at boot, so after the Pi restarts it is
**inactive** and every transfer stalls at `Downloading: *` with no data — the
board looks broken but the server simply is not listening. Start it before
booting:

```sh
ssh raspberrypi 'sudo systemctl start tftpd-hpa'
# verify: systemctl is-active tftpd-hpa; sudo ss -ulnp | grep :69
```

A quick way to tell the server apart from the board: `tftp 192.168.4.34` from
your own machine and `get` the image. If that times out too, it is the Pi, not
the DVR.

## Iterating with the NFS share

The Pi exports `/srv/dhb-ax` read-write to the mainline system at
`192.168.7.240`. This is the fast path for driver work: copy modules or bulk
output through the share rather than rebooting or scraping serial output.

Mount it from the DVR with a soft NFSv3 mount:

```sh
mkdir -p /mnt
mount -t nfs -o soft,timeo=100,retrans=3,nolock,vers=3 \
      192.168.4.34:/srv/dhb-ax /mnt
```

Do not use the default hard mount: if the link drops, it can block the shell
uninterruptibly and force a reset.

The Pi has very little free space. A full SD card makes picocom terminate with
`FATAL: write to logfile failed: No space left on device`, which also removes
the serial console. If the console disappears unexpectedly, check `df -h /` on
the Pi first. Old images under `/srv/tftp` are regenerable, but inspect them
before reclaiming space; do not delete files as part of diagnosis alone.

## Nothing writes to the board

The factory firmware still boots and the flash images in `backups/` are the only
copies of it. Kernels are loaded into DRAM over TFTP and run from there.

- Never run `saveenv`, `sf write`, `sf erase`, `nand write`, `nand erase`,
  `flashcp`, `flash_eraseall`, `nandwrite`, or similar commands.
- Never write to the attached SATA disk, mount it read-write, or run `fsck` on
  it.
- `tools/dvr-console.sh` does not enforce any of this. It sends whatever it is
  given, so check a command before sending it.

Safe operations include U-Boot `printenv`, `nand info`, `nand bad`, `nand
read`, `sf probe`, `sf read`, `md` and `ping`; temporary `setenv` changes
without `saveenv`; loading data into DRAM and booting it with `bootm`;
read-only filesystem mounts; temporary files in RAM; and volatile SoC register
writes with `devmem`. A command being technically safe does not make it useful:
send only the minimum operation needed for the task.
