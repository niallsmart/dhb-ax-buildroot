# SSH over the serial console

```text
user ssh -> proxy ssh to Pi -> socat -> UART -> sshd -i
```

`user ssh` is the user’s SSH client connecting to the DVR. `proxy ssh` is the SSH process the Mac launcher starts to connect to the Pi and carry the user ssh stream.

The UART carries SSH bytes, not IP. OpenSSH runs directly on the DVR console; there is no loopback listener or DVR transport relay.

For every command, redirection, and cleanup step, see the [line-by-line script walkthrough](serial-ssh-scripts.md).

## Setup

Build and boot the image using `scripts/buildroot.sh`, `tools/dvr-stage`, and `tools/dvr-boot`. OpenSSH replaces Dropbear for ordinary network SSH as well. Password and keyboard-interactive authentication are disabled; root uses public keys.

The post-build script installs `authorized_keys` and `ssh_host_{rsa,ecdsa,ed25519}_key` from the ignored `artifacts/local/ssh/` directory. The existing DVR keys were converted from Dropbear format, preserving the host identity and known-hosts verification.

Install the Pi script after editing it. The Pi needs Bash, socat, flock, and permission to open `/dev/serial0`:

```sh
. ./local.env
ssh "$DHB_AX_PI_IPADDR" 'mkdir -p ~/.local/bin'
scp tools/dvr-serial-uart "$DHB_AX_PI_IPADDR":.local/bin/dvr-serial-uart
```

Add this to the Mac's `~/.ssh/config`, using the repository's absolute path:

```sshconfig
Host dvr-serial
    HostName dvr
    User root
    HostKeyAlias dvr
    ProxyCommand /absolute/path/to/dhb-ax-buildroot/tools/dvr-serial
    ControlMaster auto
    ControlPath ~/.ssh/dvr-serial.sock
    ControlPersist 10m
    ServerAliveInterval 10
    ServerAliveCountMax 3
```

## Use

Leave the DVR at an idle Buildroot root console shell and release picocom first:

```sh
ssh dvr-serial
ssh dvr-serial uname -a
scp example.bin dvr-serial:/run/example.bin
```

Establish the first connection before starting others. Later clients share it. The Pi lock rejects a second transport if startup races; it does not coordinate unrelated console programs.

Closing a client leaves the connection available for ten minutes after the last client exits. Release the UART immediately with `ssh -O exit dvr-serial`, then allow cleanup before opening picocom or using the boot tools. Ordinary network `ssh dvr` is independent.

## How it works

`tools/dvr-serial` reads the Pi address from `local.env` and runs the Pi script through proxy ssh. It ignores hangup so the final disconnect can drain.

`tools/dvr-serial-uart` locks the UART and configures raw 115200 baud. It asks the DVR shell to save its settings, disable echo, and invoke the helper, restoring settings afterward. It waits one second, then runs socat. The user ssh client reads the console preamble and server greeting itself. There is no custom readiness marker or greeting parser.

`/usr/sbin/dvr-serial-serve` saves the console settings, disables console logging, configures raw mode, and runs `sshd -i`. Cleanup stops the server, discards queued serial data, and restores terminal settings and normal kernel logging (`printk` = `7 4 1 7`, `ignore_loglevel` = `N`). Socat is used only for the brief cleanup drain, not for the DVR transport. Diagnostics go to `/run/dvr-serial.log`.

The serial server uses ten-second SSH keepalives with three missed replies and a 60-second authentication grace period. These settings are specific to the UART instance. The regular network server uses the shared public-key-only configuration.

## Limits

The one-second delay assumes normal startup on an idle root shell; it is not a readiness check. It lets the helper configure raw mode before binary data arrives. The foreground shell waits for the helper; it does not compete with sshd for input. All clients share roughly 11.5 kB/s per direction before SSH overhead. Heavy output can delay other clients and leave a long backlog after Ctrl-C. OpenSSH only sends its server keepalive probes after an idle poll; continuous UART output can prevent those probes. If the Mac/Pi connection disappears during sustained output, automatic recovery is not guaranteed. Stop the Mac transport first, then use ordinary network SSH to identify and terminate the `dvr-serial-serve` helper; its trap restores the console.

Unrelated console writes can corrupt the transport. Cleanup cannot survive a DVR crash or SIGKILL of the helper. No factory flash or saved boot environment is changed.
