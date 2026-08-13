# DHB_AX V1.2: investigation and backup record

The reverse-engineering phase of this project, completed 2026-08-03, plus the
verified flash backups it produced. This is a historical record: the
procedures here were used to understand the hardware and to capture every
flash layer before any of the porting work began.

For current work see the top-level `README.md` and `docs/porting.md`.

## Boot and flash layout

The partition definition is supplied as text in U-Boot's stored `bootargs`:

```text
mtdparts=hi_sfc:2M(boot);hinand:8M(kernel),16M(rootfs),64M(user),32M(hdr000000)
```

The SoC boot ROM starts U-Boot from SPI NOR. U-Boot reads its environment from
SPI NOR and passes `bootargs` to Linux. Linux's MTD command-line parser then
creates the named MTD devices. The flash chips themselves have no partition
concept.

| Linux MTD | Chip | Name | Offset on chip | Size | Format/use |
|---|---|---|---:|---:|---|
| `mtd0` | SPI NOR | `boot` | `0x000000` | 2 MiB | U-Boot + environment |
| `mtd1` | NAND | `kernel` | `0x0000000` | 8 MiB | legacy ARM uImage |
| `mtd2` | NAND | `rootfs` | `0x0800000` | 16 MiB | YAFFS2 root |
| `mtd3` | NAND | `user` | `0x1800000` | 64 MiB | YAFFS2 vendor data/app |
| `mtd4` | NAND | `hdr000000` | `0x5800000` | 32 MiB | YAFFS2 backup/data |

The declared NAND partitions occupy 120 MiB. The final 8 MiB,
`0x07800000-0x07ffffff`, is unpartitioned.

For the physical backup only, a volatile boot argument appended `8M(tail)` to
the NAND layout. This exposed that final range as `mtd5` without changing the
stored U-Boot environment or anything on flash.

Known bad NAND eraseblocks:

| Physical NAND offset | Location |
|---:|---|
| `0x03860000` | `user` |
| `0x03960000` | `user` |
| `0x04880000` | `user` |
| `0x05c20000` | `hdr000000` |
| `0x07e60000` | unpartitioned final 8 MiB |

There are no known bad blocks in `kernel` or `rootfs`.

## Stored U-Boot environment

The environment was located and CRC-validated directly in both verified SPI
images. An older note incorrectly called `0x0a0000` the start. The correct
layout is:

```text
offset:       0x080000
total size:   0x020000 (128 KiB)
data range:   0x080004-0x09ffff
end:          0x0a0000 (exclusive)
stored CRC32: 0x62132bef
computed CRC: 0x62132bef
```

The first four bytes are the little-endian CRC, followed by NUL-separated
`name=value` strings and erased padding. Important persistent values are:

```text
bootdelay=1
baudrate=115200
ethaddr=00:00:23:34:45:66
ipaddr=192.168.1.10
serverip=192.168.1.1
netmask=255.255.255.0
bootfile="uImage"
bootcmd=nand read 0x82000000 0x0 0x500000;bootm 0x82000000
phyaddr0=2
phyaddr1=1
phyintfx=0
bootargs=mem=224M console=ttyAMA0,115200 root=/dev/mtdblock2 rootfstype=yaffs2 mtdparts=hi_sfc:2M(boot);hinand:8M(kernel),16M(rootfs),64M(user),32M(hdr000000) pcieclkext=0
verify=n
```

`printenv` displays the working RAM copy. After temporary `setenv` commands it
does not exactly represent the stored SPI copy. A reset discards those RAM-only
changes.

## Ethernet findings

The board has two Synopsys DWMAC/GMAC controllers but one external Realtek
RTL8211CL PHY (marked `RTL8211CL` on the board, though it reports the
RTL8211B PHY ID `0x001cc912`, so Linux binds the B driver):

- PHY MDIO address: 1.
- The packet-data/RGMII path is physically wired to GMAC1 at `0x101c4000`.
- GMAC0 at `0x101c0000` can access the shared MDIO bus but its RGMII packet path
  is not connected to this PHY.
- The vendor's stock mapping is intentional: `phyaddr0=2`, `phyaddr1=1`,
  `phyintfx=0`.
- Do **not** set `phyaddr0=1`. It makes GMAC0 claim the PHY first: link status is
  visible over MDIO, but no Ethernet frames reach the wire.

### U-Boot Ethernet

Leave the PHY variables at their stored defaults. Set only temporary LAN values:

```text
setenv ipaddr 192.168.7.241
setenv netmask 255.255.252.0
setenv serverip 192.168.4.34
setenv ethaddr 00:18:AE:3C:A2:49
ping 192.168.4.34
```

Recheck the Pi address and confirm the chosen DVR address is unused first. Never
run `saveenv`. Four `No such device: 0:1` messages during network initialization
are noisy but non-fatal. Repeated initialization can also print
`miiphy_register: non unique device name '0:2'` without preventing traffic.

This vendor U-Boot uses `tftp` as an upload when address, filename, and size are
given:

```text
tftp <RAM-address> <destination-filename> <size>
```

In other words, data travels from the DVR to the Pi even though the command is
named `tftp`.

### Linux Ethernet from a minimal root shell

The vendor stmmac module must be loaded manually because vendor init is bypassed:

```sh
cd /hitoe
insmod stmmac.ko macsorts=1 phyid0=2 phyid1=1
ifconfig eth0 hw ether 00:18:AE:3C:A2:49
ifconfig eth0 192.168.7.240 netmask 255.255.252.0 up
```

With `macsorts=1`, physical GMAC1 becomes Linux `eth0`. Normal vendor boot uses
DHCP and was observed at `192.168.4.31`, but that lease can change.

## Completed backups

Backups are on the Pi under:

```text
/home/niallsmart/dhb_ax/backups/2026-08-03/
```

Each layer was read twice independently, and each pair passed both SHA-256 and
byte-for-byte comparison.

**On 2026-08-04 the redundant `-b` copies were deleted** after re-verifying
each pair byte-identical with `cmp`. One copy of each file remains here and a
second on the Raspberry Pi, so redundancy is now across two machines rather
than two files on one. `backups/2026-08-03/MANIFEST.md` records the SHA-256 of
what survives; the SPI NOR hash still matches the value captured at read time,
below.

### Layer 1: complete SPI NOR

Directory:

```text
/home/niallsmart/dhb_ax/backups/2026-08-03/spi-nor/
```

Files:

```text
dhb-ax-spi-nor-cold-a.bin  2,097,152 bytes
dhb-ax-spi-nor-cold-b.bin  2,097,152 bytes
```

SHA-256 for both:

```text
b0c66d971228a8a941e320282e6423330acf34064f11d0397698f4b8459a89c3
```

This also matches the earlier Mac workspace `dvr-spi-boot.bin`.

Read-only U-Boot procedure used:

```text
sf probe 0:1
sf read 0x82000000 0x0 0x200000
tftp 0x82000000 dhb-ax-spi-nor-cold-a.bin 0x200000
```

The SPI was read again before exporting copy B.

### Layer 2: complete NAND kernel partition

Directory:

```text
/home/niallsmart/dhb_ax/backups/2026-08-03/nand-kernel/
```

Files:

```text
dhb-ax-nand-kernel-cold-a.bin  8,388,608 bytes
dhb-ax-nand-kernel-cold-b.bin  8,388,608 bytes
```

SHA-256 for both:

```text
a5940ef07d37a3127d97f825d660199fef57cb9288039af2d1aa94857927161e
```

The image begins with valid legacy uImage structure recognized as:

```text
Linux-3.0.8, Linux/ARM, uncompressed OS kernel image
payload size: 3,629,636 bytes
built: 2013-03-11 03:23:48
load/entry: 0x80008000
header CRC field: 0x6fcdb0be
data CRC field: 0x7c24bf9b
```

Read-only U-Boot procedure used:

```text
nand info
nand bad
nand read 0x82000000 0x0 0x800000
tftp 0x82000000 dhb-ax-nand-kernel-cold-a.bin 0x800000
```

There were no bad blocks inside the kernel partition. The NAND was read again
before exporting copy B. One first TFTP attempt stalled before sending packets;
it was safely aborted, a successful `ping` refreshed network operation, and the
retry completed.

### Layer 3, step 1: YAFFS2 file-level archives

Directory:

```text
/home/niallsmart/dhb_ax/backups/2026-08-03/filesystems/
```

The DVR was booted with `ro init=/bin/sh`; the kernel explicitly reported the
YAFFS2 root mounted read-only. The vendor application was never started.
`user` and `hdr000000` were mounted with `-o ro`, and every temporary device
node and mount point lived on tmpfs. Each filesystem was traversed and streamed
to the Pi twice with BusyBox TAR and netcat.

| Filesystem | Archive names | Size each | Entries | SHA-256 for both |
|---|---|---:|---:|---|
| `rootfs` | `dhb-ax-rootfs-files-{a,b}.tar` | 9,851,904 bytes | 509 | `ce496377352763b31b983f8dd3b121829e7acb137b26dfa006679685299f9921` |
| `user` | `dhb-ax-user-files-{a,b}.tar` | 36,916,224 bytes | 2,068 | `96c7c0786c4bdb6b34aa45e42103305283a9a5494661accc764ddca7b6a3dfe2` |
| `hdr000000` | `dhb-ax-hdr000000-files-{a,b}.tar` | 2,048 bytes | 2 | `ae0105a21580023eb59082eb93994c61191fb6c4d592443222f3d219396aa401` |

Every archive passes `tar -tf`, and each A/B pair is byte-for-byte identical.
`hdr000000` contains only `./` and `./lost+found/`.

After capture, both auxiliary YAFFS2 mounts, `/proc`, and the temporary tmpfs
were unmounted successfully. No persistent DVR writes were made.

### Layer 3, step 2: complete physical NAND images with OOB

Directory:

```text
/home/niallsmart/dhb_ax/backups/2026-08-03/nand-physical/
```

Files:

```text
dhb-ax-nand-raw-oob-a.bin  138,412,032 bytes
dhb-ax-nand-raw-oob-b.bin  138,412,032 bytes
```

SHA-256 for both:

```text
dd4ff9df690f49539deb37c4e8ed2a263e0485d0cbadb0ef97a3aa14595d2c47
```

The files are byte-for-byte identical and mode `0444`. Each is a complete
128 MiB NAND capture containing all 65,536 physical pages. The on-disk format
is page-interleaved:

```text
[2,048-byte page data][64-byte OOB] repeated 65,536 times
```

Linux exposed only partition MTD devices rather than a whole-chip character
device. The reader therefore streamed these five contiguous ranges in order
into each single output file:

| Stream segment | NAND data range | Main data | Data + OOB |
|---|---:|---:|---:|
| `mtd1` `kernel` | `0x00000000-0x007fffff` | 8 MiB | 8.25 MiB |
| `mtd2` `rootfs` | `0x00800000-0x017fffff` | 16 MiB | 16.5 MiB |
| `mtd3` `user` | `0x01800000-0x057fffff` | 64 MiB | 66 MiB |
| `mtd4` `hdr000000` | `0x05800000-0x077fffff` | 32 MiB | 33 MiB |
| temporary `mtd5` `tail` | `0x07800000-0x07ffffff` | 8 MiB | 8.25 MiB |
| **Complete NAND** | `0x00000000-0x07ffffff` | **128 MiB** | **132 MiB** |

The temporary fifth partition was created by cold-resetting into U-Boot and
setting this complete RAM-only `bootargs` value:

```text
setenv bootargs 'mem=224M console=ttyAMA0,115200 root=/dev/mtdblock2 rootfstype=yaffs2 mtdparts=hi_sfc:2M(boot);hinand:8M(kernel),16M(rootfs),64M(user),32M(hdr000000),8M(tail) pcieclkext=0 ro init=/bin/sh'
nand read 0x82000000 0x0 0x500000
bootm 0x82000000
```

The kernel reported all five ranges and mounted the YAFFS2 root read-only. No
`saveenv` was issued. After mounting tmpfs on `/tmp`, temporary character nodes
were made for MTD minors 2, 4, 6, 8, and 10. The custom reader opened each node
with `O_RDONLY`, selected `MTD_FILE_MODE_RAW`, read every main-data page and OOB
area, and aborted on any short or failed read. It was transferred to and run
from tmpfs; its only output was the network stream.

Reader artifacts on the Pi:

```text
/home/niallsmart/dhb_ax/tools/nandrawdump.c
  SHA-256 37cd02bead80f3d09a7c1e4d4ad071a3f82809a18091b3d9248c196d143f4e9f
/home/niallsmart/dhb_ax/tools/nandrawdump
  SHA-256 5bec867004fd894584adcfe4738260d9a91bd5a4a8768b22817c780125cb47aa
/home/niallsmart/dhb_ax/tools/inspect_nand_raw.py
  SHA-256 5e09c1dbb3fbdd80327ffe057d3d35bc92b24b68841b5c6395fd39a8f728b04a
```

Validation with `tools/inspect_nand_raw.py` produced:

```text
SHA-256, all 128 MiB main areas:
67de5d7e01a61636874af123c119f541cd0ef4238ad71e96df25443a95892f1b

SHA-256, all 4 MiB OOB areas:
6b7f7ff21e87f7da0be07d749748e5c5672a8c28f67e53e5b9ef595887606e8c

SHA-256, extracted kernel main area:
a5940ef07d37a3127d97f825d660199fef57cb9288039af2d1aa94857927161e
```

The extracted kernel hash exactly matches both earlier Layer 2 kernel images.
The OOB bad-block marker scan found exactly five marked eraseblocks, at
`0x03860000`, `0x03960000`, `0x04880000`, `0x05c20000`, and `0x07e60000`.
Both marker bytes in the first two pages of each block were `0x00`; every other
eraseblock had `0xff` in both tested marker positions.

## Temporary Pi TFTP receiver

The installed service's default `TFTP_ADDRESS=":69"` failed on this Pi with an
address-family error. Use an explicitly IPv4, temporary daemon instead.

Before an upload, create an exact destination file owned by `tftp` and globally
writable; this server rejects U-Boot uploads otherwise:

```sh
install -o tftp -g tftp -m 0666 /dev/null /srv/tftp/FILENAME
/usr/sbin/in.tftpd --listen --address 0.0.0.0:69 --user tftp --secure /srv/tftp
pgrep -a in.tftpd
ss -lunp | grep ':69 '
```

After verifying and moving the received file into the backup directory:

```sh
chown niallsmart:niallsmart BACKUP-FILE
chmod 0444 BACKUP-FILE
pgrep -a in.tftpd
kill VERIFIED-PID
pgrep -a in.tftpd || echo NO_TFTPD_PROCESS
ss -lunp | grep ':69 ' || echo NO_UDP_69_LISTENER
```

Resolve and inspect the actual PID immediately before killing it; do not reuse a
PID from this document.

## Getting a minimal Linux root shell

This is the **vendor** kernel with its application bypassed, from the
investigation phase. It remains useful as a reference — it is how the runtime
probe in `docs/reference/vendor-runtime-probe.md` was captured, and the
only way to see the vendor's own drivers running. For the mainline port, boot
a `uImage-*` from the Pi's TFTP root instead.

Note the vendor system normally reaches a login prompt; the root password is
`1001chin`.

U-Boot has a one-second autoboot delay. Interrupt it during a cold boot, then
reproduce the stock kernel load while appending a temporary init override:

```text
nand read 0x82000000 0x0 0x500000
setenv bootargs ${bootargs} init=/bin/sh
printenv bootargs
bootm 0x82000000
```

Do not use `saveenv`. This stripped U-Boot has no working `boot`, `bootd`, or
`run`; `reset` restarts normal autoboot and discards temporary environment edits.

At the resulting `/ #` shell:

```sh
mount -t proc proc /proc
mount -t sysfs sysfs /sys
```

This kernel has no devtmpfs. Put manually created device nodes in a RAM-backed
temporary directory rather than `/dev` on the root filesystem. MTD character
devices use major 90. The read-only minor for MTD N is `2*N+1`:

```sh
mknod /tmp/mtd0ro c 90 1
mknod /tmp/mtd1ro c 90 3
mknod /tmp/mtd2ro c 90 5
mknod /tmp/mtd3ro c 90 7
mknod /tmp/mtd4ro c 90 9
```

Important: under `init=/bin/sh`, the shell has no controlling terminal. Ctrl-C
does not reliably signal foreground programs. Always use bounded commands such
as `ping -c N`; an unbounded foreground process can force a power cycle.

## Remaining backup and archival work

The raw+OOB physical images are complete. They preserve the accessible and
unused main areas, YAFFS2 metadata, ECC/OOB bytes, bad-block markers, and the
previously unpartitioned final 8 MiB.

### Main-area-only images — optional convenience copies

These omit the 64-byte OOB area and therefore are not complete, directly
restorable YAFFS2 images. They are useful for `binwalk`, `strings`, carving, and
binary comparisons.

Once validated raw+OOB images exist, derive main-area images on the Pi by keeping
each 2,048-byte data portion and removing each following 64-byte OOB portion.
This is preferable to another DVR read and avoids ambiguity from U-Boot's
bad-block skipping.
