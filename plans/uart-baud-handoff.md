# U-Boot UART baud-rate handoff

## Objective and status

Prove a faster, RAM-only U-Boot serial download path. The factory U-Boot and
its saved environment must remain unchanged. Never run `saveenv` or write SPI
NOR or NAND.

This work completed on 2026-08-24. The maintained result is the parameterized
1 KiB UART handoff stub and 16 KiB YMODEM-G receiver under
`tools/uart-baud-handoff/`. The receiver loaded the complete 6,882,783-byte
minimal uImage six times at 2 Mbit/s; the five-run repeat batch averaged
35.562601 seconds and 1,548.321 kb/s. Every run matched the payload CRC,
verified both RAM-resident helper images, restored the exact factory UART
register state, and returned to the 115200 U-Boot prompt.

The implementation and rerun instructions are documented in the
[tooling README](../tools/uart-baud-handoff/README.md). This file retains the
investigation, staged validation procedure, and detailed measurements. There
is no pending live UART test in the completed scope. Rates above 2 Mbit/s
remain untested, not failed; 2.5 and 3 Mbit/s would be separate signal-margin
work.

Do not try to reboot a running vendor system into U-Boot. When another live
test is authorized, ask the user to reset the board and interrupt autoboot.
Obtain explicit authorization and exclusive access before taking control of
the Raspberry Pi's `/dev/serial0`; do not terminate another console owner on
the basis of permission granted for an earlier test session.

## Verified behaviour

- UART0 is 115200 8N1 and has no flow control.
- The vendor U-Boot sometimes drops the first character of an interactive
  command. Prefix U-Boot commands with a space, for example
  ` loady 0x82000000`.
- A generated 1 KiB YMODEM transfer with `loady 0x82000000` at 115200 loaded
  into RAM successfully. U-Boot's `crc32` reported `b70b4c26` for the test
  payload. The host-side YMODEM sender must tolerate an ACK and a following
  `C` arriving in the same read. This receiver ACKs the first EOT directly;
  then send YMODEM's empty final header block.
- Cancel a running YMODEM receive with several CAN (`0x18`) bytes. When
  `loady` was called with a different baud argument, it then asks for ESC
  before returning to the prompt.

## Why `loady ADDR BAUD` cannot change the baud rate

The matching SDK source is under:

```
../dhb-ax-guide/Hi3531_V100R001C01SPC0D1/01.software/board/Hi3531_SDK_V1.0.D.1/
osdrv/uboot/u-boot-2010.06/
```

`common/cmd_load.c` accepts `loady [address] [baud]`, prints the requested
rate, changes only `gd->baudrate`, calls `serial_setbrg()`, and waits for CR.
After the transfer it performs the symmetric apparent switch back and waits
for ESC.

The PL011 implementation in `drivers/serial/serial_pl01x.c` defines
`serial_setbrg()` as an empty function. The UART hardware remains at its
boot-time 115200 setting. Thus this command is misleading:

```
 loady 0x82000000 230400
## Switch baudrate to 230400 bps and press ENTER ...
```

The DVR remains at 115200 while waiting for the CR. Switching the Pi to
230400 causes the handoff to fail.

`include/configs/godnet.h` also restricts `setenv baudrate` to 9600, 19200,
38400, 57600 and 115200. `loady` bypasses that validation but, because of the
empty driver method, does not actually configure any rate.

## UART clock and register values

UART0 is the PL011 at `0x20080000`. Relevant registers are:

| Register | Address | Value / purpose |
| --- | --- | --- |
| IBRD | `0x20080024` | Integer baud divisor |
| FBRD | `0x20080028` | Fractional baud divisor |
| LCR_H | `0x2008002c` | Existing 8N1/FIFO setting; preserve its value, but rewrite it to commit new divisors |
| CR | `0x20080030` | `0x301` enables UART, TX and RX |

The SDK configures `CONFIG_PL011_CLOCK` as half the bus clock. The documented
U-Boot CRG dump has `CRG+0x04 = 0x006c209b` and `CRG+0x28 = 0x00000023`, which
the SDK's `get_bus_clk()` macro resolves to a 310 MHz bus clock. That source
therefore calculates a 155 MHz PL011 clock, but the factory U-Boot does not
leave UART0 in that state.

Read-only U-Boot commands on the live 115200 console established:

| Register | Live value |
| --- | ---: |
| IBRD | `1` |
| FBRD | `40` |
| LCR_H | `0x70` |
| CR | `0x301` |
| CRG `+0xe4` | `0x0000e060` |

IBRD 1 and FBRD 40 imply a 2.9952 MHz clock at an exact 115200 baud, consistent
with a nominal 3 MHz UART source and normal baud error. CRG `+0xe4` has clock
select bit 13 set. This contradicts the matching SDK's `board_init()`, which
clears bit 13 with a comment saying that selects the APB clock. Prefer the live
register evidence over the early SDK source.

Use the PL011 formula from `serial_pl01x.c`:

```
IBRD = floor(UARTCLK / (16 * baud))
FBRD = round(64 * fractional( UARTCLK / (16 * baud) ))
```

| Clock source | Baud | IBRD | FBRD |
| --- | ---: | ---: | ---: |
| 3 MHz | 115200 | 1 | 40 |
| 155 MHz APB-derived | 115200 | 84 | 6 |
| 155 MHz APB-derived | 230400 | 42 | 3 |

The PL011 minimum divisor is 1, so the 3 MHz source cannot produce 230400;
its maximum is 187500. A 230400 test must switch CRG `+0xe4` bit 13 to the
APB-derived source as part of the same RAM-only handoff.

### First stub attempt and recovery

The first generated 230400 stub assumed the UART was already clocked at
155 MHz and wrote IBRD 42 and FBRD 3. Both 1 KiB stubs loaded successfully and
matched their expected U-Boot CRCs. After `go`, the Pi saw framing-like zero
bytes at 230400 and neither 230400 nor 115200 recovered the prompt. With the
live 3 MHz source, those divisors produce approximately 4.46 kbaud, explaining
the observation. A hard reset restored the original 115200 console. No
persistent state was changed.

## Do not use a chain of `mw.l` commands for the handoff

A direct sequence that disables UART0, writes the divisors and re-enables it
has no stable interval for the Pi to switch rates. It was attempted at 230400
and did not establish a readable link. It can leave the console inaccessible
until the board is hard-reset. The first-character input issue also makes a
multi-command U-Boot line fragile.

## RAM-only stub design

Write the stub as freestanding GNU ARM assembly, not C. Build it with the
shared cross-compilation SDK produced by the toolchain configuration's
`make sdk` and staged as:

```
artifacts/toolchain/arm-buildroot-linux-musleabihf_sdk-buildroot.tar.gz
```

The SDK contains Linux-host tools, so extract and relocate it inside the
project's existing Linux build container. Assemble for Cortex-A9 in ARM state,
link without libraries, extract only the executable section as a raw binary,
and pad the template to the already-proven 1 KiB YMODEM transfer size. Inspect
the linked ELF and disassembly before use: there must be no relocations,
external calls, stack use, literal pool, or unexpected loadable sections.

The stub should use only caller-saved registers. Before disabling UART0 it
must wait for `FR.BUSY` to clear so U-Boot's preceding output has left the
transmitter. Use the decrementing U-Boot timer value at `0x20000004` for the
handoff delay rather than relying on CPU-loop timing. Set `r0` to zero before
`bx lr` so U-Boot reports a successful return from `go`.

Compile the position-independent code once. A 16-byte little-endian parameter
record at image offset `0x100` contains:

| Offset | Field | Validation |
| ---: | --- | --- |
| `0x100` | Magic `UART` (`0x54524155`) | Must match |
| `0x104` | IBRD | `1..65535` |
| `0x108` | FBRD | `0..63` |
| `0x10c` | Clock selector | `0` = original 3 MHz, `1` = 155 MHz APB-derived |

The unparameterized template deliberately has zero divisors and therefore
returns failure without touching UART or CRG registers. The Pi controller
validates that pristine record, calculates the requested PL011 divisors, and
patches three independent 1 KiB profile images: APB-clock 115200 canary,
APB-clock target baud, and original-clock 115200 restoration. This keeps the
restoration path preloaded and CRC-protected while avoiding a rebuild for each
baud rate. The parameter record is part of each U-Boot CRC calculation.

Load the three profile images by the verified 115200 YMODEM path:

1. Load an APB-clock 115200 canary at `0x82000000`, an APB-clock target profile
   at `0x82001000`, and an original-clock 115200 restoration profile at
   `0x82002000`.
2. The common stub code must:
   - read and preserve the existing UART0 LCR_H value;
   - read and preserve the other fields in CRG `+0xe4`;
   - wait for UART0 `FR.BUSY` to clear;
   - write zero to UART0 CR;
   - clear CRG `+0xe4` bit 13 for the APB-derived clock, or set it for the
     original 3 MHz clock;
   - write the selected IBRD/FBRD values;
   - rewrite the preserved LCR_H value so the PL011 commits the new divisors;
   - write `0x301` to CR;
   - wait for at least one second using the already-running U-Boot timer; and
   - return with `bx lr`.

The profiles must preserve no persistent state and must not alter the line
configuration encoded in LCR_H, interrupt configuration, flash, or the U-Boot
environment. Rewriting the preserved LCR_H value is required for the PL011 to
commit IBRD/FBRD. `go` supplies a return address, so `bx lr` returns to U-Boot
after the delay.

The original staged validation established a command-response test and a
small YMODEM RAM transfer at 230400 before pausing. The higher-rate sweep and
YMODEM-G work were authorized and performed later. A failed test can require
a physical reset, so manual reset access remains a prerequisite for any future
live work.

## Original 230400 test procedure

This was the initial safety-gated procedure. It completed successfully; later
sections record the subsequently authorized higher-rate tests.

Configure the Pi UART as raw 8N1 with hardware flow control and all software
flow control disabled. The board has no RTS/CTS connection, and CR `0x301`
does not enable PL011 hardware flow control. YMODEM supplies block-level
pacing through ACK/NAK; its CRC and a final U-Boot CRC check detect transfer
errors.

1. At the original 115200, verify CRG `+0xe4`, IBRD, FBRD, LCR_H and CR. Load
   the canary, 230400 target and restoration profiles at `0x82000000`,
   `0x82001000` and `0x82002000`. Check each 1 KiB region with U-Boot `crc32`
   against its host-side expected value.
2. Invoke the canary. It clears CRG `+0xe4` bit 13 and writes IBRD 84 and
   FBRD 6 while the Pi remains at 115200. Stop unless U-Boot returns cleanly
   and readback confirms the selected clock and divisors.
3. Invoke the 230400 profile, switch the Pi UART during its timer delay, and
   verify U-Boot's return message and prompt at 230400.
4. Send a harmless prefixed U-Boot command at 230400 and verify its response.
5. Run ` loady 0x82003000` without a baud argument. Transfer a deterministic
   1 KiB payload at the actual 230400 hardware rate, then compare U-Boot's
   `crc32 82003000 400` with the host-side value. U-Boot will still describe
   this as 115200 because the RAM stub changes the PL011 registers without
   changing `gd->baudrate`; that text is expected and is not the wire rate.
6. Invoke the restoration profile at `0x82002000`. It sets CRG `+0xe4` bit 13
   and writes the observed original IBRD 1 and FBRD 40. Switch the Pi back to
   115200 during its delay, verify U-Boot's return and prompt, and read back
   the original clock selection and divisors.
7. For a standalone run, optionally issue prefixed ` reset` at 115200 to
   resume normal boot. During a sweep, leave U-Boot at the restored 115200
   prompt and start the next independently checked rate from there.

The initial run stopped after the 230400 restoration test as planned. It did
not include 460800 or 921600.

## Adaptive throughput sweep

Use payload sizes proportional to baud so the active data phase remains close
to four seconds. Each point independently checks the original registers,
preloads and CRC-verifies all three profiles, exercises the target baud, and
restores and verifies the exact factory 115200 state before proceeding.

| Target baud | Payload size |
| ---: | ---: |
| 115200 | 32 KiB |
| 230400 | 64 KiB |
| 460800 | 128 KiB |
| 921600 | 256 KiB |
| 1500000 | 416 KiB |
| 2000000 | 544 KiB |
| 2500000 | 704 KiB |
| 3000000 | 832 KiB |

Before the sweep, transfer 288 KiB at the verified 230400 rate. This crosses
YMODEM's 8-bit block-number wrap and separates any receiver wrap defect from a
high-baud UART failure. Stop the sweep at the first CRC, command-response,
profile, or restoration failure. A failed high-rate handoff may require the
user to reset the board and interrupt autoboot manually.

### Sweep result

The 288 KiB preflight completed at 230400 with CRC `8a238885`. It took
22.508272 seconds end-to-end and 17.276521 seconds in the active data phase,
giving 104.819 kb/s and 136.561 kb/s, respectively. This verified an 8-bit
block-number wrap before the rate sweep.

| Target baud | Actual baud | IBRD/FBRD | Payload | Total time | Active time | Complete rate | Active rate | CRC/result |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 115200 | 115198.811 | 84/6 | 32 KiB | 8.468221 s | 3.200244 s | 30.956 kb/s | 81.914 kb/s | `217726b2` |
| 230400 | 230397.622 | 42/3 | 64 KiB | 9.068273 s | 3.836483 s | 57.816 kb/s | 136.658 kb/s | `b11de6a1` |
| 460800 | 460966.543 | 21/1 | 128 KiB | 10.348103 s | 5.119312 s | 101.330 kb/s | 204.828 kb/s | `205fbff3` |
| 921600 | 921248.143 | 10/33 | 256 KiB | 12.827521 s | 7.600091 s | 163.488 kb/s | 275.938 kb/s | `c790bff6` |
| 1500000 | 1501210.654 | 6/29 | 416 KiB | 13.508228 s | 8.281451 s | 252.281 kb/s | 411.507 kb/s | `d5f01311` |
| 2000000 | 2000000.000 | 4/54 | Not sent | — | — | — | — | Corrupted prompt byte |

All five completed payloads matched their host CRCs. The controller reported
no packet retransmissions during those measured transfers, and every point
restored the complete original register state before the next one began. At
2 Mbit/s the stub returned `rc = 0`, but the expected `hisilicon #` prompt
arrived as `s<00>ilicon #`. The controller stopped before starting `loady`.
The CRC-verified restoration profile was then invoked directly at 2 Mbit/s;
it returned cleanly at 115200 and readback matched CRG `+0xe4`, IBRD, FBRD,
LCR_H and CR values `0x0000e060`, `1`, `40`, `0x70` and `0x301`.

At the end of this original `loady` sweep, the error-free tested ceiling was
therefore 1.5 Mbit/s, with 2 Mbit/s as the first observed unreliable point.
Later YMODEM-G tests described below sustained error-free transfers at
2 Mbit/s, so the corrupted prompt is an isolated observation rather than the
present verified ceiling. Per the sweep stop rule, 2.5 and 3 Mbit/s were not
attempted. The `loady` throughput scaling is sublinear because its receiver,
per-block ACK latency and CRC work increasingly dominate the wire time.

The first preflight attempt lost an ACK while loading the 1 KiB restoration
profile at the original 115200 rate, before any stub was invoked. Several CAN
bytes cancelled `loady` and recovered the prompt with the factory registers
untouched. The sender now retransmits the same numbered packet after an ACK
timeout, as X/YMODEM permits; the repeated preflight and full sweep completed
without a host-side retransmission.

## Protocol choice

U-Boot's `loadb` Kermit receiver was not pursued as the kernel-loading path.
Its acknowledged packet flow and escaping do not remove the round-trip pacing
that limited `loady`, and it would not make useful use of the verified high
wire rates.

YMODEM-G was selected because it keeps the already-tested YMODEM framing,
sequence checks, per-block CRC16, image name and length, and familiar transfer
termination while removing ACK latency from the data stream. The small
receiver and matching sender were implemented locally from the protocol
behaviour needed here; no third-party protocol code was imported. A whole-file
CRC32 contract and U-Boot CRC checks add end-to-end verification. YMODEM-G
cannot retransmit a bad streaming block, so any error cancels the transfer and
the complete image must be sent again.

A RAM-only TFTP implementation would require substantially more board-specific
code: Ethernet and PHY initialization, packet buffering, ARP, IP, UDP, TFTP,
timeouts, and cleanup. The existing vendor network stack makes a one-word,
RAM-resident CLI patch to its fixed destination port the smaller TFTP option.
That alternative, including the corrected macOS firewall constraint, is
recorded in the [high-port TFTP plan](uboot-tftp-high-port.md); its live
instruction patch has not been tested. It is independent of the completed
UART result.

## RAM-only YMODEM-G receiver

The per-block ACK latency in the vendor U-Boot `loady` receiver limits useful
throughput well before the UART wire rate. A separate freestanding receiver in
`tools/uart-baud-handoff/loader.c` implements YMODEM-G streaming while retaining
the familiar YMODEM framing and host-side CRC generation. It is fixed at
`0x83000000`, occupies a 16 KiB load image, and accepts this 32-byte parameter
record at image offset `0x3000`:

| Offset | Field |
| ---: | --- |
| `0x3000` | Magic `YDMG` (`0x474d4459`) |
| `0x3004` | Parameter version, `1` |
| `0x3008` | Target IBRD |
| `0x300c` | Target FBRD |
| `0x3010` | APB-clock selector, required to be `1` |
| `0x3014` | Destination address |
| `0x3018` | Exact payload length |
| `0x301c` | Expected whole-payload CRC32 |

The loader accepts destinations from `0x82000000` up to but not including its
own `0x83000000` address. It requires the exact observed factory UART baseline,
saves the complete CRG/divisor/LCR_H/CR state, switches to the requested APB
divisors, and requests streaming with `G`. Each 1 KiB block retains YMODEM's
sequence/complement and CRC16, while the sender does not wait for an ACK after
each block. The loader also calculates CRC32 as it writes the unpadded payload.
It accepts EOT only after the contracted byte count, validates the whole-image
CRC before acknowledging completion, processes the empty final header, and
then restores the exact saved UART state before returning to U-Boot. On any
protocol, timeout, UART or CRC failure it sends eight CAN bytes and performs
the same restoration.

The existing 1 KiB original-clock restoration profile is independently loaded
and CRC-checked at `0x83010000` before invoking the receiver. The controller
checks the loader, restoration image and destination with U-Boot CRC32, and
reads back all five UART-related register values after every successful run.
The SDK build fixes the entry point at `0x83000000`, places 1,700 bytes of code
in the only executable section, has no relocations or undefined symbols, and
places only the 32-byte record at `0x83003000`.

### Streaming results

The first 416 KiB run succeeded but retained a host `tcdrain()` after every
1 KiB frame. That recreated per-block pacing and delivered only 407.557 kb/s.
Changing the Pi sender to keep the tty continuously fed, while monitoring RX
for CAN cancellation, produced these verified results:

| Payload | CRC32 | Total time | Data time | Complete rate | Data rate |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 416 KiB deterministic | `d5f01311` | 2.971691 s | 2.891563 s | 1,146.779 kb/s | 1,178.557 kb/s |
| 6,882,783-byte minimal uImage | `02636914` | 47.061772 s | 46.987113 s | 1,170.000 kb/s | 1,171.859 kb/s |

Both rows above used 1.5 Mbit/s. Follow-up tests used the same payloads at an
exact 2 Mbit/s with IBRD/FBRD `4/54`:

| Payload | CRC32 | Total time | Data time | Complete rate | Data rate |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 416 KiB deterministic | `d5f01311` | 2.251754 s | 2.189503 s | 1,513.430 kb/s | 1,556.459 kb/s |
| 6,882,783-byte minimal uImage | `02636914` | 35.521684 s | 35.470431 s | 1,550.103 kb/s | 1,552.343 kb/s |

A five-run repeat batch then transferred the complete minimal uImage five more
times at 2 Mbit/s. Every run returned `rc = 0`, matched destination CRC32
`02636914`, and passed the loader, recovery-stub and exact factory-register
restoration checks:

| Run | Total time | Complete rate |
| ---: | ---: | ---: |
| 1 | 35.632043 s | 1,545.302 kb/s |
| 2 | 35.532168 s | 1,549.646 kb/s |
| 3 | 35.522123 s | 1,550.084 kb/s |
| 4 | 35.564505 s | 1,548.236 kb/s |
| 5 | 35.562168 s | 1,548.338 kb/s |

The batch mean was 35.562601 seconds and 1,548.321 kb/s. The time range was
35.522123–35.632043 seconds. In total it moved 34,413,915 payload bytes without
a detected error or protocol cancellation.

The full image was
`artifacts/buildroot-minimal/uImage-hi3531-dhb-ax-minimal`, with SHA-256
`a8db1e57fd68d6a8b93708b48c407c302e231796f2718a439ffe08f6b05251a8`.
Its host CRC matched U-Boot's CRC over `0x82000000..0x826905de`. The loader
returned `rc = 0`; CRG `+0xe4`, IBRD, FBRD, LCR_H and CR then read back as
`0x0000e060`, `1`, `40`, `0x70` and `0x301`. The benchmark did not boot the
image or write flash, environment, USB or HDD state.

The original handoff stub and the YMODEM-G receiver both wait two seconds
after changing the UART clock and divisors before emitting their first byte at
the new rate. Settling time therefore does not distinguish the earlier single
corrupted 2 Mbit/s prompt from the two successful streaming runs. The later
tests, including the five-run repeat batch, show that the link can sustain
2 Mbit/s, but do not establish whether the earlier byte error was random signal
corruption or another transient.

## Verified result

The revised procedure completed successfully on 2026-08-24. This run used the
three build-time variants that preceded the parameterized template:

- The three 1 KiB stubs were built with the shared Buildroot `make sdk`
  toolchain, contained one executable section and no relocations, and matched
  their expected U-Boot CRCs after YMODEM loading:
  - APB-clock 115200 canary: `dd9ff811`
  - APB-clock 230400: `4b91e60f`
  - original-clock 115200 restoration: `77860c10`
- The canary returned `rc = 0` with the Pi unchanged at 115200. Readback showed
  CRG `+0xe4` changed from `0x0000e060` to `0x0000c060`, IBRD/FBRD changed
  from `1/40` to `84/6`, and LCR_H/CR remained `0x70/0x301`.
- The high-rate stub returned `rc = 0` at 230400. Readback showed
  `0x0000c060`, IBRD 42 and FBRD 3.
- A deterministic 1 KiB YMODEM payload transferred at the actual 230400 wire
  rate to `0x82003000`. U-Boot reported CRC `b70b4c26`, matching the host.
- The restoration stub returned `rc = 0` at 115200. Readback exactly restored
  CRG `+0xe4 = 0x0000e060`, IBRD/FBRD `1/40`, LCR_H `0x70`, and CR `0x301`.
  Its RAM image still matched CRC `77860c10`.
- Prefixed ` reset` produced the normal factory U-Boot banner and boot path.

The reproducible stub source, build helper and Pi-side test controller are in
`tools/uart-baud-handoff/`. No environment, flash or storage writes are part
of the procedure.

### Parameterized-template refactor

The tooling builds one `uart-stub-template.bin` and the controller creates the
canary, target and restoration images by patching only the record at offset
`0x100`. Static checks with the shared SDK established that the template is
exactly 1 KiB, contains no relocations, and calculates the expected APB
divisors `84/6` and `42/3`. For that build, the generated profile CRCs are
`ddef20e4`, `2faee9be` and `7d418413`, respectively.

A live repeat run hardware-validated the parameterized template. All three
generated images matched those CRCs after loading. The canary returned at
115200 with APB divisors `84/6`; the target returned at 230400 with divisors
`42/3`; and a 1 KiB payload matched CRC `b70b4c26`. The restoration profile
then returned CRG `+0xe4`, IBRD, FBRD, LCR_H and CR to `0x0000e060`, `1`,
`40`, `0x70` and `0x301`, and its RAM CRC remained `7d418413`. The controller
exited successfully after issuing `reset` from the restored 115200 console.

### 64 KiB throughput follow-up

A second run transferred a deterministic 64 KiB payload to `0x82010000` at
230400. U-Boot received 64 STX data packets and reported CRC `b11de6a1`,
matching the host. Monotonic timing on the Pi measured:

| Interval | Time | Effective payload rate |
| --- | ---: | ---: |
| Complete YMODEM transaction, first header through final ACK | 9.068129 s | 57.817 kb/s (7.058 KiB/s) |
| Data-block phase, first 1 KiB block through final data ACK | 3.836316 s | 136.664 kb/s |

The complete-transaction figure includes approximately 5.23 seconds of header
and closeout handshaking. The data-phase figure describes sustained transfer
while the 64 payload blocks are moving. The sender observed no NAK-triggered
packet retries. The restoration stub again returned CRG `+0xe4`, IBRD, FBRD,
LCR_H and CR to `0x0000e060`, `1`, `40`, `0x70` and `0x301`, respectively,
before a normal U-Boot reset.

## Useful source locations

- `common/cmd_load.c`: high-baud `loady` handoff and restoration logic
  (lines 440–515 in the SDK tree).
- `drivers/serial/serial_pl01x.c`: PL011 initialisation and the empty
  `serial_setbrg()` (lines 115–186).
- `drivers/serial/serial_pl01x.h`: PL011 register offsets and CR bits.
- `include/configs/godnet.h`: clock calculation and baud-rate table.
- `../dhb-ax-guide/doc/17-register-dumps.md`: U-Boot CRG dump used for the
  155 MHz clock derivation.
