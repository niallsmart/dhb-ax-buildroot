# DHB_AX V1.2: binwalk and firmware-inspection notes

Last updated: 2026-08-04.

Working notes on the tools used to inspect the flash images in
`../backups/`, and on where those tools mislead. Written after a session in
which the default binwalk missed two of the three interesting things in these
images.

## Summary

**No single tool here is authoritative.** The two most consequential findings
in this project's flash images — the boot splash JPEG in SPI NOR, and the fact
that the vendor kernel is a compressed zImage rather than a flat binary — were
both missed by the binwalk that ships in `PATH`.

Cross-check before concluding that a region is empty or that a file is what
its container claims.

## Tool inventory

| Tool | Source | Job |
|---|---|---|
| `binwalk` 3.1.0 | Homebrew, in `PATH` | Fast signature scan, extraction. Rust rewrite |
| `binwalk` 2.3.3 | GitHub tag, via `uvx` | Signature scan with much wider coverage. Original Python |
| `file` | system | Identify a single carved file. Uses libmagic; the most reliable of the three |
| `hexdump` / `xxd` | system | Region boundaries, byte-level confirmation |
| `dd` + `tr` | system | Quantitative erase-block occupancy |

### Running the Python binwalk

The PyPI package named `binwalk` is a broken 2.1.0 stub — it installs but
raises `ModuleNotFoundError: No module named 'binwalk.core'`. The real Python
release is a git tag; the repository's default branch is now the Rust v3.

```sh
uvx --python 3.11 --from git+https://github.com/ReFirmLabs/binwalk@v2.3.4 binwalk <file>
```

Python 3.11 is pinned because the 2.3.x code contains idioms that fail on
3.14 (`if child_pid is 0`). `uvx` keeps it in an isolated, cached environment,
so it does not shadow the Homebrew `binwalk` in `PATH`.

## v3 versus v2 on this project's images

| Target | binwalk 3.1.0 | binwalk 2.3.3 |
|---|---|---|
| `spi-nor/dhb-ax-spi-nor-cold-a.bin` | CRC32 table only | + the splash JPEG at `0xC0000` |
| `nand-kernel/dhb-ax-nand-kernel-cold-a.bin` | uImage header only | + zImage at `0x40`, + gzip at `0x5698` |
| A known-good JPEG | nothing | correct |
| False positives | none observed | one bogus "bix header" |

v3 is not simply worse. It is **stricter with narrower coverage**: it produced
no false positives all session, while v2 reported a header claiming a
770,244,688-byte image inside a 2 MiB file.

## Three distinct v3 behaviours, only one of which is a bug

### 1. JPEG is never detected — a bug

The signature is registered (`binwalk --list` shows `JPEG image / jpeg /
Built-in`, and `-y jpeg` loads exactly one pattern), but it does not fire on a
valid standalone JPEG with no container involved. Confirmed against both an
Exif file and an ordinary JFIF camera photo.

Known upstream:

- [Issue #750](https://github.com/ReFirmLabs/binwalk/issues/750) — v3 does not
  recognise signatures that v2 did, JPEG specifically.
- [Issue #829](https://github.com/ReFirmLabs/binwalk/issues/829) — tracks which
  magic patterns from v2.3.4 have been ported to the Rust version and which
  have not.

Check whether a release after 3.1.0 has closed these before relying on v3
for image formats.

### 2. Signatures inside an identified container are suppressed — by design

v3 does not report nested signatures once it has identified a container.
Demonstrated on the vendor kernel:

| Input | gzip detected? |
|---|---|
| Full gzip stream carved standalone | yes |
| zImage with the 64-byte uImage header stripped | yes, at `0x5658` |
| Same bytes with the uImage header intact | **no** |

The intended workflow is `-e` to extract and `-M/--matryoshka` to rescan
recursively. v2 reported everything inline instead.

**Practical consequence:** whenever v3 identifies a container, assume you are
seeing the wrapper and nothing inside it. This is exactly how the zImage
stayed hidden.

### 3. No 32-bit ARM zImage signature — a coverage gap

`--list` has `linux_arm64_boot_image` and a generic `linux_boot_image`, but
nothing matching a 32-bit ARM zImage. v2 has it. Same bucket as #829.

## Gotchas that cost time

- **`-y/--include` swallows the filename.** `binwalk -y jpeg file.bin` panics
  with "No target file name specified!" because the option is variadic. Use
  `binwalk -y jpeg -- file.bin`.
- **zsh does not word-split unquoted variables.** Putting a multi-word command
  in a shell variable and expanding it as `$CMD file` fails in zsh where it
  would work in bash. Combined with `2>/dev/null` this silently looks like
  "the tool found nothing". Use an array, `${=VAR}`, or write the command out.
- **A truncated carve fails validation, correctly.** Carving 200 KB out of a
  3.6 MB gzip stream and scanning it produces no result — because it is not a
  valid gzip stream. That is the tool being right.
- **`tr` needs `LC_ALL=C`** to handle `0xFF` bytes; without it you get
  "Illegal byte sequence" and wrong counts.

## Recipes

### Erase-block occupancy map

The most useful first look at a flash image. Blocks reporting `0` are fully
erased.

```sh
export LC_ALL=C
i=0
while [ $i -lt 32 ]; do
  n=$(dd if=IMAGE bs=65536 skip=$i count=1 2>/dev/null | tr -d '\377' | wc -c)
  printf "block %2d  0x%06x  %s\n" "$i" $((i*65536)) "$n"
  i=$((i+1))
done
```

Note this counts non-`0xFF` bytes. A region padded with `0x00` reads as full,
not empty — which is the case for SPI blocks 12-13, holding the splash JPEG
plus zero padding.

### Region boundaries

`hexdump -C` collapses repeated identical lines to `*`, so erased runs
disappear. Printing the line after each run gives the boundaries:

```sh
hexdump -C IMAGE | grep -A1 '^\*$'
```

### Reading the vendor kernel

The payload is a zImage, so the kernel proper must be decompressed before
`strings`, symbol extraction, or disassembly will work:

```sh
dd if=dhb-ax-nand-kernel-cold-a.bin bs=1 skip=$((0x5698)) | gunzip > vmlinux.bin
strings vmlinux.bin | grep 'Linux version'
```

## Findings this produced

### The vendor kernel is a compressed zImage

The `uImage` header says `compression: none`, which means only that U-Boot
does not have to decompress before jumping in. The payload is an ARM zImage —
a decompressor stub plus the gzip-compressed kernel.

- ARM zImage magic `0x016F2818` at file offset `0x64`
- gzip stream begins at `0x5698`, length 3,607,483 bytes
- decompresses to 6,909,316 bytes

`investigation.md` describes this image as an "uncompressed legacy uImage",
which is accurate about the header field and misleading about the contents.
Worth amending there.

### The vendor kernel's build banner

```text
Linux version 3.0.8 (lzg@localhost.localdomain)
  (gcc version 4.4.1 (Hisilicon_v100(gcc4.4-290+uclibc_0.9.32.1+eabi+linuxpthread)))
  #20121101111407 SMP Mon Mar 11 11:23:32 CST 2013
```

- Built by an individual on their own machine, not a build server — a
  developer's working copy rather than a clean SDK checkout.
- HiSilicon's own gcc 4.4.1 uclibc toolchain, so built inside the vendor SDK.
- `#20121101111407` is a timestamp used as a build ID: 2012-11-01, the same
  date the vendor U-Boot was built.
- `CST` is China Standard Time. `11:23:32 CST` is `03:23:32 UTC`; the uImage
  header records the wrapping step at `03:23:48 UTC`, sixteen seconds later.
- `SMP` matches the `vermagic=3.0.8 SMP mod_unload ARMv7` string carried by
  the vendor kernel modules.

This bears on the provenance question: the running kernel was not built from a
pristine tree, which lowers the odds that any public source tree matches it
exactly.

### SPI NOR contents

See `u-boot-chainload-plan.md` for the full occupancy map. Structures
identified:

| Offset | Contents |
|---|---|
| `0x0C0000-0x0D156E` | Boot splash JPEG, 71,023 bytes, 480x300, Exif, `software=www.meitu.com` |
| `0x0BFC20` | Config record: MAC `00:18:ae:3c:a2:49`, `v1.2`, `1156f` |
| `0x0FFC20` | Byte-identical backup of the same record |

`1156f` is `0x1156F` = 71,023 — the splash image's length in hex, stored as an
ASCII string.

## Recommended workflow

1. Occupancy map with the `dd` loop, to see the shape of the image.
2. Python binwalk via `uvx` as the primary signature scan.
3. Rust binwalk for speed, extraction, and entropy (`-E`) — always with
   `-e -M` when a container is identified.
4. `file` on anything carved out.
5. Confirm every hit by hand: check the magic sits at its documented offset
   and that reported sizes are physically possible.

**Do not treat "binwalk found nothing" as evidence that nothing is there.**
This matters directly for the U-Boot chainload plan, where an empty-looking
region is about to be erased.
