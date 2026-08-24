# Plan: drive dvr-boot with Pexpect

`tools/dvr-boot.exp` uses Tcl but polls `tmux capture-pane` rather than using
Expect as a stream matcher. Replace the polling with Pexpect reading live pane
output from `tmux pipe-pane`.

## Implementation

Add `tools/dvr_boot.py` alongside the existing tool. Keep `tools/dvr-boot.sh`
and `tools/dvr-boot.exp` unchanged until the candidate has run successfully on
the DVR.

The Python helper will retain the existing command line and boot sequence:

- perform the Pi, tmux, image and TFTP preflight checks;
- create the existing per-session console lock;
- create a FIFO inside the lock and open it read-write;
- direct `tmux pipe-pane` output into the FIFO;
- use `pexpect.fdpexpect.fdspawn` to wait for console prompts and results;
- continue sending input with literal `tmux send-keys` calls;
- append the raw console stream to the optional transcript;
- disable the pane pipe and remove the FIFO and lock on exit.

The FIFO begins with live output, so old tmux scrollback cannot satisfy a wait.
Prompt patterns will tolerate ANSI CSI sequences and repeated carriage returns
on either side of a line without trying to normalize the entire console stream.

The persistent tmux session remains the only UART owner. The helper must reject
a pane that already has a pipe instead of replacing it. It must not call
`saveenv` or write board flash or storage.

## PHY recovery

If TFTP reports `PHY not link!` and returns to the U-Boot prompt, run:

    mii write 1 e 0
    mii write 1 0 1140

Wait three seconds, then retry the same TFTP command once. If the retry reports
the same failure, stop and request a hard reset.

## Verification

Before using the DVR, run one throwaway-tmux smoke test to confirm that live
pane output is matched, stale scrollback is ignored, the transcript receives
data, and cleanup removes the pipe and lock.

After the user confirms the candidate is ready for live testing:

1. Run its read-only preflight.
2. Complete one USB boot and one TFTP boot.
3. Reproduce the warm-reboot PHY failure and confirm the retry succeeds.

Only then switch `tools/dvr-boot.sh` to the Python implementation and remove
`tools/dvr-boot.exp`.
