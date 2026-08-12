# dvr-browser

Browse the DVR's recordings interactively, over the network, from your own
machine. The DVR serves raw bytes; everything else happens here.

```sh
tools/dvr-browser/browser.py --dvr http://192.168.4.70/
# then open http://localhost:8099/  (the port it prints)
```

Requires `ffmpeg` on your PATH. No other dependencies.

## What it does

The DVR, booted into the `dvr-extract` Buildroot image, runs lighttpd serving
its four recording partitions read-only with HTTP range support (see
[docs/dvr-extract.md](../../docs/dvr-extract.md)). This program:

1. reads each partition's `reclog.bin` to build one chronological timeline of
   every recording across the whole disk (the four partitions are a
   time-ordered ring buffer),
2. when you pick a recording, range-fetches only its 256 KiB header+index to
   build a keyframe timeline with real timestamps,
3. when you click a time, range-fetches just that keyframe's byte span, remuxes
   it to fragmented MP4 with ffmpeg (no re-encode), and streams it into the
   page's `<video>`.

Only the bytes you actually watch cross the network. Nothing is written to the
DVR.

## Files

| File | What it is |
|---|---|
| `ftvt.py` | parser for the DVR's container format; the reverse-engineered layout is documented at the top |
| `browser.py` | the local web app: discovery, timeline, and ffmpeg-backed streaming |

## Options

| Flag | Default | Meaning |
|---|---|---|
| `--dvr` | `http://192.168.4.70/` | base URL of the DVR's lighttpd |
| `--port` | `8099` | local port for the browser UI |
| `--partitions` | `00,01,02,03` | partition directories to scan |

## Notes

- Timestamps in the index are UTC. The DVR burns *local* time into the picture,
  so a frame stamped `06:27:08` in New York (EDT) has index time `10:27:08Z`.
  The UI shows times in your browser's local zone and notes the stored value is
  UTC.
- Playback runs from the chosen keyframe to the end of that container. Real
  capture rate is ~30 fps; raw H.264 carries no timing, so `browser.py` hands
  ffmpeg that rate when remuxing (the `FPS` constant).
- The DVR's `.dat` files are ~512 MB each and hold one continuous span (~7 min)
  of video. There is only one camera (the board is four-channel but only
  channel 1 was wired), so a recording is never ambiguous. The four partitions
  form one time-ordered ring buffer, ~9 days total; the timeline stitches them
  into a single chronological list.
