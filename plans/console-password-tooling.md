# Plaintext console password and machine-local access

## Goal

Store the Buildroot root password as `DHB_AX_ROOT_PASSWD` in `local.env`.
Use it to authenticate at the serial getty so `dvr-boot` can request a clean
reboot without SSH. Keep machine access details out of boot profiles.

## Implementation

- Treat `DHB_AX_ROOT_PASSWD` as plaintext rather than a precomputed hash. Pass
  it to `BR2_TARGET_GENERIC_ROOT_PASSWD` and let
  Buildroot derive the crypt hash with `host-mkpasswd`. Keep the build wrapper
  silent and confirm that the installed shadow entry contains a crypt hash.
  Retain the make-variable indirection so the tracked defconfigs and generated
  `.config` contain the variable reference rather than the plaintext.
- Load the Pi address, DVR address, netmask, Ethernet address and Buildroot
  password as shared machine-local settings. Send the password through tmux
  without placing it in command arguments, output or transcripts.
- Remove `[console]` and `[network]` from every profile. Resolve `${local.*}`
  boot-argument references from the shared settings.
- Have `dvr-boot` distinguish vendor and Buildroot login prompts, authenticate
  with the appropriate password, and issue a normal serial-console `reboot`.
  Remove the SSH reboot path and the `reboot -f` fallback for both Buildroot
  and vendor Linux; fail if a clean reboot does not reach U-Boot.
- Have `dvr-stage` use the machine-local Pi and DVR addresses for SSH/SCP.
  It performs no reboot today, so retain SSH for artifact transfer and remote
  installation rather than adding console control to the staging command.
- Update `local.env.example`, README and AGENTS for the new variable and
  profile shape.

## Minimal verification

- Load all checked-in profiles and run each tool's non-mutating `--check` path.
- Build the minimal image once and confirm its shadow entry accepts the
  configured plaintext password.
- From a Buildroot login prompt, run `dvr-boot uboot` and confirm serial login,
  clean shutdown, U-Boot interception, and no subsequent watchdog reset. Check
  that the password is absent from command output and an optional transcript.
