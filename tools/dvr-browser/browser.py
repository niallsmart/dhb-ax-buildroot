#!/usr/bin/env python3
"""Interactively browse the DVR's recordings over the network.

The DVR (booted into the dvr-extract Buildroot image) runs lighttpd, serving
its four read-only-mounted recording partitions as static files with HTTP range
support.  This program runs on your machine, not the DVR.  It:

  * discovers the .dat containers on each partition,
  * range-fetches only each container's header+index to build a timeline,
  * on demand, range-fetches a single keyframe span and remuxes it to
    fragmented MP4 with ffmpeg, streamed into an HTML5 <video>.

The DVR only ever serves raw bytes; all parsing, indexing and muxing happen
here.  Nothing is written to the DVR, and only the bytes you actually watch
cross the network.

Usage:
    tools/dvr-browser/browser.py --dvr http://192.168.4.70/
    then open http://localhost:8099/

Requires ffmpeg on PATH.  Standard library only otherwise.
"""

import argparse
import html
import http.server
import json
import re
import socketserver
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import timezone

import ftvt

# Real capture rate, derived from the index: ~120 frames per ~4.0 s keyframe
# interval.  Raw H.264 carries no timing, so we hand ffmpeg this frame rate when
# remuxing; get it wrong and playback runs fast or slow.
FPS = 30

# How long to wait on the DVR for any single HTTP request.
HTTP_TIMEOUT = 30


class DVR:
    """A thin HTTP-range client for the DVR's lighttpd."""

    def __init__(self, base: str):
        # Normalise to exactly one trailing slash so urljoin behaves.
        self.base = base.rstrip("/") + "/"

    def _url(self, path: str) -> str:
        return urllib.parse.urljoin(self.base, path.lstrip("/"))

    def get_range(self, path: str, start: int, end: int) -> bytes:
        """GET bytes [start, end) of path.  end is exclusive."""
        req = urllib.request.Request(self._url(path))
        req.add_header("Range", f"bytes={start}-{end - 1}")
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
            return r.read()

    def size(self, path: str) -> int:
        """File size, via the Content-Range of a one-byte range GET.

        A HEAD would be tidier but some static servers omit Content-Length on
        HEAD; a range GET's Content-Range is reliable and costs one byte.
        """
        req = urllib.request.Request(self._url(path))
        req.add_header("Range", "bytes=0-0")
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
            cr = r.headers.get("Content-Range", "")
        m = re.search(r"/(\d+)\s*$", cr)
        if not m:
            raise RuntimeError(f"no Content-Range total for {path!r}: {cr!r}")
        return int(m.group(1))

    def list_dats(self, directory: str) -> list[str]:
        """Return the .dat hrefs in a lighttpd directory listing, sorted."""
        try:
            with urllib.request.urlopen(self._url(directory), timeout=HTTP_TIMEOUT) as r:
                page = r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return []
            raise
        # lighttpd dirlisting is <a href="00000000.dat">.  Accept any href that
        # ends .dat, strip query/anchors, ignore parent links.
        names = set()
        for href in re.findall(r'href="([^"]+)"', page):
            href = html.unescape(href).split("?")[0].split("#")[0]
            if href.lower().endswith(".dat"):
                names.add(href.rsplit("/", 1)[-1])
        return sorted(names)

    def get_reclog(self, directory: str) -> bytes | None:
        """The head of a partition's reclog.bin, or None if absent."""
        try:
            return self.get_range(directory + "reclog.bin", 0, ftvt.RECLOG_SPAN)
        except urllib.error.HTTPError as e:
            if e.code in (404, 416):  # missing, or smaller than the range
                return None
            raise


def stream_mp4(dvr: DVR, path: str, start: int, end: int):
    """Yield fragmented-MP4 bytes for the container span [start, end).

    The raw H.264 (with the container's interspersed "00db" chunk tags, which
    ffmpeg skips by resyncing on start codes) is remuxed, not transcoded -- the
    DVR's stream is already H.264, so this is cheap and keeps quality.
    """
    body = dvr.get_range(path, start, end)
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-f", "h264", "-r", str(FPS), "-i", "pipe:0",
        "-c", "copy",
        "-movflags", "frag_keyframe+empty_moov+default_base_moof",
        "-f", "mp4", "pipe:1",
    ]
    proc = subprocess.Popen(
        cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )

    # Feed ffmpeg from a thread so we can read its output concurrently and not
    # deadlock on pipe buffers.
    import threading

    def feed():
        try:
            proc.stdin.write(body)
        except BrokenPipeError:
            pass
        finally:
            try:
                proc.stdin.close()
            except BrokenPipeError:
                pass

    threading.Thread(target=feed, daemon=True).start()
    try:
        while True:
            chunk = proc.stdout.read(64 * 1024)
            if not chunk:
                break
            yield chunk
    finally:
        proc.stdout.close()
        proc.wait()


class App(http.server.BaseHTTPRequestHandler):
    dvr: DVR = None            # set on the class before serving
    partitions: list[str] = []

    # -- helpers ---------------------------------------------------------------

    def _send(self, code, body=b"", ctype="text/plain; charset=utf-8", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)
        if body:
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body and self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj).encode(), "application/json")

    def log_message(self, *a):
        pass  # quiet; this is a personal tool

    # -- routing ---------------------------------------------------------------

    def do_GET(self):
        parts = urllib.parse.urlparse(self.path)
        route = parts.path
        q = urllib.parse.parse_qs(parts.query)
        try:
            if route == "/":
                self._send(200, INDEX_HTML.encode(), "text/html; charset=utf-8")
            elif route == "/api/timeline":
                self._api_timeline()
            elif route == "/api/containers":
                self._api_containers()
            elif route == "/api/index":
                self._api_index(q["path"][0])
            elif route == "/play":
                self._play(q["path"][0], int(q["kf"][0]))
            else:
                self._send(404, b"not found")
        except (BrokenPipeError, ConnectionResetError):
            pass  # client navigated away mid-stream
        except KeyError as e:
            self._send(400, f"missing parameter {e}".encode())
        except urllib.error.URLError as e:
            self._send(502, f"DVR unreachable: {e}".encode())
        except Exception as e:  # surface parse/format errors to the browser
            self._send(500, f"{type(e).__name__}: {e}".encode())

    # -- endpoints -------------------------------------------------------------

    def _api_timeline(self):
        """One chronological timeline across all partitions, from reclog.bin.

        Each partition's reclog gives its segments' start/end times; segment i
        maps to container 0000000i.dat.  The four partitions are a ring buffer,
        so merging every partition's segments and sorting by start time yields
        the whole disk in wall-clock order.  A partition with no reclog falls
        back to a bare .dat listing with null times, so nothing is hidden just
        because its index is missing.
        """
        entries = []
        for p in self.partitions:
            directory = f"/{p}/"
            raw = self.dvr.get_reclog(directory)
            if raw:
                for seg in ftvt.parse_reclog(raw):
                    entries.append({
                        "partition": p, "name": seg.name,
                        "path": directory + seg.name,
                        "start_utc": seg.start.isoformat(),
                        "end_utc": seg.end.isoformat(),
                    })
            else:
                for name in self.dvr.list_dats(directory):
                    entries.append({"partition": p, "name": name,
                                    "path": directory + name,
                                    "start_utc": None, "end_utc": None})
        # Sort by start time; the timeless fallback entries sort last.
        entries.sort(key=lambda e: (e["start_utc"] is None, e["start_utc"] or ""))
        self._json(entries)

    def _api_containers(self):
        """List every container across the partitions, with size and path."""
        out = []
        for p in self.partitions:
            directory = f"/{p}/"
            for name in self.dvr.list_dats(directory):
                path = directory + name
                out.append({"partition": p, "name": name, "path": path,
                            "size": self.dvr.size(path)})
        self._json(out)

    def _api_index(self, path):
        """Header+index for one container: the keyframe timeline."""
        size = self.dvr.size(path)
        span = min(ftvt.HEADER_SPAN, size)
        buf = self.dvr.get_range(path, 0, span)
        c = ftvt.parse_header(buf)
        self._json({
            "path": path,
            "size": size,
            "data_offset": c.data_offset,
            "start_utc": c.start.astimezone(timezone.utc).isoformat(),
            "end_utc": c.end.astimezone(timezone.utc).isoformat(),
            "duration_s": c.duration_s,
            "keyframes": [
                {"i": i, "frame": k.frame, "offset": k.offset,
                 "utc": k.time.isoformat()}
                for i, k in enumerate(c.keyframes)
            ],
        })

    def _play(self, path, kf):
        """Stream from keyframe kf to the end of the container as MP4."""
        size = self.dvr.size(path)
        buf = self.dvr.get_range(path, 0, min(ftvt.HEADER_SPAN, size))
        c = ftvt.parse_header(buf)
        start, end = c.span_from(kf, size)
        self.send_response(200)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        for chunk in stream_mp4(self.dvr, path, start, end):
            self.wfile.write(chunk)


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


INDEX_HTML = r"""<!doctype html>
<meta charset="utf-8">
<title>DVR browser</title>
<style>
  :root { color-scheme: light dark; }
  body { font: 14px/1.4 system-ui, sans-serif; margin: 0; display: grid;
         grid-template-columns: 320px 1fr; height: 100vh; }
  #left { border-right: 1px solid #8884; overflow: auto; padding: 8px; }
  #right { display: flex; flex-direction: column; min-width: 0; }
  h1 { font-size: 14px; margin: 4px 8px; }
  .day { position: sticky; top: 0; background: Canvas; font-weight: 700;
         padding: 6px 8px 2px; opacity: .85; }
  .c { padding: 5px 8px; border-radius: 6px; cursor: pointer;
       font-variant-numeric: tabular-nums; }
  .c:hover { background: #8882; }
  .c.sel { background: #3b82f680; }
  .c .t { font-weight: 600; }
  .c .s { opacity: .7; font-size: 12px; }
  video { width: 100%; background: #000; max-height: 60vh; }
  #kf { overflow: auto; padding: 8px; display: flex; flex-wrap: wrap;
        gap: 4px; align-content: flex-start; }
  .k { padding: 3px 6px; border: 1px solid #8886; border-radius: 5px;
       cursor: pointer; font-variant-numeric: tabular-nums; }
  .k:hover { background: #3b82f680; }
  #hint { opacity: .6; padding: 8px; }
  #err { color: #e11; padding: 8px; white-space: pre-wrap; }
</style>
<div id="left"><h1>Recordings (oldest → newest)</h1><div id="list">loading…</div></div>
<div id="right">
  <video id="v" controls></video>
  <div id="hint">Pick a container, then a time to play from.</div>
  <div id="err"></div>
  <div id="kf"></div>
</div>
<script>
const $ = s => document.querySelector(s);
const fmt = iso => new Date(iso).toLocaleString(undefined,
    {hour12:false, year:'numeric', month:'2-digit', day:'2-digit',
     hour:'2-digit', minute:'2-digit', second:'2-digit'});
const dur = s => { s=Math.round(s); const m=Math.floor(s/60);
    return m+'m'+String(s%60).padStart(2,'0')+'s'; };

let cur = null;
const hms = iso => new Date(iso).toLocaleTimeString(undefined, {hour12:false});
const day = iso => new Date(iso).toLocaleDateString(undefined,
    {weekday:'short', year:'numeric', month:'short', day:'2-digit'});

async function loadTimeline() {
  const r = await fetch('/api/timeline');
  const cs = await r.json();
  const list = $('#list'); list.innerHTML = '';
  if (!cs.length) { list.textContent = 'no recordings found'; return; }
  let lastDay = null;
  for (const c of cs) {
    if (c.start_utc) {
      const dk = day(c.start_utc);
      if (dk !== lastDay) {
        const h = document.createElement('div');
        h.className = 'day'; h.textContent = dk;
        list.appendChild(h); lastDay = dk;
      }
    }
    const d = document.createElement('div');
    d.className = 'c';
    const label = c.start_utc
      ? `<span class="t">${hms(c.start_utc)}</span>`
        + `<span class="s"> – ${hms(c.end_utc)} · part ${c.partition}</span>`
      : `<span class="t">${c.name}</span>`
        + `<span class="s"> · part ${c.partition} (no index)</span>`;
    d.innerHTML = label;
    d.onclick = () => selectContainer(c, d);
    list.appendChild(d);
  }
}

async function selectContainer(c, el) {
  document.querySelectorAll('.c').forEach(x => x.classList.remove('sel'));
  el.classList.add('sel');
  $('#err').textContent = '';
  $('#kf').innerHTML = 'loading index…';
  cur = c;
  const r = await fetch('/api/index?path=' + encodeURIComponent(c.path));
  if (!r.ok) { $('#err').textContent = await r.text(); $('#kf').innerHTML=''; return; }
  const idx = await r.json();
  $('#hint').textContent = `${c.name}: ${fmt(idx.start_utc)} → ${fmt(idx.end_utc)}`
      + ` (${dur(idx.duration_s)}, ${idx.keyframes.length} keyframes). `
      + `Times shown in your local zone; stored UTC.`;
  const kf = $('#kf'); kf.innerHTML = '';
  for (const k of idx.keyframes) {
    const b = document.createElement('div');
    b.className = 'k';
    b.textContent = new Date(k.utc).toLocaleTimeString(undefined, {hour12:false});
    b.title = 'UTC ' + k.utc;
    b.onclick = () => play(c.path, k.i);
    kf.appendChild(b);
  }
}

function play(path, kf) {
  const v = $('#v');
  v.src = '/play?path=' + encodeURIComponent(path) + '&kf=' + kf;
  v.play().catch(()=>{});
}

loadTimeline().catch(e => $('#list').textContent = e);
</script>
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dvr", default="http://192.168.4.70/",
                    help="base URL of the DVR's lighttpd (default %(default)s)")
    ap.add_argument("--port", type=int, default=8099,
                    help="local port to serve the browser UI on (default %(default)s)")
    ap.add_argument("--partitions", default="00,01,02,03",
                    help="comma-separated partition dirs to scan (default %(default)s)")
    args = ap.parse_args()

    App.dvr = DVR(args.dvr)
    App.partitions = [p.strip() for p in args.partitions.split(",") if p.strip()]

    srv = Server(("127.0.0.1", args.port), App)
    print(f"DVR:     {App.dvr.base}")
    print(f"Browser: http://localhost:{args.port}/")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
