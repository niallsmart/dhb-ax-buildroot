# Step 9: staged read-only hardware validation

Date: 2026-08-14

## Result

The reconciled Linux 6.18.42 kernel completed the staged hardware-validation
sequence without an Oops, panic, RCU stall, lockup, or fatal bus error. The
image was loaded into RAM over TFTP and mounted its Buildroot root filesystem
over NFS; board flash and the attached SATA disk were not written.

Validated image:

```text
artifacts/buildroot/uImage-hi3531-dhb-ax-ethernet
SHA-256 56ff2bd1895adb61354faae5fcb0271582d7f48aca0343ecc0c536941e87c23b
Linux 6.18.42 #1 SMP Fri Aug 14 13:38:00 UTC 2026
```

The storage-autoload follow-up rebuilt the same maintained kernel and changed
only the rootfs policy. Its final artifacts are:

```text
uImage SHA-256 f76b72cacf9d5195096ff1131b90abcc8bd0955515bab63ab9a7cf0df970f634
rootfs SHA-256 04fe061a5d3d6fd4262d689ad9d537dbf8b4ec9ba3cabbff6f7bc5a75bfab826
Linux 6.18.42 #1 SMP Fri Aug 14 15:59:21 UTC 2026
```

`tools/dvr-boot.exp --stage` atomically staged the local image, verified the
remote SHA-256, warm-rebooted the DVR, interrupted U-Boot, and returned to a
Linux login prompt. `STEP-9-WARM-BOOT.log` is the local serial transcript.

## Memory and SMP

The post-reboot kernel reported:

```text
Memory: 1030624K/1048576K available
MemTotal: 1032928 kB
cpu online: 0-1
smp: Brought up 1 node, 2 CPUs
SMP: Total of 2 processors activated
```

There was no `Ignoring RAM` diagnostic. This confirms both independent 512 MiB
banks are present through the reconciled 2G/2G virtual split.

Two concurrent, in-memory 512 MiB zero streams were hashed. Both produced
`9acca8e8c22201155389f65abbf6bc9723edc7384ead80503839f49dcc56d767`
and exited zero. During that load, CPU0 accumulated 3,068 non-idle scheduler
ticks and CPU1 accumulated 3,146; both remained online. The subsequent warm
reboot also returned with both CPUs and all 1 GiB available.

## GPIO, I2C, and RTC

The `gpio-pl061` AMBA driver bound all 19 expected banks, from
`20150000.gpio` through `20270000.gpio`. The boot log contains one successful
registration for each bank.

The root-level `i2c-gpio` controller registered I2C bus 0 using GPIO lines 612
and 613. The external clock bound as `rtc-ds1307 0-0068`, registered `rtc0`,
and set the system clock at boot. A read-only `hwclock -r` agreed with
`/proc/driver/rtc`; no RTC register was written.

## Ethernet

The current image negotiated 1000 Mb/s, full duplex, with autonegotiation and
flow control. Ten pings to the NFS/TFTP Pi completed with zero loss and about
1.05 ms average latency.

Two 128 MiB in-memory streams, one in each direction over SSH, produced the
same SHA-256:

```text
254bcc3fc4f27172636df4bf32de9f107f620d559b20d760197e452b97453917
```

The kernel RX and TX error counters remained zero. `rx_dropped` increased from
11 to 17 during the transfer; the driver-specific counters remained clean,
including CRC errors, GMAC overflow, missed frames, descriptor errors, stopped
RX/TX processes, and fatal bus errors.

A deliberate link drop was not repeated while the current image used a hard
NFS root. Step 7 already exercised a forced 100/full transition and return to
1000/full with zero loss using the same reconciled Ethernet driver and binary
configuration. The Step 8 changes after that test were DTS placement/unit-name
corrections, generated-config refresh, patch-context refresh, and archive
hashes; none changed Ethernet runtime behavior.

## SATA

The initial image kept SATA modular but did not request the module during
startup. After validating it with a read-only `modprobe ahci_hi3531`, normal
Buildroot bring-up was updated with
`/etc/modules-load.d/storage.conf`. Buildroot's standard `S11modules` script now
reports `ahci_hi3531 OK` and loads the controller and its dependencies without
a custom init script.

On the final boot, AHCI probe began at 3.75 seconds and disk attachment
completed at 19.46 seconds. The controller reported AHCI 1.2, 3 Gb/s
capability, 32 command slots, and both ports implemented. Port 2 enumerated a
five-port JMicron `197b:0325` SATA multiplier at 1.5 Gb/s. The disk appeared
on multiplier port 2 as:

```text
WDC WD10EURX-63C57Y0, firmware 01.01A01
1953525168 sectors, 1.00 TB / 932 GiB
512-byte logical blocks, 4096-byte physical blocks
```

The four expected partitions were present:

| Partition | Start sector | Sectors |
|---|---:|---:|
| `sda1` | 63 | 488375937 |
| `sda2` | 488376000 | 488376000 |
| `sda3` | 976752000 | 488376000 |
| `sda4` | 1465128000 | 488376000 |

No `sda` partition was mounted. The block device reports `ro=0`, so Linux is
technically capable of writing it, but validation issued no write, filesystem
mount, filesystem check, or filesystem probe. A raw read of the first 1 MiB
completed with SHA-256
`58e392f8cc492aad3749775687b5a85a6dc0caf29306acb81c0e00846133a353`.

## USB

The corrected `20030000.usb-phy` platform device bound to
`hi3531-usb-phy`. OHCI at `100a0000` and EHCI at `100b0000` both bound and
enumerated their two-port root hubs:

| Bus | Controller | Speed |
|---|---|---:|
| `usb1` | EHCI Host Controller | 480 Mb/s |
| `usb2` | Generic Platform OHCI controller | 12 Mb/s |

A Corsair Flash Voyager (`090c:1000`, serial `A500000000025556`) enumerated on
front-panel EHCI port `usb1/1-1` at 480 Mb/s. Loading the in-tree
`usb_storage` module produced removable block device `/dev/sdb`, with
15,728,640 512-byte sectors (8.05 GB / 7.50 GiB). After the destructive test,
`usb_storage` was added to `storage.conf`. A clean boot loaded it automatically
at 19.28 seconds and attached the device at 20.45 seconds.

With explicit authorization to destroy this USB device's contents, four
distinct deterministic 128 MiB patterns were written at dispersed offsets and
read back. All readback SHA-256 values matched:

| Region | Offset | SHA-256 | Elapsed |
|---|---:|---|---:|
| start | 0 MiB | `31994d3c01ac3e2e4aeae53970fb097e4bba1bec933f3c01e0b42c868c1886d8` | 71 s |
| first third | 2517 MiB | `dc8fe3a8e386639846014451ce68e4780693d918167cf7bf1389a593db3f314c` | 62 s |
| second third | 5034 MiB | `bd9d40bc5a2024d497918cfad56217e795deae425636ff98a1148eb095e85e7c` | 75 s |
| end | 7552 MiB | `643a95fddc42e4474eba3292da9a2cc3a01e5bfd4d458fc1909ff60d1b7719a3` | 61 s |

The 512 MiB aggregate test therefore exercised the beginning, interior, and
end of the address space. Kernel logs contained no USB reset, disconnect,
transport, or I/O errors. The write at offset zero destroyed the previous
partition table and data. Reloading `usb_storage` forced a clean rescan and
removed the former `sdb1` and `sdb2` partition devices; only the whole-device
`sdb` node remains.

Safety guards checked the exact device size, removable flag, and EHCI sysfs
path before writing. Post-test checks reconfirmed `/dev/sda` as the non-removable
1 TB `WDC WD10EURX-63C` SATA disk with its original four partitions. Neither
disk was mounted, and no SATA write was issued.

## SP805 watchdog

`sp805_wdt` loaded and registered the watchdog at `20040000`. It initially
reported `state=inactive`, `timeout=60`, `nowayout=0`, and `bootstatus=0`.
The timeout sysfs attribute is read-only in this build, so the default
60-second timeout was used.

Opening `/dev/watchdog` started the counter. Four samples taken over six wall
seconds read 59, 57, 55, and 53 seconds remaining. Writing the magic-close
character and closing the file returned the watchdog to `state=inactive`.
This validates one-second timeout accounting with the described 3 MHz clock
without deliberately resetting the board.

## Step 10 follow-up

- The stale SATA comment now records the validated controller, multiplier,
  disk enumeration and read path.
- `AGENTS.md` now states that the port declares both 512 MiB banks and uses the
  ARM 2G/2G virtual split.
- Preserve the explicit Ethernet limitation above: the current hard-NFS-root
  boot was not intentionally deprived of its link.
