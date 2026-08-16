# Plan: drive dvr-boot from a console stream

`tools/dvr-boot.exp` runs under the expect interpreter but uses none of its
stream handling: it polls `tmux capture-pane` every 50 ms and reconstructs a
read position from typed markers. This plan covers moving it to `tmux
pipe-pane` into a FIFO, read through `spawn -open`, with `tmux send-keys`
still carrying input.

## Goals

1. Match against the console byte stream rather than rendered screen text.
   `configure_bootargs` currently compares a `printenv bootargs` value that
   tmux has rejoined from display wraps with `-J`; the stream carries the
   value whatever the pane width is.
2. Block on the descriptor instead of polling. `wait_pane` forks two
   `capture-pane` processes per 50 ms, around 9,600 across a 120 s `bootm`
   wait; an `expect` with `-re` branches and a `timeout` replaces it.
3. Write the transcript incrementally through `log_file`, so a run that is
   killed or that fails still leaves one, and so it does not depend on the
   session `history-limit` holding the whole boot.
4. Drop the per-command markers where stream position replaces them. The
   sacrificial leading token stays: it defends against the first character
   after an autoboot interrupt being dropped, which is a property of the
   DVR rather than of tmux.
5. Report a failing preflight only for conditions that actually block the
   run. `ssh_command`, `local_sha256`, `remote_sha256` and `stage_image`
   treat any stderr output as command failure, because Tcl `exec` raises on
   stderr regardless of exit status; a host-key warning or a sudo lecture is
   enough to abort a working rig.

## Non-goals

- The `dvr` tmux session stays sole owner of the UART. The tool reads the
  pane and sends keys; it does not open the serial port or spawn picocom.
- The `usb`/`tftp` command line, exit codes and preflight semantics stay as
  they are. `plans/test-boot-tooling.md` passes unchanged.
- No `saveenv`, no writes to board storage.

## Constraints established by experiment

Measured against tmux 3.6b and expect 5.45 (Tcl 8.5.9) with a throwaway
session standing in for the console.

- Lines arrive as `\r\r\n`: the console emits CRLF and the pty adds its own
  CR. A `\r?$` anchor fails on real output, so patterns end `*\r*$`.
- `pipe-pane` passes escape sequences through unfiltered, so an anchored
  pattern does not match a colourised line. Stripping them on the way into
  the FIFO leaves the pane itself untouched for anyone watching:

      tmux pipe-pane -o -t "$session" \
          "sed -u $'s/\033\[[0-9;?]*[A-Za-z]//g' >> $fifo"

- The FIFO is opened `r+`. Opening `r` blocks until a writer appears and
  reports EOF as soon as `pipe-pane` is toggled; RDWR holds a writer
  reference, so the spawn_id survives.
- `match_max` defaults to 2000 bytes, which a boot with `ignore_loglevel`
  slides patterns out of. Set it to 100000.
- A pane carries one pipe at a time, so enabling this one replaces whatever
  was there, and leaving it enabled makes tmux buffer into a FIFO with no
  reader. Turning it off belongs with the lock release.
- Nothing emitted before the pipe is enabled is recoverable. Setup order is
  lock, pipe, open, and only then the first `console_send`.

## Console state sync

The opening probe stays as it is: send `\r` and read the reply. Every state
the loop separates answers a bare CR -- U-Boot reprints its prompt and
interrupts a running countdown, a shell prints a newline and its prompt,
`login:` re-prompts, and `Password:` submits empty, fails, and returns to a
login prompt, which is itself a handled state. A console that stays silent
is the existing `could not identify the current DVR console state` case.

## Test cases

### Host-side, no DVR

A tmux session running a shell stands in for the console; a stub `ssh` early
in `PATH` stands in for the Pi.

1. Anchors: a line written as `\r\n` through a pty matches `*\r*$` and does
   not match `\r?$`.
2. Colour: a line wrapped in SGR sequences matches its anchored pattern with
   the filter in place.
3. FIFO lifetime: `pipe-pane` toggled off and on mid-run does not end the
   read; the same run continues matching afterwards.
4. `match_max`: a pattern still matches after 8 KB of intervening output.
5. Ordering: output written before the pipe is enabled is absent from the
   stream, and the probe reply that follows is present.
6. Bootargs readback: a fake console echoing a `bootargs=` value longer than
   the pane width is compared intact, with the pane at 80 and at 40 columns.
7. State sync, one case each: `hisilicon # `, `~ # `, `(none) login: `,
   `dhb-ax login: `, `Password: `. Each reaches the state the current loop
   reaches.
8. Empty-password path: `Password:` answered with `\r` reaches a login
   prompt within the retry budget, allowing for the busybox login delay.
9. Silent console: exits 5 with the state-identification message.
10. Stale scrollback: a pane preloaded with an old `# ` prompt and old
    markers does not satisfy the sync, since the stream starts at
    `pipe-pane`.
11. Stub `ssh` writing to stderr and exiting 0 counts as success, for each
    of the preflight console check, `tftpd-hpa` start, `sha256sum` readback
    and `stage_image` install.
12. Stub `ssh` exiting non-zero counts as failure, with its stderr shown.
13. Transcript is non-empty while the run is still going.
14. Transcript path in an unwritable directory fails during preflight.
15. Cleanup on normal exit, on `abort_boot`, and on SIGINT: pipe off, FIFO
    removed, lock released. Checked by running a second invocation after
    each.
16. Second concurrent invocation exits 4 on the lock.

### On the rig

17. `plans/test-boot-tooling.md` cases 1-10, unchanged.
18. Kernel panic reported as exit 9 rather than a boot timeout.
19. TFTP with a missing image: the transfer failure is reported, not the
    120 s timeout.
20. Ethernet unplugged during `tftp`: the PHY message is reported ahead of
    the generic transfer failure.
21. USB with an invalid partition: the load failure is reported.
22. SIGINT during `bootm`: cleanup as in 15, and the transcript holds the
    boot up to the interrupt.
23. Boot from the vendor 3.0.8 system and from Buildroot, covering the
    console-login and SSH-reboot paths.

## Acceptance

Cases 1-16 pass unattended and are cheap enough to rerun. Cases 17-23 pass
once on the rig. No `capture-pane` call remains in the boot path. A run
killed with SIGKILL mid-boot leaves a transcript covering everything up to
the kill.

## Sequence

The `exec` stderr fix (goal 5) lands first and on its own, since it changes
which rigs the tool considers healthy and is worth bisecting separately from
the read path.
