# Browsing the DVR's recordings (dvr-extract)

How to read the video off the DVR's hard disk and browse it interactively,
using only the DVR itself to reach the disk — no SATA-to-USB adapter, no
pulling the drive.

Lives on the `dvr-extract` branch. Written 2026-08-11.

## The idea

The DVR is a weak dual-core ARM box with 220 MB of RAM. It should do the one
thing only it can do — read its own SATA disk — and nothing else. So:

- **On the DVR:** boot the `dvr-extract` Buildroot image. Its `/init` brings up
  the network, mounts the four recording partitions **read-only**, and starts
  **lighttpd** serving them as static files with byte-range support.
- **On your machine:** run `tools/dvr-browser/browser.py`. It parses the
  container index, presents a timeline in a web page, and when you pick a time
  it range-fetches just that clip, remuxes it to MP4 with ffmpeg, and plays it.

The DVR only ever serves raw bytes. All parsing, decoding and UI happen on the
capable machine, and only the bytes you watch cross the network.

Nothing writes to the disk: the partitions are mounted `-o ro` and lighttpd
serves static files only (mod_webdav is not even built — `post-build.sh`
asserts both).

## The container format (FTVT)

Reverse-engineered from a running board; no vendor documentation exists. Each
partition holds preallocated 512 MB files `00000000.dat`, `00000001.dat`, … On
each file:

```
offset  size  field
0x00    4     "FHDR" magic
0x0c    4     "FTVT" container tag
0x18    4     number of index records
0x30    4     byte offset of the index
0x34    4     byte offset where the H.264 data begins   (0x28200 observed)
```

Then an index of 20-byte records, one per keyframe:

```
0x00    4     "00db" tag (AVI fourcc for a compressed video chunk)
0x04    4     cumulative frame number at this keyframe
0x08    4     byte offset of the keyframe within the file
0x0c    8     timestamp, microseconds since Unix epoch, UTC
```

The payload is a raw H.264 Annex-B elementary stream (High profile, 1920×1080,
~30 fps) with the `00db` chunk tags left in; ffmpeg skips them by resyncing on
start codes. Because each index record carries the keyframe's byte offset, the
stream is randomly seekable: the bytes from one keyframe's offset to the next
are a self-contained playable GOP starting on an IDR.

Timestamps are UTC. The DVR burns *local* time into the picture — a frame
stamped 06:27:08 in New York (EDT, UTC-4) has index timestamp 10:27:08Z. This
was the confirmation the parse was right: the decoded overlay and the index
timestamp agree once the 4-hour offset is applied.

Not yet decoded: which physical camera a container belongs to. Nothing here
depends on it; identify the camera from the burnt-in overlay for now. The
per-partition `reclog.bin` is the likely place it is recorded.

The parser lives in `tools/dvr-browser/ftvt.py` with this layout at the top.

## Building the image

Same as any other build; the branch's defconfig adds lighttpd and the overlay
adds the config and the serving `/init`.

```sh
scripts/bootstrap-sources.sh    # once
scripts/buildroot.sh
```

The image lands in `kernel-port/build/buildroot-artifacts/`. Stage and boot it
over TFTP exactly as in the top-level README. **Never `saveenv`.**

## Booting and browsing

At boot the image prints its DHCP address, the read-only mounts, and that
lighttpd is up:

```text
DHB-AX Linux 6.18 dvr-extract server (Buildroot)
eth0 up; requesting a DHCP lease...
  address 192.168.4.70/22
Loading SATA and vfat, waiting for the disk...
  /dev/sda1 -> /srv/rec/00 (ro)
  /dev/sda2 -> /srv/rec/01 (ro)
  ...
lighttpd serving /srv/rec on port 80.
```

If there is no DHCP server, it drops to the shell and tells you the command to
set an address by hand. Then, on your machine:

```sh
tools/dvr-browser/browser.py --dvr http://192.168.4.70/
# open the http://localhost:… URL it prints
```

Pick a container on the left, then a time; playback runs from that keyframe to
the end of the container. See `tools/dvr-browser/README.md` for the flags.

## What it is not

- **Not a full extractor.** It browses; it does not carve every clip to disk.
  The index parser has everything needed to do that (walk the index, split on
  keyframe, mux each span) if a bulk export is wanted later.
- **Not consistent against a live recorder.** This image stops the vendor app
  by virtue of replacing the whole system, so the disk is static while you
  browse. Do not instead browse the *factory* firmware's live mounts — it is
  recording, and the bytes move under you.
