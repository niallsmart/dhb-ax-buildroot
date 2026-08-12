"""Parser for the TVT DVR's on-disk video container ("FTVT").

The DVR stores recordings as a sequence of preallocated 512 MB files named
00000000.dat, 00000001.dat, ... on each of four FAT32 partitions.  Each file is
one container: a fixed header, a keyframe index, then a raw H.264 Annex-B
elementary stream (start-code delimited).  The format was reverse-engineered
from a running board; there is no vendor documentation.  What is known:

  offset  size  field
  0x00    4     "FHDR" magic
  0x04    4     header block length (0x48 observed)
  0x0c    4     "FTVT" container tag
  0x18    4     number of index records
  0x30    4     byte offset of the index within the file
  0x34    4     byte offset where the H.264 data begins

Each index record is 20 bytes:

  0x00    4     "00db" tag (the AVI fourcc for a compressed video chunk)
  0x04    4     cumulative frame number at this keyframe
  0x08    4     byte offset of the keyframe within the file
  0x0c    8     timestamp, microseconds since the Unix epoch, UTC

The records are one-per-keyframe (roughly every 4 s / 120 frames, so the source
is ~30 fps).  Because each record carries the keyframe's byte offset, the stream
is randomly seekable: the bytes from records[i].offset up to records[i+1].offset
(or end-of-data) are a self-contained playable GOP span starting on an IDR.

The timestamps are UTC.  The DVR burns a *local* time into the picture, so a
frame stamped 06:27:08 in New York (EDT, UTC-4) has index timestamp 10:27:08Z.

What is NOT yet decoded: which physical camera a container belongs to.  The
channel is presumably in the header (a couple of small integer fields remain
unidentified) or in the per-partition reclog.bin, but nothing here depends on
it.  Callers get the timeline and can identify the camera from the burnt-in
overlay.
"""

import struct
from dataclasses import dataclass
from datetime import datetime, timezone

# --- reclog.bin: the per-partition segment index --------------------------------
#
# Each partition carries a reclog.bin: a table of fixed 24-byte records, one per
# recorded container, that the DVR uses to find footage by time without opening
# every .dat.  Records start at 0x40 and run contiguously until an unused slot.
#
#   offset  size  field
#   0x00    4     record type (always 4 for a real record)
#   0x04    4     (always 0)
#   0x08    4     segment start, Unix seconds UTC
#   0x0c    4     segment end,   Unix seconds UTC
#   0x10    4     (always 2)
#   0x14    4     (a constant, identical on every partition)
#
# Record i maps positionally to the container 0000000i.dat on that partition.
# The records are time-contiguous, and the four partitions chain end to end into
# one ring buffer, so a chronological timeline across the whole disk is just
# every partition's segments sorted by start time.  No field names a camera --
# this DVR has only one.
RECLOG_BASE = 0x40
RECLOG_REC = 24
_RECLOG_TYPE = 4
# Sanity bound on the start-time field: Unix seconds within [2000, 2038], which
# rejects zero/uninitialised slots and misalignment without hard-coding a year.
_TS_MIN, _TS_MAX = 946_684_800, 2_145_916_800

FHDR_MAGIC = b"FHDR"
FTVT_TAG = b"FTVT"
REC_TAG = b"00db"
REC_SIZE = 20

# The header fields we read.  Kept as named offsets rather than a single struct
# unpack because most of the 0x48-byte header is still unidentified and hard
# offsets document what we actually rely on.
_OFF_MAGIC = 0x00
_OFF_TAG = 0x0C
_OFF_COUNT = 0x18
_OFF_INDEX = 0x30
_OFF_DATA = 0x34

# A container header plus its full index is small; 256 KiB covers the largest
# index seen with room to spare.  Callers fetching over the network only need
# to pull this much to list a container's contents.
HEADER_SPAN = 256 * 1024


class NotAContainer(ValueError):
    """The bytes are not an FTVT container (bad magic/tag)."""


@dataclass(frozen=True)
class Keyframe:
    frame: int          # cumulative frame number
    offset: int         # byte offset of the keyframe within the .dat file
    ts_us: int          # microseconds since Unix epoch, UTC

    @property
    def time(self) -> datetime:
        return datetime.fromtimestamp(self.ts_us / 1_000_000, tz=timezone.utc)


@dataclass(frozen=True)
class Container:
    data_offset: int            # where the H.264 stream starts
    keyframes: list[Keyframe]

    @property
    def start(self) -> datetime:
        return self.keyframes[0].time

    @property
    def end(self) -> datetime:
        return self.keyframes[-1].time

    @property
    def duration_s(self) -> float:
        return (self.keyframes[-1].ts_us - self.keyframes[0].ts_us) / 1_000_000

    def span_for(self, i: int, file_size: int | None = None) -> tuple[int, int]:
        """Byte range [start, end) of the H.264 for keyframe i to the next one.

        The last keyframe runs to file_size if given, otherwise to the last
        offset we can name (which truncates the final GOP -- pass file_size to
        play it whole).
        """
        start = self.keyframes[i].offset
        if i + 1 < len(self.keyframes):
            return start, self.keyframes[i + 1].offset
        return start, (file_size if file_size is not None else start)

    def span_from(self, i: int, file_size: int) -> tuple[int, int]:
        """Byte range from keyframe i to the end of the file (play to end)."""
        return self.keyframes[i].offset, file_size


@dataclass(frozen=True)
class Segment:
    index: int          # positional: this is container {index:08d}.dat
    start_s: int        # Unix seconds, UTC
    end_s: int

    @property
    def name(self) -> str:
        return f"{self.index:08d}.dat"

    @property
    def start(self) -> datetime:
        return datetime.fromtimestamp(self.start_s, tz=timezone.utc)

    @property
    def end(self) -> datetime:
        return datetime.fromtimestamp(self.end_s, tz=timezone.utc)


# The records occupy only the first ~11 KiB even on a full partition; this is a
# generous cap on how much of reclog.bin a caller needs to fetch.
RECLOG_SPAN = 64 * 1024


def parse_reclog(buf: bytes) -> list[Segment]:
    """Parse a reclog.bin into its list of segments, in on-disk (time) order.

    Scans records from RECLOG_BASE until the first unused or malformed slot.
    buf need only contain the populated head of the file (RECLOG_SPAN bytes is
    always enough).  Returns [] if the table is empty.
    """
    segs = []
    off = RECLOG_BASE
    i = 0
    while off + RECLOG_REC <= len(buf):
        rtype, _zero, start, end = struct.unpack_from("<IIII", buf, off)
        if rtype != _RECLOG_TYPE or not (_TS_MIN <= start <= _TS_MAX) or start > end:
            break
        segs.append(Segment(index=i, start_s=start, end_s=end))
        off += RECLOG_REC
        i += 1
    return segs


def parse_header(buf: bytes) -> Container:
    """Parse an FTVT header + index from the start of a container.

    buf must contain at least the header and the whole index; HEADER_SPAN bytes
    is always enough.  Raises NotAContainer on bad magic, ValueError if the
    index runs past the supplied buffer.
    """
    if len(buf) < 0x48:
        raise NotAContainer("buffer shorter than a container header")
    if buf[_OFF_MAGIC:_OFF_MAGIC + 4] != FHDR_MAGIC:
        raise NotAContainer(f"bad magic {buf[:4]!r}, expected {FHDR_MAGIC!r}")
    if buf[_OFF_TAG:_OFF_TAG + 4] != FTVT_TAG:
        raise NotAContainer(f"bad tag {buf[_OFF_TAG:_OFF_TAG+4]!r}")

    count = struct.unpack_from("<I", buf, _OFF_COUNT)[0]
    index_off = struct.unpack_from("<I", buf, _OFF_INDEX)[0]
    data_off = struct.unpack_from("<I", buf, _OFF_DATA)[0]

    end = index_off + count * REC_SIZE
    if end > len(buf):
        raise ValueError(
            f"index of {count} records at {index_off:#x} needs {end} bytes, "
            f"have {len(buf)}"
        )

    keyframes = []
    for i in range(count):
        rec = index_off + i * REC_SIZE
        if buf[rec:rec + 4] != REC_TAG:
            # A short or corrupt index: stop at the first non-record rather than
            # emit garbage.  Partly-filled containers end this way.
            break
        frame, offset = struct.unpack_from("<II", buf, rec + 4)
        (ts_us,) = struct.unpack_from("<Q", buf, rec + 12)
        keyframes.append(Keyframe(frame, offset, ts_us))

    if not keyframes:
        raise ValueError("container has no index records")
    return Container(data_offset=data_off, keyframes=keyframes)
