# Step 2: DRAM Topology and Kernel Virtual Split

Completed on 2026-08-13.

## Conclusion

The target has two independent 512 MiB DRAM banks:

```text
DDR0  0x80000000-0x9fffffff
hole  0xa0000000-0xbfffffff
DDR1  0xc0000000-0xdfffffff
```

The maintained source correctly measured that an address in the hole aliases
DDR0, but incorrectly extrapolated that observation to the DDR1 controller.
The guide's two-bank conclusion is correct for this target. The maintained DTS
and kernel configuration were changed; the guide does not need a correction
for this discrepancy.

## Runtime evidence

The board was running the vendor Linux 3.0.8 kernel with `mem=224M`. It was
rebooted into vendor U-Boot 2010.06, and autoboot was interrupted. No flash or
disk write command was used.

Because this U-Boot has no `dcache` command and enables its MMU during splash
setup, each comparison was followed by this read-only 4 MiB sweep before the
result was read:

```text
crc32 90000000 00400000
CRC32 for 90000000 ... 903fffff ==> e509efc5
```

The sweep exceeds the Cortex-A9 cache capacity and prevents a dirty cache line
from making two aliased DRAM locations appear independent.

### The maintained hole-alias observation is real

Initial values:

```text
88000000: c8000010
a8000000: c8000010
```

After writing `0x55667788` to `0xa8000000` and running the CRC sweep:

```text
a8000000: 55667788
88000000: 55667788
```

After restoring `0xc8000010` through `0xa8000000` and repeating the sweep, both
views again read `0xc8000010`. Thus the `0xa...` hole is decoded as an alias of
DDR0 on this board.

### DDR1 is not that alias

Initial values:

```text
81000000: 00000029
c1000000: 7fff7fff
```

After writing `0x11223344` to `0x81000000` and running the CRC sweep:

```text
81000000: 11223344
c1000000: 7fff7fff
```

The original DDR0 word was restored, another sweep was run, and both original
values were verified.

### Each independent bank spans 512 MiB

Four words 256 MiB apart retained distinct values after a CRC sweep:

```text
81000000: aaaa0000
91000000: aaaa0001
c1000000: bbbb0000
d1000000: bbbb0001
```

A second top-of-bank comparison retained different values near offset
+496 MiB:

```text
9f000000: aaaa0004
df000000: bbbb0004
```

Every modified word was restored to its recorded original content and
verified after another cache-eviction sweep. The board was then reset and left
to autoboot its normal vendor kernel.

## Linux 6.18.42 analysis

`arch/arm/mm/mmu.c:adjust_lowmem_bounds()` computes the low-memory ceiling from
`PAGE_OFFSET`, `PHYS_OFFSET`, and the vmalloc reservation. With this platform's
physical offset of `0x80000000`:

- The previous 3G split (`PAGE_OFFSET=0xc0000000`) has a default physical
  low-memory ceiling of `0xb0000000`, below DDR1.
- Because `CONFIG_HIGHMEM` is disabled, Linux would remove DDR1 and print
  `Ignoring RAM`.
- The 2G split (`PAGE_OFFSET=0x80000000`) has a default physical low-memory
  ceiling of `0xf0000000`, above both banks' end at `0xe0000000`.
- `CONFIG_HIGHMEM` is therefore unnecessary.
- `CONFIG_ARM_ATAG_DTB_COMPAT` remains disabled, preventing the vendor's
  incomplete ATAG memory description and `mem=224M` command line from replacing
  the appended DTB's description.

Linux 6.18.42's ARM Kconfig derives `CONFIG_PAGE_OFFSET=0x80000000` from
`CONFIG_VMSPLIT_2G=y`, matching the maintained configuration update.

## Source changes

- `hi3531-dhb-ax.dtsi` now gives its memory node two 512 MiB `reg` entries and
  distinguishes the real `0xa...` hole alias from independent DDR1.
- The no-reservation comment now locates U-Boot's read-only video buffers in
  DDR1 instead of incorrectly describing them as aliases of the kernel load
  area.
- `linux.config` now selects `CONFIG_VMSPLIT_2G=y` and
  `CONFIG_PAGE_OFFSET=0x80000000`; the 3G split remains disabled.

## Build verification

`scripts/buildroot.sh` completed successfully. The generated configuration is:

```text
# CONFIG_VMSPLIT_3G is not set
# CONFIG_VMSPLIT_3G_OPT is not set
CONFIG_VMSPLIT_2G=y
# CONFIG_VMSPLIT_1G is not set
CONFIG_PAGE_OFFSET=0x80000000
# CONFIG_HIGHMEM is not set
# CONFIG_ARM_ATAG_DTB_COMPAT is not set
```

Generated config checksum:

```text
84bc8230da191c707a92d3f35b8e7a465c773ee8eee8a011ab0ebd0bba9b0d33  /output/build/linux-custom/.config
```

Decompiling both generated DTBs produces the same memory node:

```dts
memory@80000000 {
    device_type = "memory";
    reg = <0x80000000 0x20000000 0xc0000000 0x20000000>;
};
```

Relevant output checksums:

```text
19c7c2a1dc07647d1949a573d8a8962450db8617f5f66f32133420fea56e6bc1  hi3531-dhb-ax.dtb
07e6d95cef7352e5b8d789c351398b01ba99c70286790d18c36529506fa3d83b  hi3531-dhb-ax-ethernet.dtb
39f02dbd17b41fadb57d5eae84958b825f546cab9684deb250aac1781f44d367  uImage-hi3531-dhb-ax
f8cbac9802e305c4db8094ecaefb4b7e69e3e88b442555acbcbae5dc756e972a  uImage-hi3531-dhb-ax-ethernet
```

No new compiler warning was observed. The baseline jobserver warning and
missing `/output/target/usr/libexec/` notice recurred.

## RAM-boot validation

The minimal image with SHA-256
`39f02dbd17b41fadb57d5eae84958b825f546cab9684deb250aac1781f44d367`
was subsequently loaded by TFTP to `0x82000000` and booted with
`bootm 0x82000000`. Flash and SATA were not written.

Linux 6.18.42 reported both complete ranges during early boot:

```text
node 0: [mem 0x0000000080000000-0x000000009fffffff]
node 0: [mem 0x00000000c0000000-0x00000000dfffffff]
Built 1 zonelists, mobility grouping on. Total pages: 262144
```

262,144 4 KiB pages equal exactly 1 GiB of physical RAM. The live system
reported:

```text
MemTotal:        1032968 kB
MemFree:         1015480 kB
MemAvailable:    1009492 kB

              total        used        free      shared  buff/cache   available
Mem:           1009           8         992           8           9         986
```

`/proc/iomem` confirmed both ranges as System RAM:

```text
80000000-9fffffff : System RAM
c0000000-dfffffff : System RAM
```

There was no `Ignoring RAM` message. This completes the Step 2 mainline boot
check for memory discovery and availability; broader staged device validation
remains in Step 9. The board was left running this RAM-booted minimal kernel.
