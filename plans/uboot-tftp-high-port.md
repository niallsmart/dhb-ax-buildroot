# Vendor U-Boot TFTP on an unprivileged port

## Goal

Load a kernel with the vendor U-Boot TFTP client while the host server listens
on an unprivileged UDP port. Keep the change entirely in RAM: never run
`saveenv` or write SPI NOR, NAND, USB or HDD storage.

Do not test this without explicit authorization and exclusive access to the
DVR console. A typo in a code address or instruction can require a hard reset.

## Verified vendor behaviour

The running TVR build accepts an arbitrary volatile `tftpdstp` environment
variable, but ignores it. With `tftpdstp=1069`, a live test sent the RRQ to the
Pi's normal UDP/69 TFTP daemon; a simultaneous UDP/1069 listener received
nothing. The saved factory image also lacks the `tftpdstp` string, consistent
with `CONFIG_TFTP_PORT` being disabled.

The matching source sets `TftpServerPort` to 69 in `TftpStart()`. Static
disassembly of the verified SPI-NOR backup identifies the corresponding
instruction in the factory binary:

| Item | Value |
| --- | --- |
| Runtime address | `0x80803cf0` |
| Factory word | `0xe3a03045` |
| Factory instruction | `mov r3, #69` |
| UDP/1069 word | `0xe300342d` |
| UDP/1069 instruction | `movw r3, #1069` |

The next relevant store writes `r3` to `TftpServerPort`. After the first TFTP
response, the existing implementation adopts the server's transfer-ID port in
the normal way.

## Why the CLI should be sufficient

The factory image is linked and runs from DDR at `0x80800000`. Its startup code
disables the L1 instruction and data caches, and the binary does not include
the `icache` or `dcache` commands. A verified `mw.l` change should therefore be
visible when `TftpStart()` next executes, without a separate RAM patcher or
cache-maintenance stub.

## Proposed procedure

Use separate, prefixed U-Boot commands; do not combine the writes into a
multi-command line. First require the exact factory word:

```text
 md.l 80803cf0 1
```

Stop unless the result is exactly `e3a03045`. Patch and read back UDP/1069:

```text
 mw.l 80803cf0 e300342d 1
 md.l 80803cf0 1
```

Set `ipaddr`, `netmask`, `serverip` and the verified factory `ethaddr` only as
volatile variables. Processes on the macOS host can bind UDP/1069 without
privileges. The first inbound use may display a native macOS firewall dialog;
have the user approve it before interpreting a timeout as a DVR or TFTP
failure. Then use the ordinary U-Boot command:

```text
 tftp 82000000 IMAGE
```

Verify the received size and compare U-Boot `crc32` with the host CRC before
booting. Restore and read back the original instruction whether TFTP succeeds,
fails or is interrupted:

```text
 mw.l 80803cf0 e3a03045 1
 md.l 80803cf0 1
```

Also restore any temporary network variables. Do not call `saveenv`.

## Automation and recovery

A host controller should enforce the original-word check, patch readback,
payload CRC, cleanup restoration and final readback. If TFTP hangs, send
Ctrl-C before restoring the word. If the prompt or instruction readback is
lost, hard-reset the DVR; the patch is volatile and the SPI-NOR image remains
unchanged.

The vendor PHY can fail after a warm reset. Treat `PHY not link!` or a request
that emits no packets as a separate Ethernet problem and use a physical reset
before judging the port patch.

The earlier Mac-based listener attempts did not receive packets, but the host
firewall had not been approved through its native dialog. Those attempts are
inconclusive and do not show that macOS blocks non-privileged listeners.

## Status

The binary address and replacement opcode are statically verified, and the
factory build's disregard of `tftpdstp` is hardware-verified. The one-word CLI
patch itself has not yet been executed on the DVR.
