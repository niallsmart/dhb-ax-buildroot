# DHB_AX V1.2: modern U-Boot by chainloading

Status: **plan only.** Nothing here has been built or run, and nothing has
been written to the DVR. Last updated 2026-08-04.

Companion to `investigation.md`, which holds the hardware survey, flash
layout and backup record; to `binwalk-notes.md`, which covers the inspection
tooling used to build the flash map below and where it misleads; and to
`../kernel-port/README.md`, which holds the Linux 6.18 bring-up.

The board boots vendor U-Boot 2010.06, built 2012-11-01, from SPI NOR. This
plan reaches a current U-Boot without replacing it: the vendor bootloader
stays where it is and hands control to a newer one.

## Why chainload rather than replace

The vendor U-Boot already knows how to initialise this board's DDR. That
knowledge is in the binary and, as far as we know, nowhere else. A
from-scratch port would have to redo it blind, which is the hardest and
least recoverable part of any bootloader bring-up.

Chainloading avoids it. By the time the second U-Boot starts, DRAM is
already up, so it can be built with low-level init skipped.

It also preserves recovery. The vendor U-Boot at `0x000000` is never erased,
so every failure mode still reaches a working `hisilicon #` prompt.

## What this buys

Present limitations traceable to the 2010 build:

| Limitation | Consequence today |
|---|---|
| `iminfo` missing | Downloaded images cannot be verified before `bootm`; byte counts checked by eye |
| `boot`, `bootd`, `run` non-functional | No scripting via environment variables |
| No FDT commands | The kernel port must append the DTB to the zImage rather than pass it |
| `tftp` upload is a vendor extension | Non-standard argument form; no `tftpput` |
| `bootdelay=1` | One-second window to interrupt autoboot |

A current U-Boot would also bring ext4 and USB loading, FIT images, and a
faster network stack.

None of this blocks the kernel port. It is a convenience and learning
exercise, not a prerequisite.

## Safety position

Stage 1 requires **no writes** and is compatible with the existing project
rule in `investigation.md`. Stages 2 and 3 require the owner to relax that
rule for two specific SPI regions.

The constraint that holds regardless:

> Never write to `0x000000-0x04FFFF`. That is the vendor U-Boot, the only
> boot path, and the only unrecoverable region on the chip.

## SPI NOR occupancy

2 MiB S25FL216K on chip select 1, 64 KiB erase blocks. Measured from the
verified cold backup by counting non-`0xFF` bytes per erase block.

| Range | Size | Contents | Writable? |
|---|---:|---|---|
| `0x000000-0x04FFFF` | 320 KB | Vendor U-Boot (content ends ~`0x044000`) | **Never** |
| `0x050000-0x07FFFF` | 192 KB | Erased | Free |
| `0x080000-0x09FFFF` | 128 KB | U-Boot environment | Stage 3 only |
| `0x0A0000-0x0AFFFF` | 64 KB | Erased | Free |
| `0x0B0000-0x0BFFFF` | 64 KB | Config record at `0x0BFC20` — **do not touch** | No |
| `0x0C0000-0x0DFFFF` | 128 KB | Boot splash JPEG + zero padding — **do not touch** | No |
| `0x0E0000-0x0EFFFF` | 64 KB | Erased | Free |
| `0x0F0000-0x0FFFFF` | 64 KB | Backup config record at `0x0FFC20` — **do not touch** | No |
| `0x100000-0x1FFFFF` | **1 MiB** | Erased, contiguous | **Target** |

The 1 MiB at `0x100000` is the staging area. A trimmed ARM U-Boot is
typically 500-800 KB, so this is sufficient with margin.

### The vendor data area

Two distinct structures, both of which must survive.

**Config record, `0x0BFC20`.** A 1 KB record near the end of block 11, not at
its start — which is why a per-block occupancy count reports only 336 used
bytes for that block:

```text
00:18:ae:3c:a2:49      the board's real MAC address
v1.2                   matches the board revision, DHB_AX V1.2
0008                   unidentified
1156f                  0x1156F = 71,023: the splash image's length
```

This resolves an open question in `investigation.md`. The stored U-Boot
`ethaddr` is the placeholder `00:00:23:34:45:66` while the running hardware
uses `00:18:AE:3C:A2:49`. The real address lives here, in vendor data read by
the application rather than by U-Boot.

**The record is duplicated.** An identical copy sits at `0x0FFC20` in block
15; the two 1 KB ranges have matching SHA-1. A redundant pair is what you
write when the data must survive a power cut mid-update, which is a further
argument for leaving both alone.

**Boot splash, `0x0C0000-0x0D156E`.** A 71,023-byte Exif JPEG, 480x300,
`software=www.meitu.com`. The remainder of blocks 12-13 is padded with `0x00`
rather than erased to `0xFF`, so an occupancy count reports those blocks as
nearly full.

Overwriting any of this would lose the board's identity and its logo. All of
it is present in the verified backup, so the loss is recoverable, but there is
no reason to go near it.

## Mechanism

Three stages, each gated on the previous one working.

### Stage 1 — prove it in RAM (no writes)

Same shape as the kernel port's existing workflow. Interrupt autoboot, then:

```text
setenv ipaddr 192.168.7.241
setenv netmask 255.255.252.0
setenv serverip 192.168.4.34
setenv ethaddr 00:18:AE:3C:A2:49
ping 192.168.4.34
tftp 0x88000000 u-boot-dhb-ax.bin
go 0x88000000
```

Unlimited attempts, no persistence, power cycle to revert. Do not proceed
until the second U-Boot boots reliably and its network works.

### Stage 2 — persist the image only

One write, to the emptiest region on the chip. The environment is left alone,
so `bootcmd` still boots the vendor kernel exactly as it does now.

```text
erase blocks 16-31 only:  0x100000 - 0x1FFFFF
write the image at:       0x100000
```

The new U-Boot is then reached on demand by interrupting autoboot:

```text
sf probe 0:1
sf read 0x88000000 0x100000 <size>
go 0x88000000
```

This is the recommended resting state for a development board: stock boot
path intact, new bootloader available when wanted.

### Stage 3 — automatic chainload (optional)

Only if typing two commands becomes tiresome. Requires writing the
environment sector, the riskier of the two writes.

```text
setenv bootcmd 'sf probe 0:1; sf read 0x88000000 0x100000 <size>; go 0x88000000'
saveenv
```

A wrong `bootcmd` is still recoverable: autoboot fails and drops to the
prompt. Capture the current environment first regardless.

## Build requirements for the second U-Boot

1. **Skip low-level init.** DRAM, PLLs and pin muxing are already configured
   by the vendor bootloader. The build must not repeat them.
2. **Fixed load address in RAM.** `0x88000000` is the starting proposal: clear
   of `0x80008000` where kernels land and of `0x82000000` used for TFTP
   staging. Confirm against the relocation target before trusting it.
3. **Environment must not collide.** If the new U-Boot expects its environment
   at `0x080000` it will overwrite the vendor's. Build with the environment in
   RAM only, or give it its own sector in free space.
4. **Board support.** PL011 serial at `0x20080000`, timer, SPI, and the
   GMAC1 Ethernet described in `../kernel-port/README.md`. The device trees
   there are the reference for addresses and interrupts.

Note the UART clock trap documented in the kernel port: U-Boot leaves UART0
on a roughly 3 MHz source rather than the 155 MHz peripheral clock. A second
U-Boot inherits whatever the first one left configured, so console setup
needs the same attention.

## Open questions to settle before Stage 1

| Question | How to check | Risk if wrong |
|---|---|---|
| Does this U-Boot have `go`? | `help` at the prompt | Blocks stage 1; fall back to `mkimage -T standalone` and `bootm` |
| Does it have `sf erase` / `sf write`? | `help` at the prompt — check availability, do not run | Blocks stages 2-3 entirely |
| Where does the vendor U-Boot relocate itself? | `bdinfo`, if present | Possible overlap with the chosen load address |
| Is `0x88000000` clear at the moment of `go`? | `md` before jumping | Second U-Boot corrupts itself on start |
| Does the vendor application read the MAC from `0x0B0000`? | Search the application binary for the offset | Confirms the region must stay untouched |

`iminfo` is unavailable, so image integrity before `go` has to be checked by
comparing the transferred byte count against the staged file.

## Recovery

In increasing order of severity:

1. Second U-Boot misbehaves in RAM → power cycle. Nothing persisted.
2. Bad image at `0x100000` → vendor `bootcmd` untouched, board boots
   normally; rewrite the region.
3. Bad `bootcmd` (stage 3 only) → autoboot fails, prompt still appears;
   `setenv` and `saveenv` to correct.
4. Vendor U-Boot region damaged → **not recoverable over serial.** Requires a
   SPI programmer and clip, plus the verified backup at
   `../backups/2026-08-03/spi-nor/dhb-ax-spi-nor-cold-a.bin`
   (SHA-256 `b0c66d971228a8a941e320282e6423330acf34064f11d0397698f4b8459a89c3`).

Acquiring a SPI programmer before attempting stage 2 or 3 converts the worst
case from terminal to inconvenient.

## How the flash map was measured

Read-only, from the backup, on the Mac. Tooling caveats are in
`binwalk-notes.md`; the one that matters here:

> The binwalk in `PATH` (Rust 3.1.0) **did not find the splash JPEG** in this
> image. It reports one result for the whole 2 MiB. A region that a signature
> scanner calls empty is not thereby empty — this map was built by counting
> non-`0xFF` bytes, not by asking a tool what it recognised.

Before erasing anything, verify the target range with the occupancy loop below
and confirm by eye with `hexdump`. Do not rely on a scanner's silence.

Reproducible:

```sh
cd backups/2026-08-03/spi-nor
export LC_ALL=C          # tr fails on 0xFF without this
i=0
while [ $i -lt 32 ]; do
  n=$(dd if=dhb-ax-spi-nor-cold-a.bin bs=65536 skip=$i count=1 2>/dev/null \
      | tr -d '\377' | wc -c)
  printf "block %2d  0x%06x  %s\n" "$i" $((i*65536)) "$n"
  i=$((i+1))
done
```

Blocks reporting `0` are fully erased. The vendor data area was identified by
running `strings` over blocks 11-13.

## Recommendation

Stage 1 is worth doing and costs nothing but time. It is a reasonable way to
learn bootloader bring-up with no risk to the board.

Stage 2 is reasonable once stage 1 is solid, ideally with a SPI programmer to
hand first.

Stage 3 has the worst effort-to-benefit ratio of the three and can be
deferred indefinitely.

The vendor U-Boot loads kernels over the network reliably, which is the only
thing the kernel port needs from it. Nothing here is urgent.
