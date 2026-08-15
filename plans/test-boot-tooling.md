# Test plan: dvr-boot.sh subcommand redesign

Exercises the `usb`/`tftp` subcommand interface in `tools/dvr-boot.exp` and
`tools/dvr-boot.sh` against the real DVR rig. Requires `local.env` in place
and `artifacts/buildroot/uImage-hi3531-dhb-ax` present from a build.

## Read-only (`--check`, safe, no reboot)

1. `usb --check` -- default USB image, default root (hdd)
2. `usb --root nfs --check` -- USB image, root overridden to nfs
3. `tftp --check` -- default local image (`artifacts/buildroot/uImage-hi3531-dhb-ax`)
4. `tftp <explicit path> --check` -- local image given explicitly
5. `tftp --root hdd --check` -- tftp source, root overridden to hdd
6. `usb --usb-device 0:2 --check` -- non-default USB device string, valid form

## Real (reboots the DVR)

7. `usb` -- boot from USB, default HDD root
8. `usb --root nfs` -- boot from USB, root overridden to NFS
9. `tftp` -- stage + TFTP boot, default NFS root
10. `tftp --root hdd` -- stage + TFTP boot, root overridden to HDD

None of the real variants write to the HDD or USB filesystem contents --
only `dvr-prepare-storage.sh`/`dvr-install-system.sh` do that -- so they
only overwrite the running kernel and root mount for the duration of each
test.
