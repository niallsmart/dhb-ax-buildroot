# Configuration-driven DVR staging and booting

## Summary

Split deployment from booting while having both commands consume the same
named TOML profiles:

```sh
tools/dvr-stage.sh [--check] [--kernel-only] PROFILE
tools/dvr-boot.sh [--check] [--transcript FILE] PROFILE
```

`dvr-stage` prepares configured artifacts. `dvr-boot` drives the console and
either boots an already-staged kernel or leaves the board at U-Boot, according
to the profile.

## Configuration

- Store profiles under `tools/configs/<name>.toml`.
- Add these initial profiles:
  - `main-usb-hdd`: USB kernel and HDD root.
  - `main-tftp-nfs`: TFTP kernel and NFS root.
  - `minimal-tftp`: TFTP kernel with embedded initramfs.
  - `minimal-usb`: USB kernel with embedded initramfs.
  - `uboot`: interrupt autoboot and leave the board at the U-Boot prompt.
- Require `boot.action = "kernel"` or `"prompt"` so prompt-only behavior is
  explicit rather than inferred from the profile name.
- Use `${local.*}` for machine-local values and `${section.key}` for references
  within a profile.
- Represent kernel boot arguments as an array joined with single spaces.

```toml
[boot]
action = "prompt"
```

Kernel profiles additionally contain `kernel`, `rootfs`, and boot-argument
fields.

## Implementation

- Add one small shared Python loader for TOML parsing, interpolation, and
  action/source/root-specific validation.
- Implement `dvr-stage`:
  - Kernel profiles always stage the configured kernel.
  - TFTP kernels are installed atomically beneath the Pi's `/srv/tftp`.
  - USB kernels are installed atomically on the validated USB boot filesystem
    and require a reachable Buildroot system.
  - NFS roots are published to the configured export while retaining the
    active-client guard.
  - HDD roots are reformatted and installed while retaining the
    minimal-initramfs, mount, device, and partition checks.
  - Initramfs roots require no separate action.
  - `--kernel-only` skips NFS publication or HDD-root replacement.
  - Prompt-only profiles report that they contain no stageable artifacts and
    exit successfully.
- Keep `dvr-prepare-storage.sh` separate because repartitioning both physical
  devices remains an exceptional operation.
- Implement `dvr-boot`:
  - Load and validate the profile, acquire the tmux pipe, identify the current
    console state, reboot when necessary, and interrupt autoboot.
  - For `action = "prompt"`, confirm the U-Boot prompt, cleanly release the
    pipe and lock, and leave the persistent tmux console at that prompt.
  - For `action = "kernel"`, set and verify the configured boot arguments,
    load the configured USB or TFTP target, run `bootm`, and wait for the
    configured login.
  - Retain transcript support, prompt handling, PHY recovery, timeouts, and
    cleanup.
  - Never stage artifacts or save the U-Boot environment.
- `--check` performs non-mutating configuration and environment preflight
  checks.
- After live validation, remove `dvr-install-system.sh`,
  `publish-nfs-root.sh`, and `dvr-boot.exp`; switch the public boot wrapper to
  Pexpect and update README and Justfile commands.
- Update AGENTS with `tools/dvr-boot.sh uboot` as the standard way for agents
  to reach U-Boot. Direct agents to attach with `just dvr-console` afterward
  and avoid ad-hoc reboot/autoboot handling.

## Test Plan

- Add focused host tests for profile loading, interpolation, action-specific
  validation, `--kernel-only`, and prompt-only staging.
- Retain the tmux pipe-pane smoke test.
- Before cutover, validate:
  - `dvr-boot uboot` from vendor Linux, Buildroot Linux, and an existing U-Boot
    prompt.
  - Stage and boot `minimal-tftp`.
  - Stage and boot `main-tftp-nfs` from a non-NFS-root system.
  - Stage `main-usb-hdd --kernel-only` and boot it.
  - Stage and boot `minimal-usb`.
  - With separate authorization, fully stage `main-usb-hdd` from the
    minimal initramfs and boot the resulting system.
- Keep existing tools until their corresponding replacement paths pass live
  testing.

## Assumptions

- A normal kernel-profile stage prepares the kernel and complete external root
  filesystem.
- `--kernel-only` is the sole staging-content override.
- `dvr-boot` never stages artifacts.
- Development NFS uses a TFTP kernel.
- Invoking full staging for an HDD-root profile authorizes reformatting the
  validated root partition, subject to the existing safety checks.
- The `uboot` profile performs no U-Boot configuration and sends no command
  after the prompt is reached.
