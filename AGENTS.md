# Working on this repo

Start with `README.md` for the project overview. The sibling
`../hi3531-porting-guide/doc/README.md` indexes the official hardware and
porting guide. That guide is an early release: prefer specific, repeatable
hardware evidence when it disagrees, and update the guide rather than changing
working source to match it.

This file is for repository workflow, device access and safety constraints.

## Repository map and build

- `br2-external/` is the maintained board support: defconfig, kernel config,
  device trees, patch queue, rootfs overlay, and post-build/image scripts.
- `scripts/` contains source/bootstrap and build operations; `tools/` contains
  board interaction and provisioning commands.
- `pcb/` contains board and component photographs.
- `rootfs/` is the extracted vendor filesystem and is a reference, not the
  rootfs built for the port.
- `backups/` contains the verified factory-flash images; see the safety rules
  below.
- `kernel/` and `buildroot/` are derived source trees. They are regenerated
  from pinned inputs; make lasting kernel changes in the `br2-external/` patch
  queue rather than editing these trees as source.
- `artifacts/buildroot/` contains ignored current outputs;
  `artifacts/legacy/` contains ignored historical outputs.

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

## Working on the device

The board can run the vendor 3.0.8 kernel or the mainline port. Run `uname -r`
before interpreting runtime results. Avoid multi-register `devmem` loops over
the serial console: echo interleaving can produce plausible but garbled output.
Prefer individual reads and cross-check surprising values.

Update `README.md` when the maintained implementation or its verified status
changes. Put reusable hardware conclusions in the official porting guide.

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

## Booting and deployment

Automatic boot is deliberately deferred. For now, manually boot the installed
USB kernel through the serial console:

```sh
tools/dvr-boot.exp --usb
```

For TFTP development or recovery, stage and boot a local image through the
Raspberry Pi with:

```sh
tools/dvr-boot.exp --stage \
    artifacts/buildroot/uImage-hi3531-dhb-ax-full
```

Run `tools/dvr-boot.exp --help` for image checks, root selection and other
options.

## Provisioning the USB and HDD

The normal Buildroot system uses the USB kernel and HDD root. The one-time
provisioning tools are intentionally explicit and refuse to run unless Linux
is currently using an NFS root:

```sh
tools/dvr-prepare-storage.sh --destroy-all-data
tools/dvr-install-system.sh
```

The first command destroys and recreates both approved storage devices. The
second installs the current `rootfs.tar` and full uImage. Read each tool before
changing its device-identification checks.

## NFS development and recovery

The Raspberry Pi can export a root filesystem for development, provisioning or
recovery:

```sh
scripts/buildroot.sh
scripts/publish-nfs-root.sh
```

Boot that root with `tools/dvr-boot.exp --usb --root nfs`. For ordinary driver
work, copy specific modules or files rather than republishing the complete
root filesystem.

## Protecting the factory flash

The USB drive and SATA HDD are approved Linux storage. The SPI NOR, NAND and
saved U-Boot environment are not.

- Never run `saveenv`, `sf write`, `sf erase`, `nand write`, `nand erase`,
  `flashcp`, `flash_eraseall`, `nandwrite`, or similar commands.
- Do not modify the verified originals under `backups/`.
- Access helpers do not enforce this boundary. Check commands before sending
  them to U-Boot or Linux.

Volatile `setenv`, RAM loading and `bootm` are allowed; do not follow them with
`saveenv`. Normal filesystem work on the USB drive and HDD is allowed.
