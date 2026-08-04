#!/usr/bin/env python3
"""Convert an image to a raw ARGB1555 framebuffer for the Hi3531 video output.

    mkfb.py <image> <out.raw> [WxH] [--crop]
    mkfb.py --bars  <out.raw> [WxH]

Default geometry is 1280x1024, the mode the VO is running in.

Pixel format is ARGB1555, little-endian, alpha bit clear:

    bit 15    14..10   9..5    4..0
    A(0)      R        G       B

Determined by reading the live framebuffer while U-Boot's boot splash was on
screen and matching known pixels against the original JPEG.

The buffer is handed to the display with U-Boot's vendor command:

    startgx <layer> <addr> <stride> <x> <y> <w> <h>

where stride is bytes per row = w * 2.
"""
import sys

def to1555(r, g, b):
    return ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)


def pack(rgb, W, H):
    """rgb: flat bytes, three per pixel, row-major, W*H*3 long."""
    stride = W * 2
    out = bytearray(stride * H)
    i = 0
    for y in range(H):
        base = y * stride
        for x in range(W):
            v = to1555(rgb[i], rgb[i + 1], rgb[i + 2])
            out[base + x * 2] = v & 0xFF
            out[base + x * 2 + 1] = (v >> 8) & 0xFF
            i += 3
    return out


def bars(W, H):
    """75% colour bars over a greyscale ramp, as flat RGB bytes."""
    cols = [(191, 191, 191), (191, 191, 0), (0, 191, 191), (0, 191, 0),
            (191, 0, 191), (191, 0, 0), (0, 0, 191), (0, 0, 0)]
    px = bytearray()
    split = int(H * 0.75)
    for y in range(H):
        for x in range(W):
            if y < split:
                px += bytes(cols[x * len(cols) // W])
            else:
                v = x * 255 // (W - 1)
                px += bytes((v, v, v))
    return px


def load(path, W, H, crop):
    from PIL import Image
    im = Image.open(path).convert("RGB")
    if crop:
        # Fill the screen, trimming whatever does not fit.
        scale = max(W / im.width, H / im.height)
        new = (round(im.width * scale), round(im.height * scale))
        im = im.resize(new, Image.LANCZOS)
        left, top = (im.width - W) // 2, (im.height - H) // 2
        im = im.crop((left, top, left + W, top + H))
        fit = f"cropped to fill {W}x{H}"
    else:
        # Preserve the whole frame, pad with black.
        im.thumbnail((W, H), Image.LANCZOS)
        canvas = Image.new("RGB", (W, H), (0, 0, 0))
        canvas.paste(im, ((W - im.width) // 2, (H - im.height) // 2))
        fit = f"fitted to {im.width}x{im.height}, padded to {W}x{H}"
        im = canvas
    # tobytes() gives flat row-major RGB and avoids getdata(), which Pillow 12
    # deprecates.
    return im.tobytes(), fit


args = [a for a in sys.argv[1:] if not a.startswith("--")]
flags = {a for a in sys.argv[1:] if a.startswith("--")}

if len(args) < (1 if "--bars" in flags else 2):
    sys.exit(__doc__)

# With --bars there is no source image, so the output path comes first.
if "--bars" in flags:
    src, dst, geom = None, args[0], args[1:]
else:
    src, dst, geom = args[0], args[1], args[2:]

W, H = (int(n) for n in geom[0].split("x")) if geom else (1280, 1024)

if "--bars" in flags:
    data, note = bars(W, H), "colour bars"
else:
    data, note = load(src, W, H, "--crop" in flags)

raw = pack(data, W, H)
open(dst, "wb").write(raw)

name = dst.rsplit("/", 1)[-1]
print(f"wrote {dst}")
print(f"  {W}x{H} ARGB1555, stride {W*2}, {len(raw)} bytes ({len(raw)/2**20:.2f} MiB)")
print(f"  {note}")
print(f"  tftp 0xc2000000 {name}")
print(f"  startgx 0 0xc2000000 {W*2} 0 0 {W} {H}")
