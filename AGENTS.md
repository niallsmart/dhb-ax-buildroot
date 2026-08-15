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

The output image is `artifacts/buildroot/uImage-hi3531-dhb-ax-full`.

## Commit messages

Use a short, imperative subject, such as `buildroot: verify the kernel archive`
or `tools: reuse the persistent DVR console`. Add a component prefix when it
makes the subject clearer, but do not force one. Keep each commit to one logical
change, and add a body only when the reason or supporting evidence is not
obvious. Do not add a `Signed-off-by` line unless it is required.

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
  DDR0 at `0x80000000`, DDR1 at `0xc0000000`. The port declares both banks and
  uses the ARM 2G/2G virtual split; runtime validation reports the full 1 GiB.
- Vendor U-Boot is 2010.06, its prompt is `hisilicon #`, and the kernel load
  and entry address is `0x80008000`.
- The runtime MAC is `00:18:AE:3C:A2:49`; the value stored in U-Boot is only a
  placeholder.
- The 1 TB WDC SATA disk is the Buildroot ext4 root filesystem. Its stable
  partition identifier is `ca264b64-5738-4e60-a0ab-b3c3a4c789c1`.
- The front-panel 8 GB Corsair USB drive has one FAT32 partition. Its `/uImage`
  is the normal kernel image.

## Talking to the DVR

### Serial console

Use the UART for U-Boot, boot logs, recovery, or when Linux networking or sshd
is unavailable.

The `dvr` tmux session owns the UART through one long-lived SSH and picocom
connection. Start or attach to it with `just dvr`. Leave it running.

- Use `just dvr` for an interactive console.
- Use `tools/dvr-exec.sh` to run one command at a Linux shell.
- Use `tools/dvr-boot.exp` to boot a kernel from USB or TFTP.

```sh
tools/dvr-exec.sh 'cat /proc/mtd'
```

tmux scrollback is the console history; use `tmux capture-pane` for forensics.

### Vendor Linux

When the vendor Linux 3.0.8 system is running, Telnet access is allowed and is
usually more convenient than the serial shell:

```sh
telnet 192.168.4.77
```

Log in as `root` with password `1001chin`. The DHCP reservation is
`192.168.4.77`; the legacy static address is `192.168.7.240`. Telnet is
unencrypted, so use it only on the local trusted network.

### Buildroot Linux

When the normal Buildroot system is running, use OpenSSH directly. The DVR has
a DHCP reservation at `192.168.4.77`, and root login is public-key only:

```sh
ssh -o BatchMode=yes root@192.168.4.77 'uname -a'
scp path/to/file root@192.168.4.77:/tmp/
```

This is the default path for commands, file transfer and interactive work. It
is faster and more flexible than sending shell commands through the UART. The
authorized key comes from the ignored local build input at
`artifacts/local/ssh/authorized_keys`.

## Booting a kernel

Automatic boot is deliberately deferred. For now, manually boot the installed
USB kernel through the serial console:

```sh
tools/dvr-boot.exp --usb
```

### TFTP development and recovery

The Raspberry Pi at `raspberrypi` hosts the TFTP server and serial connection.
Stage and boot a local image with:

```sh
tools/dvr-boot.exp --stage \
    artifacts/buildroot/uImage-hi3531-dhb-ax-full
```

Use `--check --stage` to compare the local and staged images without changing
anything or accessing the UART. An already-staged image can still be booted by
name:

```sh
tools/dvr-boot.exp uImage-hi3531-dhb-ax-full
```

The helper handles staging, checksum verification, the TFTP service, U-Boot
interaction, bootargs verification, and boot checks. USB defaults to the HDD
root and TFTP to the Pi's NFS root. Use `--root hdd` or `--root nfs` to
override that pairing; for example, `--usb --root nfs` avoids U-Boot Ethernet
when testing the NFS root. Run `tools/dvr-boot.exp --help` for all options.

## Provisioning the USB and HDD

The normal Buildroot system uses the USB kernel and HDD root. The one-time
provisioning tools are intentionally explicit and refuse to run unless Linux
is currently using an NFS root:

```sh
tools/dvr-prepare-storage.sh --destroy-all-data
tools/dvr-install-system.sh
```

The first command destroys and recreates both storage devices after matching
their model, capacity, removability and hardware path. The second installs the
current `rootfs.tar` and uImage onto empty prepared filesystems.

## NFS development and recovery

The Raspberry Pi can still export a temporary root filesystem for provisioning
or recovery. When using a kernel built with the NFS-root command line, publish
the userspace with:

```sh
scripts/buildroot.sh
scripts/publish-nfs-root.sh
```

The normal kernel supports either root; `dvr-boot.exp` supplies the selected
root and the verified two-bank memory map through volatile U-Boot `bootargs`.

The publisher handles transfer, validation, safe replacement, and rollback.
Follow its error messages if the running DVR must be moved to the rescue image
first. For ordinary driver work, copy the specific modules or files through the
share instead of republishing the complete root filesystem.

## Protecting the factory flash

The factory firmware still boots and the flash images in `backups/` are the only
copies of it. The USB drive and SATA HDD are approved Linux storage; the SPI NOR
and NAND are not.

- Never run `saveenv`, `sf write`, `sf erase`, `nand write`, `nand erase`,
  `flashcp`, `flash_eraseall`, `nandwrite`, or similar commands.
- Neither SSH nor `tools/dvr-exec.sh` enforces any of this. Check every command
  before sending it.

Safe operations include U-Boot `printenv`, `nand info`, `nand bad`, `nand
read`, `sf probe`, `sf read`, `md` and `ping`; temporary `setenv` changes
without `saveenv`; loading data into DRAM and booting it with `bootm`; normal
filesystem work on the USB and HDD; temporary files in RAM; and volatile SoC
register writes with `devmem`. A command being technically safe does not make it useful:
send only the minimum operation needed for the task.
