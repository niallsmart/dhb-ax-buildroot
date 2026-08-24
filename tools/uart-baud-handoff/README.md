# RAM-only UART baud handoff

This directory contains the tooling used to move the DHB_AX vendor U-Boot
console from its factory 115200 baud configuration to a faster rate without
changing U-Boot, its saved environment, or flash. It also contains a small
RAM-only YMODEM-G receiver that can load a kernel image substantially faster
than the vendor `loady` command.

The verified fast path runs at 2 Mbit/s and transfers the 6,882,783-byte
minimal kernel image in about 35.6 seconds, at an effective payload rate of
about 1.55 Mbit/s. The receiver restores the exact factory UART register state
and returns to the U-Boot prompt after each successful transfer.

## Safety and prerequisites

All device-side code is loaded into RAM and all UART changes are volatile.
Nothing here needs or permits `saveenv`, flash writes, NAND writes, or storage
writes.

Before using the controller:

- Obtain exclusive access to the Raspberry Pi UART at `/dev/serial0`. Stop or
  detach any `picocom`, tmux, or other process that owns it.
- Have the DVR stopped at the vendor `hisilicon #` U-Boot prompt at the factory
  115200 baud setting. Do not reset a running system merely to run a test;
  arrange a physical reset with the operator when another live test is needed.
- Keep physical reset access available. A failed baud handoff can make the
  prompt inaccessible until the board is reset and autoboot is interrupted.
- Use raw 8N1 with software and hardware flow control disabled. The board has
  no RTS/CTS connection. The controller configures these settings itself.

The vendor console sometimes loses the first character of a command. The
controller prefixes its U-Boot commands with a space to avoid that problem.

## Files

| File | Purpose |
| --- | --- |
| `stub.S` | Position-independent 1 KiB UART clock/divisor handoff and restoration stub |
| `link.ld` | Linker script for the handoff stub |
| `loader.c` | Freestanding RAM-only YMODEM-G receiver |
| `loader-link.ld` | Fixed-address layout for the receiver and its parameters |
| `serial_test.py` | Raspberry Pi controller, YMODEM sender, tests, CRC checks, and timing |
| `build.sh` | Reproducible build and static checks using the shared Buildroot SDK |

## Building

Build the shared toolchain first if its SDK export is not already staged:

```sh
scripts/buildroot.sh --config toolchain
```

The expected SDK archive is:

```text
artifacts/toolchain/arm-buildroot-linux-musleabihf_sdk-buildroot.tar.gz
```

Build both RAM programs from the repository root:

```sh
tools/uart-baud-handoff/build.sh
```

The script extracts and relocates the Linux-hosted SDK inside the existing
Buildroot container, then writes its results under
`artifacts/uart-baud-handoff/`. The two files used by the controller are:

```text
artifacts/uart-baud-handoff/uart-stub-template.bin
artifacts/uart-baud-handoff/uart-ymodem-g-loader.bin
```

The build enforces exact 1 KiB and 16 KiB image sizes and rejects relocations
or undefined loader symbols. It also emits ELF files, disassemblies, and a
`readelf` audit for inspection.

## How the handoff works

UART0 is a PL011 at `0x20080000`. Factory U-Boot leaves it on a nominal 3 MHz
clock with IBRD/FBRD `1/40`, producing 115200 baud. The matching vendor source
has an empty `serial_setbrg()`, so the apparent baud argument accepted by
`loady` does not reprogram the hardware.

The handoff stub switches the UART to the 155 MHz APB-derived clock and writes
calculated PL011 divisors. It waits for pending U-Boot output to leave the
transmitter, preserves the line-control register, changes the clock and
divisors while the UART is disabled, waits two seconds for the host to switch
rates, and returns through U-Boot's `go` command.

One position-independent stub is parameterized by four little-endian 32-bit
words at image offset `0x100`:

| Offset | Field |
| ---: | --- |
| `0x100` | Magic `UART` (`0x54524155`) |
| `0x104` | IBRD, from 1 through 65535 |
| `0x108` | FBRD, from 0 through 63 |
| `0x10c` | Clock selector: `0` for the factory source, `1` for APB |

The built template deliberately contains zero divisors and cannot change the
UART until the controller validates and patches this record. For a conventional
`loady` test, the controller creates independent APB-115200 canary, target-rate,
and factory-115200 restoration profiles and verifies every RAM image with
U-Boot's `crc32` command.

## Streaming loader

The vendor YMODEM receiver waits for an ACK after every block, so throughput
stops scaling well below the UART wire rate. `loader.c` implements YMODEM-G:
it retains the YMODEM header, sequence/complement fields, per-block CRC16, EOT,
and final empty header, but streams the data blocks without per-block ACK
pauses. YMODEM-G has no retransmission after streaming starts; any sequence,
CRC, timeout, or UART error cancels the complete transfer instead.

The loader is linked at `0x83000000`, occupies 16 KiB, and has a 32-byte
little-endian record at image offset `0x3000`:

| Offset | Field |
| ---: | --- |
| `0x3000` | Magic `YDMG` (`0x474d4459`) |
| `0x3004` | Parameter version, `1` |
| `0x3008` | Target IBRD |
| `0x300c` | Target FBRD |
| `0x3010` | APB-clock selector, required to be `1` |
| `0x3014` | Payload destination address |
| `0x3018` | Exact payload length |
| `0x301c` | Expected whole-payload CRC32 |

The controller patches the record, loads the receiver with ordinary YMODEM at
115200, and also preloads an independent restoration stub. The receiver then:

1. Verifies the exact factory UART baseline and saves all five relevant
   register values.
2. Switches to the target baud and waits two seconds.
3. Receives the contracted byte count while checking every block's CRC16 and
   calculating a whole-payload CRC32.
4. Restores the saved UART state, waits two seconds, and returns to U-Boot.
5. On any failure, sends eight CAN bytes and follows the same restoration path.

After a successful return, the controller reads back all five registers and
uses U-Boot CRC32 checks on the loader, restoration stub, and payload.

The streaming RAM map is:

| Address | Use |
| ---: | --- |
| `0x82000000` to below `0x83000000` | Allowed payload range |
| `0x83000000` to `0x83003fff` | 16 KiB loader image |
| `0x83003000` | Loader parameters within that image |
| `0x83010000` | Independent 1 KiB factory-115200 restoration stub |

## Running from the Raspberry Pi

Stage the controller and built images on the Pi:

```sh
scp \
  artifacts/uart-baud-handoff/uart-stub-template.bin \
  artifacts/uart-baud-handoff/uart-ymodem-g-loader.bin \
  tools/uart-baud-handoff/serial_test.py \
  raspberrypi:/tmp/
```

Check that the Pi can see the U-Boot prompt without changing its state:

```sh
ssh -o BatchMode=yes raspberrypi \
  'python3 /tmp/serial_test.py probe'
```

The controller has four actions:

| Action | Behaviour |
| --- | --- |
| `probe` | Checks for the 115200 U-Boot prompt |
| `commands` | Runs one or more prefixed U-Boot commands at 115200 |
| `run` | Exercises the parameterized handoff and vendor `loady`, then restores 115200 |
| `stream` | Uses the RAM-only YMODEM-G receiver, then restores 115200 |

For example, this performs a 64 KiB conventional YMODEM test at 230400 baud
and leaves the board at the restored U-Boot prompt:

```sh
ssh -o BatchMode=yes raspberrypi \
  'python3 /tmp/serial_test.py run \
    --target-baud 230400 \
    --payload-size 65536 \
    --payload-address 0x82010000'
```

To stream a real kernel at 2 Mbit/s, copy it to the Pi and pass its path:

```sh
scp artifacts/buildroot-minimal/uImage-hi3531-dhb-ax-minimal raspberrypi:/tmp/

ssh -o BatchMode=yes raspberrypi \
  'python3 /tmp/serial_test.py stream \
    --target-baud 2000000 \
    --payload-file /tmp/uImage-hi3531-dhb-ax-minimal \
    --payload-address 0x82000000'
```

This only loads and verifies the image in RAM; it does not boot it. The
`--reset-after` option is supported by `run`, not `stream`, and should be used
only when resetting the DVR is part of the authorized procedure.

Run `python3 serial_test.py --help` for all path, device, payload, and command
options. The defaults expect the staged binaries in `/tmp` and the UART at
`/dev/serial0`.

## Verified results

The conventional U-Boot `loady` sweep showed increasing protocol overhead as
the baud rate rose:

| Wire rate | Payload | Complete rate | Active data rate | Result |
| ---: | ---: | ---: | ---: | --- |
| 115200 | 32 KiB | 30.956 kb/s | 81.914 kb/s | CRC matched |
| 230400 | 64 KiB | 57.816 kb/s | 136.658 kb/s | CRC matched |
| 460800 | 128 KiB | 101.330 kb/s | 204.828 kb/s | CRC matched |
| 921600 | 256 KiB | 163.488 kb/s | 275.938 kb/s | CRC matched |
| 1.5 Mbit/s | 416 KiB | 252.281 kb/s | 411.507 kb/s | CRC matched |
| 2 Mbit/s | — | — | — | Isolated corrupted prompt; payload not sent |

The YMODEM-G loader subsequently sustained error-free transfers at 2 Mbit/s:

| Payload | Total time | Complete rate | Data rate | Result |
| ---: | ---: | ---: | ---: | --- |
| 416 KiB deterministic | 2.251754 s | 1,513.430 kb/s | 1,556.459 kb/s | CRC matched |
| 6,882,783-byte minimal uImage | 35.521684 s | 1,550.103 kb/s | 1,552.343 kb/s | CRC matched |

Five additional full-image runs at 2 Mbit/s all passed the protocol, payload
CRC, RAM-image CRC, and exact register-restoration checks. Their mean transfer
time was 35.562601 seconds and their mean effective rate was 1,548.321 kb/s.
Across those five repeats, 34,413,915 payload bytes moved without a detected
error. Together with the first full-image run, the same image completed six
times at 2 Mbit/s.

The tests establish 2 Mbit/s as a reliable operating point for the present
Pi-to-DVR connection. They do not establish a physical maximum; the original
sweep stopped at its first 2 Mbit/s anomaly, so 2.5 and 3 Mbit/s were not
tested.

## Host notes and recovery

The current controller relies on Linux `termios` baud constants exposed by the
Raspberry Pi. The standard Python `termios` module on the development macOS
host does not expose all of 460800, 921600, 1.5 Mbit/s, and 2 Mbit/s. Direct
macOS operation would need an `IOSSIOSPEED` implementation and a serial adapter
that supports the requested rate.

If a normal U-Boot YMODEM receive stalls before a handoff, several CAN
(`0x18`) bytes can cancel it. If a high-rate test fails, wait for the loader's
automatic restoration, return the host UART to 115200, and probe for the
prompt. The independent restoration stub remains in RAM at `0x83010000`, but
invoking it manually requires a working high-rate console. If neither console
rate is usable, ask the operator to hard-reset the DVR and interrupt autoboot.

The investigation history, formulas, register evidence, and full benchmark
record are in [`plans/uart-baud-handoff.md`](../../plans/uart-baud-handoff.md).
Reusable hardware conclusions are in the sibling guide's
[`doc/05-uart-console.md`](../../../dhb-ax-guide/doc/05-uart-console.md).
