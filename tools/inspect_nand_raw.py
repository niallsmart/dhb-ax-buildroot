#!/usr/bin/env python3

import argparse
import hashlib
from pathlib import Path


PAGE_DATA_SIZE = 2048
PAGE_OOB_SIZE = 64
PHYSICAL_PAGE_SIZE = PAGE_DATA_SIZE + PAGE_OOB_SIZE
ERASEBLOCK_DATA_SIZE = 128 * 1024
PAGES_PER_ERASEBLOCK = ERASEBLOCK_DATA_SIZE // PAGE_DATA_SIZE
NAND_DATA_SIZE = 128 * 1024 * 1024
EXPECTED_FILE_SIZE = (NAND_DATA_SIZE // PAGE_DATA_SIZE) * PHYSICAL_PAGE_SIZE

PARTITIONS = (
    ("kernel", 0x00000000, 0x00800000),
    ("rootfs", 0x00800000, 0x01000000),
    ("user", 0x01800000, 0x04000000),
    ("hdr000000", 0x05800000, 0x02000000),
    ("tail", 0x07800000, 0x00800000),
)


def inspect(path: Path) -> None:
    size = path.stat().st_size
    if size != EXPECTED_FILE_SIZE:
        raise SystemExit(
            f"wrong file size: got {size}, expected {EXPECTED_FILE_SIZE}"
        )

    full_hash = hashlib.sha256()
    main_hash = hashlib.sha256()
    oob_hash = hashlib.sha256()
    partition_hashes = {name: hashlib.sha256() for name, _, _ in PARTITIONS}
    bad_markers = []
    first_two_oobs = {}

    page_count = NAND_DATA_SIZE // PAGE_DATA_SIZE
    with path.open("rb") as image:
        for page_number in range(page_count):
            physical_page = image.read(PHYSICAL_PAGE_SIZE)
            if len(physical_page) != PHYSICAL_PAGE_SIZE:
                raise SystemExit(f"short read at page {page_number}")

            page_data = physical_page[:PAGE_DATA_SIZE]
            page_oob = physical_page[PAGE_DATA_SIZE:]
            data_offset = page_number * PAGE_DATA_SIZE

            full_hash.update(physical_page)
            main_hash.update(page_data)
            oob_hash.update(page_oob)

            for name, start, length in PARTITIONS:
                if start <= data_offset < start + length:
                    partition_hashes[name].update(page_data)
                    break
            else:
                raise SystemExit(f"page outside partition map: {page_number}")

            page_in_block = page_number % PAGES_PER_ERASEBLOCK
            if page_in_block in (0, 1):
                block = page_number // PAGES_PER_ERASEBLOCK
                first_two_oobs.setdefault(block, []).append(page_oob)

    for block, oobs in first_two_oobs.items():
        marker_values = (oobs[0][0], oobs[1][0])
        if marker_values != (0xFF, 0xFF):
            bad_markers.append((block, marker_values, oobs))

    print(f"file: {path}")
    print(f"physical_size: {size}")
    print(f"pages: {page_count}")
    print(f"sha256_physical: {full_hash.hexdigest()}")
    print(f"sha256_main_all: {main_hash.hexdigest()}")
    print(f"sha256_oob_all: {oob_hash.hexdigest()}")
    for name, _, _ in PARTITIONS:
        print(f"sha256_main_{name}: {partition_hashes[name].hexdigest()}")

    print(f"bad_marker_blocks: {len(bad_markers)}")
    for block, marker_values, oobs in bad_markers:
        address = block * ERASEBLOCK_DATA_SIZE
        print(
            f"bad_marker: block={block} address=0x{address:08x} "
            f"page0_oob0=0x{marker_values[0]:02x} "
            f"page1_oob0=0x{marker_values[1]:02x} "
            f"page0_oob16={oobs[0][:16].hex()} "
            f"page1_oob16={oobs[1][:16].hex()}"
        )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Inspect a 2048+64-byte interleaved raw NAND image"
    )
    parser.add_argument("image", type=Path)
    args = parser.parse_args()
    inspect(args.image)


if __name__ == "__main__":
    main()
