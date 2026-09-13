# Serial SSH scripts, line by line

This walkthrough covers the three transport scripts as they appear in the repository on 2026-09-13. Every physical source line has a row, including comments, blank lines, and continued commands. Line numbers belong to the script, not this document. Update the tables when the scripts change.

The shared SSH configuration and image setup are described in [SSH over the serial console](serial-ssh.md). The flow is:

```text
user ssh -> Mac launcher -> proxy ssh to Pi
    -> Pi socat -> UART -> DVR sshd -i
```

`user ssh` is the user-started SSH client connecting to the DVR. `proxy ssh` is the SSH process started by the Mac launcher to reach the Pi. `user ssh` communicates through the launcher’s stdin/stdout, which `proxy ssh` carries to the Pi. OpenSSH ControlMaster sharing happens on the Mac; these scripts establish and carry one underlying transport.

File descriptors 0, 1, and 2 are stdin, stdout, and stderr. Both device-side scripts reserve descriptor 3 for the UART. A redirection such as `<&3` attaches that existing descriptor to a command’s stdin. Diagnostic output must stay on stderr or in a runtime log, because stdout is part of the SSH byte stream.

## Mac: `tools/dvr-serial`

Source: [tools/dvr-serial](../tools/dvr-serial).

| Line | Command / source text | Explanation |
| ---: | --- | --- |
| 1 | `#!/bin/sh` | Runs the script with the system POSIX shell. It does not need Bash-specific syntax. |
| 2 | `# Mac ProxyCommand: keep stdin/stdout available for the user ssh connection.` | Comment describing this file’s role as the user ssh client’s ProxyCommand. Its standard input and output must remain available for SSH protocol bytes. |
| 3 | `set -eu` | Enables `-e`, which exits on an unhandled command failure, and `-u`, which rejects expansion of an unset variable. Shell conditionals and explicit error-handling lists have exceptions to `-e`. |
| 4 | `repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)` | Finds the repository root: `$0` is this script’s path, `dirname` selects its directory, `/..` moves up from `tools`, and `pwd` prints the resulting absolute directory. `$(...)` captures that output. Clearing `CDPATH` prevents the caller’s directory-search configuration from changing `cd` behavior or printing extra output. Quoting protects spaces; `--` ends option parsing. |
| 5 | `. "$repo/scripts/lib.sh"` | Sources the repository’s existing shell helpers into this shell. This defines `require_env_file`; it does not start a subprocess or read the transport stream. |
| 6 | `require_env_file "$repo/local.env" DHB_AX_PI_IPADDR` | Loads the repository’s `local.env` and requires `DHB_AX_PI_IPADDR` to be nonempty. The helper reports missing configuration on stderr and exports the required variable. This is the address of the Pi, not the DVR. |
| 7 | `trap '' HUP # Let the final disconnect drain before the proxy ssh exits.` | Ignores SIGHUP. OpenSSH can send its ProxyCommand a hangup immediately after writing the final disconnect packet. Keeping this launcher and its child alive lets that packet and EOF drain through the proxy ssh connection. |
| 8 | `ssh -T -o BatchMode=yes -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \` | Starts the proxy ssh client. `-T` disables allocation of a remote pseudo-terminal, avoiding terminal processing of the user ssh bytes. `BatchMode=yes` prevents interactive authentication prompts. The remaining options request ten-second keepalive probes and permit three unanswered probes. The trailing backslash continues this command onto line 9. |
| 9 | `    "$DHB_AX_PI_IPADDR" 'exec ~/.local/bin/dvr-serial-uart'` | Supplies the Pi address and the remote command. The single quotes keep the command literal on the Mac; the Pi’s shell expands `~`. Remote `exec` replaces that shell with the installed Pi script. The proxy ssh process inherits stdin/stdout for transport and stderr for diagnostics. The Mac launcher waits for it as a foreground command. |

## Pi: `tools/dvr-serial-uart`

Source: [tools/dvr-serial-uart](../tools/dvr-serial-uart).

| Line | Command / source text | Explanation |
| ---: | --- | --- |
| 1 | `#!/bin/bash` | Runs Bash, which provides the `[[ ... ]]` test used below. |
| 2 | `# Pi: ask the idle DVR shell to lend us its UART, then forward SSH bytes.` | Comment identifying the Pi’s two responsibilities: ask the console shell to start the helper, then forward bytes. |
| 3 | `set -eu` | Exits on unhandled errors or unset-variable expansion. Deliberately handled failures below use `\|\| true` or an explicit conditional. |
| 4 | `trap '' HUP` | Ignores SIGHUP so a hangup does not prematurely cut off queued disconnect bytes. EOF or a relay error can still finish the script; INT and TERM are handled separately. |
| 5 | `exec 3<>/dev/serial0` | Opens `/dev/serial0` for both reading and writing as file descriptor 3. Here `exec` has no program argument: it changes this shell’s descriptors rather than replacing the shell. The descriptor remains open for the rest of the script. |
| 6 | `flock -n 3 \|\| { echo 'DVR UART is already in use' >&2; exit 1; }` | Takes an exclusive advisory lock on the UART’s open descriptor. `-n` makes the attempt fail immediately instead of waiting. On failure, the braced command group prints a diagnostic to stderr and exits with status 1. The lock coordinates cooperating instances of this script; it does not stop an unrelated program such as picocom from using the device. Closing all inherited copies of the locked descriptor releases the lock. |
| 7 | `saved_tty=$(stty -g <&3)` | Captures the UART’s current terminal configuration in the machine-readable format produced by `stty -g`. `<&3` temporarily makes the UART stdin for `stty`; the command’s stdout is captured in `saved_tty`, not sent into the transport. |
| 8 | `relay=` | Initializes an empty relay PID. This lets cleanup distinguish failure before socat was started from exit after it was started, and keeps `set -u` from rejecting the variable. |
| 9 | `cleanup() {` | Begins the cleanup function definition. Defining the function does not execute its body. |
| 10 | `    if [[ -n $relay ]]; then` | Checks whether a relay PID has been recorded. `-n` means the string is nonempty. |
| 11 | `        kill "$relay" 2>/dev/null \|\| true` | Sends SIGTERM, the default `kill` signal, to the recorded relay process. Errors such as “process already exited” are hidden and explicitly ignored so cleanup continues. |
| 12 | `        wait "$relay" 2>/dev/null \|\| true` | Waits for the relay child to exit and collects its status. A nonzero status or an already-completed child is not allowed to abort cleanup. |
| 13 | `    fi` | Ends the conditional portion of cleanup. |
| 14 | `    stty "$saved_tty" <&3` | Restores the saved Pi UART terminal settings. `<&3` points `stty` at the UART. This restores termios settings, not the DVR’s settings or arbitrary file-descriptor flags. |
| 15 | `}` | Ends the cleanup function definition. |
| 16 | `trap cleanup EXIT` | Registers cleanup to run when this shell exits, including after a normal `wait` return or an unhandled error. This does not cover SIGKILL or a machine failure. |
| 17 | `trap 'exit 1' INT TERM` | Handles SIGINT and SIGTERM by exiting with status 1. Exiting invokes the EXIT cleanup trap; there are no separate custom exit codes for the two signals. |
| 18 | `stty raw -echo -ixon -ixoff -crtscts cs8 -parenb -cstopb clocal 115200 <&3` | Configures the Pi UART for a byte stream: `raw` disables canonical line input, terminal signal processing, and normal byte translations; `-echo` disables echo; `-ixon -ixoff` disables software flow control; `-crtscts` disables hardware flow control; `cs8 -parenb -cstopb` selects eight data bits, no parity, and one stop bit; `clocal` ignores modem carrier status; `115200` sets the baud rate. `<&3` directs these settings to the UART. |
| 19 | *blank* | Blank line separating terminal setup from the DVR bootstrap command. |
| 20 | `# Restore DVR echo even if the helper is missing or fails to start.` | Comment explaining why the bootstrap command wraps the helper with its own save/restore pair on the DVR. |
| 21 | `printf '(s=$(stty -g); stty -echo; printf "\\n"; /usr/sbin/dvr-serial-serve; stty "$s")\r' >&3` | Sends one shell command to the DVR and ends it with carriage return, as if Enter had been pressed. The outer single quotes prevent `$()` and `$s` from being expanded on the Pi. On the DVR, the parenthesized subshell saves its terminal settings in `s`, disables echo, prints a separating newline, runs `/usr/sbin/dvr-serial-serve` in the foreground, and restores the saved settings after that command returns. The outer `printf` turns `\\n` into the `\n` escape used by the DVR’s inner `printf`. `>&3` sends the command to the UART. The original shell may echo this entire initial line before echo is disabled. If the helper is missing and the shell continues normally, the trailing `stty` still restores echo. The helper itself saves the already-echo-disabled settings, so this outer restoration is what returns the shell to its original echo state. |
| 22 | `# Allow terminal setup to finish before sending binary data. SSH handles the greeting.` | Comment explaining the deliberate startup delay. The foreground DVR shell waits for its command; the concern is finishing raw-mode setup before binary data arrives, not the shell concurrently reading commands. |
| 23 | `sleep 1` | Waits one second. This is an assumption about normal startup time, not a readiness check, retry loop, or acknowledgement from the DVR. The script has not yet started reading and forwarding the Mac client’s input. |
| 24 | `socat -b 1024 STDIO FD:3 <&0 &` | Starts socat in the background to copy bytes bidirectionally between `STDIO` (the proxy ssh connection) and `FD:3` (the already-open UART). `-b 1024` sets the transfer block size; it is not a global cap on every buffer in the SSH path. Explicit `<&0` preserves transport stdin for the background command, which could otherwise receive `/dev/null` in a noninteractive shell. The final `&` lets this shell retain control for cleanup. |
| 25 | `relay=$!` | Records `$!`, the PID of the most recently started background job: socat. |
| 26 | `wait "$relay"` | Waits for socat. A successful return reaches the end of the script; an unhandled nonzero return invokes `set -e`. Either route runs the EXIT cleanup trap. There is no parsing of the SSH greeting or subsequent transport bytes. |

## DVR: `/usr/sbin/dvr-serial-serve`

Source: [br2-external/board/dhb-ax/rootfs-overlay/usr/sbin/dvr-serial-serve](../br2-external/board/dhb-ax/rootfs-overlay/usr/sbin/dvr-serial-serve).

| Line | Command / source text | Explanation |
| ---: | --- | --- |
| 1 | `#!/bin/sh` | Runs the system POSIX shell, supplied by BusyBox in this image. |
| 2 | `# Run from the idle root console; lend its UART to one SSH connection.` | Comment stating the precondition: invoke this helper from the idle root console shell. It handles one underlying SSH transport, which may contain multiple multiplexed client sessions. |
| 3 | `set -eu` | Exits on unhandled errors and unset-variable expansion. Cleanup later disables `-e` so one failed cleanup step does not prevent the others. |
| 4 | `exec 2>>/run/dvr-serial.log` | Appends stderr to `/run/dvr-serial.log` for this shell and its children. As with the Pi’s descriptor setup, `exec` without a program changes the shell’s descriptors. `>>` creates the file if needed and appends rather than truncating it. `/run` is volatile runtime storage. stdout remains on the UART. |
| 5 | `[ -t 0 ] && [ -t 1 ] \|\| exit 2` | Requires both stdin (descriptor 0) and stdout (descriptor 1) to be terminals. The tests are joined with `&&`; if either fails, `\|\| exit 2` stops the helper before it changes console settings. |
| 6 | `exec 3<&0` | Duplicates stdin onto descriptor 3, retaining a reference to the console for the server and cleanup commands. Duplicating a descriptor shares the underlying open file description; it does not reopen the UART. |
| 7 | `saved_tty=$(stty -g)` | Saves the current console terminal settings in `stty`’s machine-readable format. In the normal bootstrap path, the outer DVR subshell has already disabled echo. This helper restores that state; the subshell subsequently restores the state from before echo was disabled. |
| 8 | `server=` | Initializes the server PID to an empty string so cleanup also works if startup fails before sshd is launched. |
| 9 | `cleanup() {` | Begins the cleanup function definition. |
| 10 | `    trap - EXIT` | Removes the EXIT trap while cleanup is running, avoiding another invocation if the cleanup path exits. |
| 11 | `    set +e` | Disables exit-on-error for the cleanup body. For example, a server that has already exited must not prevent restoration of the terminal and logging. |
| 12 | `    if [ -n "$server" ]; then kill "$server" 2>/dev/null; wait "$server" 2>/dev/null; fi` | If a server PID exists, sends it SIGTERM and waits for that child to finish. Both commands suppress their own stderr because an already-exited process is an expected possibility. This targets the per-connection inetd-mode server, not the ordinary network listener. |
| 13 | `    # Linux TCFLSH=0x540b, TCIOFLUSH=2: discard ciphertext, then drain late bytes.` | Comment identifying the Linux terminal ioctl used next. `TCFLSH` is the request number; `TCIOFLUSH` selects both the terminal’s input and output queues. |
| 14 | `    timeout 1 socat -u -T 0.2 STDIN,ioctl-int=0x540b:2 /dev/null <&3` | Runs a short cleanup drain. `STDIN,ioctl-int=0x540b:2` issues Linux `TCFLSH` with integer argument 2, discarding queued input and output before reading further. `<&3` supplies the UART as stdin. Socat’s `-u` selects one-way copying into `/dev/null`, so late serial input is discarded rather than interpreted by the shell. `-T 0.2` stops after roughly 0.2 seconds without data; the outer `timeout 1` bounds the attempt when data continues arriving. It is a cleanup operation, not a relay in the active SSH path. |
| 15 | `    stty "$saved_tty" <&3` | Restores the saved console termios settings using descriptor 3. Input was flushed first so queued encrypted bytes are not presented to the restored shell as commands. |
| 16 | `    echo "7 4 1 7" > /proc/sys/kernel/printk` | Restores chosen kernel logging defaults rather than previously saved values. The four numbers are current console log level 7, default level 4 for messages without an explicit level, minimum console log level 1, and default console log level 7. With `ignore_loglevel` disabled, a current level of 7 admits messages with numerically lower levels and excludes debug-level 7 messages. |
| 17 | `    echo N > /sys/module/printk/parameters/ignore_loglevel` | Writes `N` to disable the runtime `ignore_loglevel` override. Kernel console filtering then obeys the configured log level. This deliberately does not restore a previous `Y` value. |
| 18 | `}` | Ends the cleanup function. |
| 19 | `trap cleanup EXIT` | Registers cleanup for shell exit, including a server exit or unhandled setup error. The trap is installed before terminal or kernel logging state is changed. |
| 20 | `trap 'exit 1' HUP INT TERM` | Handles HUP, INT, and TERM by exiting with status 1, which invokes EXIT cleanup. SIGKILL cannot be trapped. |
| 21 | `printf N > /sys/module/printk/parameters/ignore_loglevel` | Disables `ignore_loglevel` before suppressing console logging. Without this, a boot-time override could make the kernel print messages regardless of the console log level. `printf N` does not add a newline; the parameter accepts this value. |
| 22 | `echo 0 > /proc/sys/kernel/printk` | Sets the current console log level to 0, suppressing normal kernel console output during transport. It does not disable the kernel log buffer, silence arbitrary userspace console writes, or guarantee that a crash cannot corrupt the stream. |
| 23 | `stty raw -echo -ixon -ixoff -crtscts cs8 -parenb -cstopb clocal 115200 <&3` | Configures the DVR console for raw 115200-baud, eight-bit, no-parity, one-stop-bit transport with echo and both kinds of flow control disabled. `clocal` ignores modem carrier status. `<&3` directs the operation to the console. The individual options have the same meanings as in the Pi table. |
| 24 | *blank* | Blank line separating console setup from starting the SSH server. |
| 25 | `# Inetd mode uses the UART directly; no listener or transport relay.` | Comment explaining that the server receives the UART directly. Neither a listening TCP socket nor a socat transport process is needed on the DVR. |
| 26 | `/usr/sbin/sshd -i -e -o ClientAliveInterval=10 -o ClientAliveCountMax=3 \` | Starts OpenSSH using its absolute executable path. `-i` selects inetd mode, using inherited input/output for one connection instead of creating a network listener. `-e` sends diagnostics to stderr, already redirected to the runtime log. The two `-o` options request ten-second client-alive probes with a count limit of three. These settings apply to this server invocation. The backslash continues the command on line 27. This is a foreground-mode server launched as a background child by the shell, not an `exec` replacement of the helper. |
| 27 | `    -o LoginGraceTime=60 <&3 &` | Sets an authentication grace period of 60 seconds. `<&3` explicitly attaches the console as stdin, while stdout is still the console inherited by the helper. The trailing `&` starts sshd asynchronously so the helper can retain its cleanup traps and server PID. OpenSSH’s grace-period scheduling may add a small timing variation. |
| 28 | `server=$!` | Records the PID of the background sshd invocation for cleanup. |
| 29 | `wait "$server"` | Waits for that server process. When it exits, the helper exits and runs cleanup. This line does not itself detect a lost Mac/Pi connection; that depends on sshd ending the connection, a signal to the helper, or manual recovery. |

## What the scripts do not guarantee

The one-second delay is not proof that raw-mode setup has completed. The foreground shell waits for its helper; the reason to delay is to avoid processing early SSH bytes with the old terminal settings. The Mac SSH client handles the console preamble and the server identification line; the Pi does not implement a synchronization or retry protocol.

Keepalive options do not impose a guaranteed wall-clock recovery deadline here. In the tested OpenSSH build, server probes depend on an idle poll. Sustained UART output can prevent those probes, so a lost transport can require manual helper termination through ordinary network SSH. Ctrl-C can stop the remote command while previously queued output continues draining.

Normal commands, multiplexed clients, binary/SCP transfers, and normal cleanup passed hardware checks. Automatic recovery during sustained output did not pass. A later reconnect after failed authentication also timed out waiting for the shared control socket; whether that was transport or test/control-socket behavior was not established. These are accepted experimental limitations, not guarantees supplied by the cleanup traps.
