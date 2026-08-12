# Working on this repo

Start with `README.md` for what the project is, and `kernel-port/README.md` for
anything about the port itself. This file covers only how to work on the board
without breaking it.

## Talking to the DVR

The board's serial console is a picocom session running under tmux, started by
`just dvr`. Drive it with:

```sh
tools/dvr-console.sh 'cat /proc/mtd'
```

**Do not use `tmux capture-pane` directly.** It returns the entire scrollback,
so each read pulls in hundreds of lines of stale output from earlier commands —
it wastes context and makes it easy to read an old result as a new one. The
script brackets the command in start/end markers and prints only the text
between the last pair, so you get exactly one command's output. It polls for
completion rather than sleeping a fixed interval, so slow commands are not
truncated.

`SESSION` and `TIMEOUT` are environment overrides; the defaults are `dvr` and 20
seconds.

## Booting a kernel over TFTP (the Raspberry Pi)

Kernels are RAM-booted from a Raspberry Pi that acts as the TFTP server and hosts
the serial console. Reach it over SSH as `raspberrypi` (192.168.4.34 — this is
U-Boot's `serverip`). Its TFTP root is `/srv/tftp`, owned by root, so staging an
image needs `sudo`:

```sh
scp kernel-port/build/buildroot-artifacts/uImage-hi3531-dhb-ax-ethernet \
    raspberrypi:/tmp/img
ssh raspberrypi 'sudo install -m0644 /tmp/img /srv/tftp/uImage-hi3531-dhb-ax-ethernet'
```

Then, at the DVR's U-Boot prompt (`hisilicon #`), over the serial console:

```text
setenv ipaddr 192.168.7.241
setenv netmask 255.255.252.0
setenv serverip 192.168.4.34
setenv ethaddr 00:18:AE:3C:A2:49
tftp 0x82000000 uImage-hi3531-dhb-ax-ethernet
bootm 0x82000000
```

**`bootdelay` is 1 second.** To catch U-Boot you have to reboot the board
(`reboot` from Linux, or power-cycle) and spam a key on the serial line through
the whole reset — reacting to "Hit any key to stop autoboot" is too slow. Send a
space every ~0.25 s for 30 s, then look for `hisilicon #`.

### The TFTP gotcha: start tftpd-hpa first

`tftpd-hpa` on the Pi is not enabled at boot, so after the Pi restarts it is
**inactive** and every transfer stalls at `Downloading: *` with no data — the
board looks broken but the server simply is not listening. Start it before
booting:

```sh
ssh raspberrypi 'sudo systemctl start tftpd-hpa'
# verify: systemctl is-active tftpd-hpa; sudo ss -ulnp | grep :69
```

A quick way to tell the server apart from the board: `tftp 192.168.4.34` from
your own machine and `get` the image. If that times out too, it is the Pi, not
the DVR.

## Nothing writes to the board

The factory firmware still boots and the flash images in `backups/` are the only
copies of it. Kernels are loaded into DRAM over TFTP and run from there.

- Never write to the DVR's NAND, and never `saveenv` at the U-Boot prompt.
- Treat the attached SATA disk as read-only.
- `tools/dvr-console.sh` does not enforce any of this. It sends whatever it is
  given, so check a command before sending it.

The board may be running either the vendor firmware (Linux 3.0.8, `hi3531_*`
modules) or a ported mainline kernel. Check `uname -r` before drawing any
conclusion from what you find — they behave nothing alike.
