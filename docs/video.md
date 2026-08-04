# Video output

What we know about the Hi3531's display path on this board, and how to put an
arbitrary image on the HDMI output from the U-Boot prompt.

Written 2026-08-04. Everything here is measured on the board; no vendor source
exists for the VDP — the video drivers are proprietary blobs
(`hi3531_vou.ko` and friends in `rootfs/mtd/modules/`).

**This port does not drive the display.** Our kernel has no VO driver and never
touches these registers. Everything below is either U-Boot's doing or a
deliberate experiment from the U-Boot prompt. It is recorded because the
hardware keeps running after U-Boot exits, which has consequences for memory
(see [memory-map.md](memory-map.md)), and because it is a useful way to get
pixels on screen without writing a driver.

## The short version

```text
tftp 0xc2000000 photo-hd.raw
startgx 0 0xc2000000 2560 0 0 1280 1024
```

Two commands. The first drops raw pixels into DRAM, the second points the
display hardware at them. No driver, no kernel, no filesystem.

## What U-Boot sets up at boot

The vendor added display commands to U-Boot 2010.06, and the boot log shows
them running:

```text
jpeg decoding ...
<<addr=0xc0000000, size=0x1156f, vobuf=0xc1000000>>
mmu_enable
<<imgwidth=480, imgheight=300, linebytes=960>>
decode success!!!!
dev 0 set background color!
dev 2 set background color!
dev 3 set background color!
dev 0 opened!
vo hd 0 end
dev 2 opened!
dev 3 opened!
vo cvbs end
graphic layer 0 opened!
graphic layer 2 opened!
graphic layer 3 opened!
```

Reading that:

| Field | Value | Meaning |
|---|---|---|
| `addr` | `0xc0000000` | where the compressed JPEG is copied |
| `size` | `0x1156f` | 71,023 bytes — the JPEG's exact length |
| `vobuf` | `0xc1000000` | the **decoded** framebuffer the display scans |
| `imgwidth`/`imgheight` | 480 × 300 | splash dimensions |
| `linebytes` | 960 | stride: 960 ÷ 480 = **2 bytes per pixel** |

Three VO devices and three graphics layers are opened. `dev 0` is the HD path
(HDMI/VGA), and the log names `cvbs` for the others — the composite outputs.
Only `dev 0` has been explored.

The splash JPEG lives at offset `0xC0000` in SPI NOR. It is a reseller's logo,
not the manufacturer's. Extract with:

```sh
dd if=backups/2026-08-03/spi-nor/dhb-ax-spi-nor-cold-a.bin \
   of=boot.jpg bs=1 skip=$((0xC0000)) count=71023
```

The extracted file is a valid 480×300 JPEG and its length matches U-Boot's
reported `size` exactly. It is gitignored as third-party material.

## Pixel format: ARGB1555

No datasheet was needed. The framebuffer's own contents gave it away, because
we already had a copy of the image that produced them.

Read the live buffer while the splash was on screen:

```text
md.l 0xc1000000 4
c1000000: 7fff7fff 7fff7fff 7fff7fff 7fff7fff
```

The splash's top-left corner is white. Decoding `0x7FFF` two ways:

| Format | `0x7FFF` decodes to | Verdict |
|---|---|---|
| ARGB1555 | `#FFFFFF` white | ✓ |
| RGB565 | `#7BFFFF` cyan | ✗ |

Confirmed against a second sample in the red band at the image centre, which
came out `#EE0029` under ARGB1555 and an implausible olive under RGB565.

```text
bit 15    14..10   9..5    4..0
A(0)      R        G       B
```

Little-endian, alpha bit always clear. Stride is `width × 2` bytes.

Centre-pixel values differ from the source JPEG by 1–2 in the low bits —
U-Boot's decoder and Pillow round chroma differently at sharp edges. Not a
format mismatch.

## The vendor's U-Boot commands

Not in mainline U-Boot; added by the vendor. `help` lists them:

```text
startgx  - open graphics layer.
         - startgx [layer addr stride x y w h]
stopgx   - close graphics layer.
         - stopgx [layer]
startvo  - open interface of vo device.
         - startvo [dev type sync]
stopvo   - close interface of vo device.
         - stopvo [dev]
setvobg  - set vo backgroud color.
         - setvobg [dev color]
decjpg   - decode jpeg picture.
```

`startgx` is the useful one: it programs a layer's base address, stride,
position and size in one go. `decjpg`'s arguments are undocumented in its help
text and untested — it is presumably what the boot script uses.

**Check `help` before reverse-engineering.** Time was spent scanning VDP
registers at `0x205c0000` looking for something holding `0xc1000000`, when the
vendor had already exposed exactly the right interface. The registers do read
live values (`0x205c0000` returns `0x000c5004`), so that route is open if a
command is ever missing, but it was not needed here.

## Putting an arbitrary image on screen

`tools/mkfb.py` converts any image to a raw ARGB1555 buffer. It needs Pillow;
`--bars` is pure Python and needs nothing:

```sh
uv venv .venv && uv pip install --python .venv/bin/python pillow
```

```sh
# full screen, letterboxed
mkfb.py photo.png photo-hd.raw

# fill the screen, trimming overflow
mkfb.py photo.png photo-hd.raw --crop

# a different geometry
mkfb.py photo.png small.raw 480x300

# colour bars, no source image needed
mkfb.py --bars bars.raw
```

It prints the two U-Boot commands to run. Stage the `.raw` on the Pi's TFTP
root, then from the U-Boot prompt:

```text
tftp 0xc2000000 photo-hd.raw
startgx 0 0xc2000000 2560 0 0 1280 1024
```

`graphic layer 0 opened!` confirms it. The image appears immediately.

### Verified on hardware

| | |
|---|---|
| Mode reported by the projector | 1280 × 1024 |
| Buffer | 2,621,440 bytes (2.5 MiB) at `0xc2000000` |
| Stride | 2560 |
| Result | full-screen image, background no longer visible |

Before reprogramming the layer, the default 480×300 buffer appeared as a small
image centred on a blue background — that blue being U-Boot's
`set background color!`. Overwriting `0xc1000000` in place changes the picture
but not its size; `startgx` is what changes the geometry.

## Gotchas

**Two different things live at `0xc0000000` and `0xc1000000`.** The first is a
*compressed JPEG*, the second is *decoded pixels*. TFTP-ing a `.jpg` to the
framebuffer renders the compressed bytes as noise. Convert first.

**Reading the framebuffer destroys evidence if you write to it.** An early
memory-aliasing test wrote `0xc0c0c0c0` to `0xc0000000`, clobbering the JPEG's
`ffd8` start-of-image marker. The flash copy is the reliable source.

**`gatewayip needed but not set` usually means the netmask is wrong.** With
only `ipaddr` set, U-Boot assumes /24, decides the Pi at `192.168.4.34` is
off-subnet, and looks for a router. Set `netmask=255.255.252.0` and it
transfers directly. The error names the wrong variable.

**Send commands one at a time over the serial console.** A `startgx` typed
while a `tftp` echo was still draining was swallowed and parsed as `tftp`.
Wait for the prompt.

**Nothing here survives a reboot.** These are RAM writes and register pokes;
U-Boot redraws the dealer logo from SPI NOR every boot. No flash is modified.

## The memory question

The framebuffers are in **DDR1**, the second bank, which this port does not
declare. See [memory-map.md](memory-map.md).

That is why writing to `0xc1000000` is safe today: Linux was never told the
bank exists, so it cannot allocate from it. The safety is a side effect of not
using the memory, not a deliberate reservation.

If DDR1 is ever claimed — it is 512 MiB sitting idle — this becomes a real
hazard. The VO block DMA-reads its framebuffer roughly 60 times a second and
will keep doing so forever unless stopped. Options, in increasing order of
merit:

1. **Reserve the buffers** in the device tree. Requires knowing *every* live
   buffer address; U-Boot printed only one, and three layers are open.
2. **Cap the memory node** below the buffers. Wastes whatever sits above.
3. **Stop the hardware.** `stopgx` / `stopvo` from U-Boot before booting, or
   gate the VO clock in the CRG during kernel init. Nothing here drives a
   display, so this is the honest fix — no DMA running means nothing to work
   around.

The failure mode is the benign one: the VO only *reads*, so a collision
produces garbage on screen rather than kernel corruption. A capture engine
writing into memory Linux owns would be far worse.

## Not yet explored

- `decjpg` argument syntax — would let the board decode a `.jpg` itself
- Layers 2 and 3, and the composite outputs
- `startvo` modes: `[dev type sync]` suggests output standard and timing are
  selectable, so 1280×1024 may not be the only option
- `setvobg` colour encoding
- Whether the VO can be started from Linux by poking registers, without the
  proprietary modules
- The HDMI transmitter itself: the vendor ships `sil9024.ko` for a Silicon
  Image part, which was not identified in the PCB survey
