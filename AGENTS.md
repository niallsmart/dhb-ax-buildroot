# Working on this repo

Start with `README.md` for the project overview. The sibling
`../dhb-ax-guide/doc/README.md` indexes the official hardware and porting guide.
That guide is an early release: prefer specific, repeatable hardware evidence
when it disagrees, and update the guide rather than changing working source to
match it.

This file is for repository workflow, device access and safety constraints.

## Repository map and build

- `br2-external/` is the maintained board support: defconfig, kernel config,
  device trees, patch queue, rootfs overlay, and post-build/image scripts.
- `scripts/` contains source/bootstrap and build operations; `tools/` contains
  board interaction and provisioning commands.
- Board photographs, the extracted vendor filesystem and the verified
  factory-flash images live in the sibling guide as `../dhb-ax-guide/pcb/`,
  `../dhb-ax-guide/rootfs/` and `../dhb-ax-guide/backups/`. They describe the
  hardware rather than build it, and nothing here reads them. The vendor rootfs
  is a reference, not the rootfs built for the port.
- `kernel/` and `buildroot/` are derived source trees. They are regenerated
  from pinned inputs; make lasting kernel changes in the `br2-external/` patch
  queue rather than editing these trees as source.
- `artifacts/buildroot/` contains ignored production-image outputs;
  `artifacts/buildroot-minimal/` contains ignored diagnostic outputs;
  `artifacts/toolchain/` contains the ignored shared SDK export, and
  `artifacts/legacy/` contains ignored historical outputs.



`local.env` is the gitignored machine-local configuration and needs to be
configured by the user. It carries the root password
hash, and the build exits rather than proceed without one. Add
further per-machine values as `DHB_AX_*` keys, documenting each in the
tracked `local.env.example`. Nothing secret goes in `br2-external/`: that
tree is public, and `buildroot.sh savedefconfig` rewrites the defconfig from
`.config`.

Prepare a fresh checkout and build the shared toolchain before an image:

```sh
scripts/bootstrap-sources.sh
scripts/buildroot.sh --config toolchain
scripts/buildroot.sh --config main
scripts/buildroot.sh --config minimal
```

The first bootstrap prepares sources and exits non-zero when the SDK is not
staged; the reported toolchain command is the next step. `main` is the default
configuration. `minimal` builds the self-contained storage-bootstrap image
with serial access, DHCP, Dropbear, and the approved SATA/USB storage paths.
Each configuration has a separate output volume, while downloads and the
compiler cache are shared. `--config NAME --clean` drops only the selected
output volume; `--distclean` drops all build, download and cache volumes.

The production image is `artifacts/buildroot/uImage-hi3531-dhb-ax`. The
diagnostic image is
`artifacts/buildroot-minimal/uImage-hi3531-dhb-ax-minimal`.

# Commit Conventions

Keep each commit to one logical change, and add a body only when the reason or supporting evidence is not obvious.

Use a short, imperative subject, such as "buildroot: verify the kernel archive" or "tools: reuse the persistent DVR console". Add a component prefix when it makes the subject clearer, but do not force one.

Do not add a Signed-off-by line unless it is required.

## Comments and documentation

Write what is true of the tree as it stands. A comment outlives the commit
that introduced it and the reader rarely has the diff in view, so a line
describing the change rather than the state stops making sense almost at once:

    no:  The serial console runs a getty, and until this was set root had
         no password.
    yes: This is what the getty on the serial console authenticates against.

"now", "used to", "previously", "no longer" and "currently" are the usual
signs. That material belongs in the commit message, where it is dated and sits
beside the diff that justifies it.

The same applies to comparisons with whatever the code replaced. A reader who
never saw the old arrangement gains nothing from being told this one differs;
explain the mechanism instead, and give a reason only where the choice is
surprising on its own terms.

Deliberately temporary text is the exception, and has to name the thing that
retires it -- as the `linux-dirclean` paragraph above names the check that
lets the next person delete it.

## Working on the device

The board can run the vendor 3.0.8 kernel or the mainline port. Run `uname -r`
before interpreting runtime results. Avoid multi-register `devmem` loops over
the serial console: echo interleaving can produce plausible but garbled output.
Prefer individual reads and cross-check surprising values.

Update `README.md` when the maintained implementation or its verified status
changes. Put reusable hardware conclusions in the official porting guide.

## Talking to the DVR

### Serial console

Use the UART for U-Boot, boot logs, recovery, or when Linux networking or Dropbear
is unavailable.

Under the Buildroot system the console getty asks for a password: log in as
`root` with the password whose hash is in `local.env`. The tools below assume
a session that is already logged in, so only interactive `just dvr-console` attaches
need it.

The `dvr` tmux session owns the UART through one long-lived SSH and picocom
connection. Start or attach to it with `just dvr-console`. Leave it running.

- Use `just dvr-console` for an interactive console.
- Use `tools/dvr-console-exec.sh` to run one command at a Linux shell.
- Use `tools/dvr-boot.sh` to boot a kernel from USB or TFTP.

```sh
tools/dvr-console-exec.sh 'cat /proc/mtd'
```

tmux scrollback is the console history; use `tmux capture-pane` for forensics.

### Vendor Linux

When the vendor Linux 3.0.8 system is running, Telnet access is allowed and is
usually more convenient than the serial shell:

```sh
telnet dvr
```

Log in as `root` with password `1001chin`. The `dvr` hostname resolves to the
DHCP reservation; the legacy static address is `192.168.4.77`. Telnet is
unencrypted, so use it only on the local trusted network.

### Buildroot Linux

When the normal Buildroot system is running, use the SSH client directly through the
`dvr` hostname. Root login is public-key only:

```sh
ssh -o BatchMode=yes root@dvr 'uname -a'
scp path/to/file root@dvr:/tmp/
```

This is the default path for commands, file transfer and interactive work. It
is faster and more flexible than sending shell commands through the UART. The
authorized key comes from the ignored local build input at
`artifacts/local/ssh/authorized_keys`.

## Booting and deployment

Automatic boot is deliberately deferred. For now, manually boot the installed
USB kernel through the serial console:

```sh
tools/dvr-boot.sh usb
```

For TFTP development or recovery, stage and boot a local image through the
Raspberry Pi with:

```sh
tools/dvr-boot.sh tftp artifacts/buildroot/uImage-hi3531-dhb-ax
```

If the vendor U-Boot reports `PHY not link!` after a warm reboot, hard-reset
the DVR, interrupt autoboot, and rerun the command from the U-Boot prompt.

The minimal image carries its root filesystem and must use the initramfs root
mode. It can be loaded over TFTP or, after installation, from USB:

```sh
tools/dvr-boot.sh tftp artifacts/buildroot-minimal/uImage-hi3531-dhb-ax-minimal --root initramfs
tools/dvr-boot.sh usb uImage-minimal --root initramfs
```

It has an Ethernet driver and obtains the same DHCP reservation as the main
image by applying the board's factory MAC address before `udhcpc` starts.
Dropbear uses the same machine-local host and authorized keys as the main image,
so `ssh -o BatchMode=yes root@dvr` works after DHCP completes. SATA and USB
are built in solely to prepare the approved storage devices; GPIO and I²C stay
excluded. The UART is the fallback when networking is unavailable.

Run `tools/dvr-boot.sh --help` for image checks, root selection and other
options.

## Installing the USB and HDD system

The normal Buildroot system uses the USB kernel and HDD root. Boot the minimal
initramfs, then partition both devices and install a clean system from the
development host:

```sh
tools/dvr-boot.sh tftp artifacts/buildroot-minimal/uImage-hi3531-dhb-ax-minimal --root initramfs
tools/dvr-prepare-storage.sh --destroy-all-data
tools/dvr-install-system.sh
```

Both full-install commands require hostname `minimal` and `rootfs` mounted at
`/`; they reject production HDD and NFS roots. The first command destroys and
recreates both approved storage devices. It is not part of routine deployment.
The second stages the production `rootfs.tar` and uImage in RAM, reformats the
existing HDD partition, installs the root filesystem, and updates the USB
uImage. It leaves the minimal image running. For kernel-only iteration from
either the HDD or NFS system, use:

```sh
tools/dvr-install-system.sh --kernel-only
```

Install the diagnostic image beside `/uImage`, without touching the HDD or
replacing the production kernel, with:

```sh
tools/dvr-install-system.sh --minimal
```

Read each tool before changing its device-identification checks.

## NFS development and recovery

The Raspberry Pi can export a root filesystem for development, provisioning or
recovery:

```sh
scripts/buildroot.sh
scripts/publish-nfs-root.sh
```

Boot that root with `tools/dvr-boot.sh usb --root nfs`. For ordinary driver
work, copy specific modules or files rather than republishing the complete
root filesystem.

## Protecting the factory flash

The USB drive and SATA HDD are approved Linux storage. The SPI NOR, NAND and
saved U-Boot environment are not.

- Never run `saveenv`, `sf write`, `sf erase`, `nand write`, `nand erase`,
  `flashcp`, `flash_eraseall`, `nandwrite`, or similar commands.
- Do not modify the verified originals under `../dhb-ax-guide/backups/`.
- Access helpers do not enforce this boundary. Check commands before sending
  them to U-Boot or Linux.

Volatile `setenv`, RAM loading and `bootm` are allowed; do not follow them with
`saveenv`. Normal filesystem work on the USB drive and HDD is allowed.
