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
  `artifacts/debian/` contains ignored Debian rootfs outputs;
  `artifacts/toolchain/` contains the ignored shared SDK export, and
  `artifacts/legacy/` contains ignored historical outputs.



`local.env` is the gitignored machine-local configuration and needs to be
configured by the user. It carries the plaintext root password used for both
maintained serial consoles, and either build exits rather than proceed without
it. Each builder derives its installed crypt hash. Add
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
scripts/mmdebstrap.sh
```

The first bootstrap prepares sources and exits non-zero when the SDK is not
staged; the reported toolchain command is the next step. `main` is the default
configuration. `minimal` builds the self-contained storage-bootstrap image
with serial access, DHCP, Dropbear, and the approved SATA/USB storage paths.
Each configuration has a separate output volume, while downloads and the
compiler cache are shared. `--config NAME --clean` drops only the selected
output volume; `--distclean` drops all build, download and cache volumes.

The production image is `artifacts/buildroot/uImage-hi3531-dhb-ax`, and its
module archive is embedded in `artifacts/debian/rootfs.cpio.gz`. The
diagnostic image is
`artifacts/buildroot-minimal/uImage-hi3531-dhb-ax-minimal`.

Each userspace is emitted once, as a gzipped cpio. The same archive serves both
destinations: U-Boot loads it to RAM as an initramfs root, and `dvr-stage`
streams it onto the HDD partition.

## Commit Conventions

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

## Reporting findings

State the finding. Do not preface it with an account of how it was reached or
how it sits against what you expected: whether a fact was checked rather than
guessed, or overturned an earlier assumption, is not something the reader can
use.

    no:  Worth checking rather than guessing -- mmdebstrap's default already
         covers trixie-updates and trixie-security.
    yes: mmdebstrap's default already covers trixie-updates and
         trixie-security.

    no:  Decisive, and it points the other way from what I assumed: line 50
         deletes a file that is never created.
    yes: Line 50 deletes a file that is never created.

"it turns out", "as suspected", "interestingly" and "good news" are the usual
signs, along with any sentence that reports on the investigation rather than
its result.

Evidence is not narration. Name the command, file or hardware observation a
claim rests on, and say plainly when something is unverified, because that
changes how far the reader should trust it. What to leave out is the
commentary about the search itself.

## Message Tags

* When a message is tagged `#memory` respond from what is already in context. Do not make tool calls to service it. Memory of the tree goes stale, so flag any claim you would otherwise have checked.

* When a message is tagged `#q`, then just reply to the question without inferring an implied action. Prefer to answer from memory, but you can use tool calls when mmory is incomplete or stale.

## Performance Benchmarking

* Run long-running benchmark scripts in the background using the built-in monitor tool
* Prefer existing proven tooling vs home-rolling your own. Install what you need.
* If the benchmark can get wedged, detect that condition as soon as possible and exit early, so you don't keep the user waiting.
* If capturing output, tee to stdout/stderr as appropriate, so the user can observe progress.

## Python and Shell Scripts

### Guards

When a successful probe identifies an error condition, use the positive
command followed by an `&&` failure block. Avoid expressing the same guard as
an inverted command followed by `||`:

```sh
grep -q "^$device " /proc/mounts && {
	echo "$device is already mounted" >&2
	exit 1
}
```

If the guard is the final command in a script or function, follow it with `:`
so the expected no-match case does not become the caller-visible exit status.

### Checksums

Only perform checksums on files transferred over unreliable transports. You
can assume that files transferred via scp and rsync do not need checksum
verification.

## Working on the device

The board can run the vendor 3.0.8 kernel or the mainline port. Run `uname -r`
before interpreting runtime results.

## Diagnostics, debugging or benchmarking tools.

Prefer proven debugging tools, installed via the methods below. Only hand-roll your
own tools when there is clear reason or unique need.

* Debian: Install the `apt` packages
* Buildroot: Add to the appropriate Buildroot config
* Vendor Linux: Cross-compile statically linked binaries in Docker using the Buildroot SDK

## Talking to the DVR

### Serial console

Use the UART for U-Boot, boot logs, recovery, or when Linux networking or Dropbear
is unavailable.

Under Buildroot and Debian the console getty asks for a password: log in as
`root` with `DHB_AX_ROOT_PASSWD` from `local.env`. `dvr-boot` uses this
password when it must log in for a clean reboot; interactive `just dvr-console`
attaches need it as well.

The `dvr` tmux session owns the UART through one long-lived SSH and picocom
connection. Start or attach to it with `just dvr-console`. Leave it running.

- Use `just dvr-console` for an interactive console.
- Use `tools/dvr-stage.sh` to publish configured kernels and root filesystems.
- Use `tools/dvr-boot.sh` to boot a named profile or reach U-Boot.
- Use `tools/dvr-boot.sh --status` to identify the current console state.

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

### Maintained Linux userspaces

When Buildroot or Debian is running, use the SSH client directly through the
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

Staging and booting are separate. Both commands consume named TOML profiles
under `tools/configs/`. Stage artifacts when their configured destinations
need updating, then boot the same profile:

```sh
tools/dvr-stage.sh buildroot-tftp
tools/dvr-boot.sh buildroot-tftp
```

Automatic boot is deliberately deferred. Manually boot the installed USB
kernel and HDD root with:

```sh
tools/dvr-boot.sh buildroot-usb-hdd
```

Use the prompt-only profile whenever work requires a U-Boot prompt, then attach
to the persistent console. Do not implement ad-hoc reboot or autoboot handling
in agent commands:

```sh
tools/dvr-boot.sh uboot
just dvr-console
```

If the vendor U-Boot reports `PHY not link!`, `dvr-boot` reinitializes the PHY,
waits for link negotiation and retries the TFTP load. If that attempt still
finds the PHY down, it waits ten more seconds and makes one final attempt.

The vendor U-Boot console can drop the first character of a command. Prefix
interactive U-Boot commands with a space, for example ` bootm 0x82000000`.

The minimal image carries its root filesystem. It can be staged and loaded over
TFTP or USB:

```sh
tools/dvr-stage.sh minimal-tftp
tools/dvr-boot.sh minimal-tftp
tools/dvr-stage.sh minimal-usb
tools/dvr-boot.sh minimal-usb
```

It has an Ethernet driver and obtains the same DHCP reservation as the main
image by applying the board's factory MAC address before `udhcpc` starts.
Dropbear uses the same machine-local host and authorized keys as the main image,
so `ssh -o BatchMode=yes root@dvr` works after DHCP completes. SATA and USB
are built in solely to prepare the approved storage devices; GPIO and I²C stay
excluded. The UART is the fallback when networking is unavailable.

Run either tool with `--help` for profile and preflight options.

## Installing the USB and HDD system

Buildroot and Debian use the same USB kernel and separate HDD roots. Boot the
minimal initramfs, then partition both devices and install clean systems from
the development host:

```sh
tools/dvr-stage.sh minimal-tftp
tools/dvr-boot.sh minimal-tftp
tools/dvr-prepare-storage.sh --destroy-all-data
tools/dvr-stage.sh buildroot-usb-hdd
tools/dvr-stage.sh debian-usb-hdd
```

Storage preparation and full production staging require hostname `minimal` and
`rootfs` mounted at `/`; they reject production HDD roots. Preparation destroys
and recreates both approved storage devices and is not part of routine
deployment. Full production staging streams the selected archive onto its fixed
HDD partition and updates the USB uImage. It leaves the minimal image running.
For kernel-only iteration from a production HDD system, use:

```sh
tools/dvr-stage.sh --kernel-only buildroot-usb-hdd
```

Install the diagnostic image beside `/uImage`, without touching the HDD or
replacing the production kernel, with:

```sh
tools/dvr-stage.sh minimal-usb
```

Read each tool before changing its device-identification checks.

## TFTP initramfs development and recovery

U-Boot can load a complete root filesystem into RAM alongside the kernel, for
development, provisioning or recovery:

```sh
scripts/buildroot.sh
tools/dvr-stage.sh buildroot-tftp
```

Boot that root with `tools/dvr-boot.sh buildroot-tftp`. Debian uses the parallel
`debian-tftp` profile.

The root is unpacked into RAM and does not survive a reboot: anything edited on
the board is gone at the next boot, and changing it means rebuilding and
restaging. `dvr-boot` reads the transferred size back from U-Boot and appends
the matching `initrd=` argument, so the kernel finds the archive wherever it
landed.

Buildroot's archive is a few megabytes and stages in seconds. Debian's is around
79 MB, so its transfer takes minutes and it occupies about 214 MB of the board's
1 GB once unpacked. For ordinary driver work, copy specific modules or files
over SSH rather than restaging the complete root filesystem.

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
