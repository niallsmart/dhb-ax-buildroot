# Step 1: Source and Build Baseline

Captured on 2026-08-13 before making reconciliation changes to
`br2-external/`.

## Source state

- Git branch: `main`
- Git commit: `360a237302b16575ed7ba8a4cac2716fb3c6e97d`
- Commit subject: `ignore pdf`
- Worktree before the build: only the new, untracked
  `PORTING_GUIDE_RECONCILIATION.md`; no pre-existing maintained-source change
  needed to be preserved.
- Build command: `scripts/buildroot.sh`
- Build result: success, exit status 0.
- Build type: incremental against the existing named Docker output volume.
  This is the unchanged-source baseline. Step 8 deliberately reserves the
  destructive output reset and clean rebuild for final static validation.

The build used Buildroot 2026.02.3, Linux 6.18.42, and:

```text
arm-buildroot-linux-gnueabihf-gcc.br_real (Buildroot 2026.02.3) 14.3.0
GNU ld (GNU Binutils) 2.44
```

## Maintained input checksums

```text
72b57995b9356560d3cd0ed11c3ad76e051d15685f020594830f092bee79b1d3  br2-external/configs/dhb_ax_defconfig
6575c98e044c5934d25bdb4732b6bc7c2f3a8396485d1a925bd7ddf239e1e7de  br2-external/board/dhb_ax/linux.config
0dbafbd99e6fdbbe8e91c624ee8bc3fe31037a8de6194daa665e3944bcf19082  br2-external/board/dhb_ax/dts/hisilicon/hi3531-dhb-ax.dtsi
963cd311bfdf0426da79f57b8f7cebc1dc1438f2c97c48dfb488bc04c4ff0e89  br2-external/board/dhb_ax/dts/hisilicon/hi3531-dhb-ax.dts
e8671123ab22d694a31bbc7a3d49cc86a7d28307884cf055a228c2064fb31624  br2-external/board/dhb_ax/dts/hisilicon/hi3531-dhb-ax-ethernet.dts
```

Kernel patch checksums:

```text
8598f162f73f6e6c2453012b1fa5b9d6196fe9668e6af88a94b8818bb1db823b  0001-arm-dts-build-dhb-ax-device-trees.patch
78104ccb5d452ddc61dbb21aa765de1e1bcb20918f9e8b1f7655ca7b827f92ad  0002-arm-hisi-initialize-hi3531-uart-clock-mux.patch
8a3fd40996da240d19de95b103ad51085aec869994f3c270e63de1df9edba333  0003-net-stmmac-add-hi3531-glue.patch
003f3751eeedc0b6df07e82afd5ee2d6b0b2dc5b577cbc95b2d9a4d16e871caa  0004-net-stmmac-address-the-mac-block-through-pcsr.patch
115daf0d8986e8c00ce811ff3d0d8bdc642d97e5dc05f4bf4f8b79e48019ef70  0005-net-stmmac-add-a-per-instance-dma-register-base.patch
e33c69764824c6072db2a723ef31c53d86edf708391db1c135b65f4a52956a15  0006-net-stmmac-derive-ptp-and-mmc-bases-from-the-mac-block.patch
4b8530e3db01f285320f8909d6ebf63ca2e6bddf2036cfa7342bdaeb50e3d8b4  0007-ata-add-hi3531-ahci-glue.patch
0b3909b608942c80a4cf4cfb4591f45d6ac1c7afa8e200a1ee1aec602d7a573c  0008-gpio-pl061-skip-irqchip-without-parent-irq.patch
445d4c1530920ffc349265e5aee0ab5d0d970e7e4f6a1d52bd825399694d645e  0009-phy-hisilicon-add-hi3531-usb-phy.patch
```

## Generated configurations

The generated configurations in the `dhb-ax-br-output` Docker volume were:

```text
9b6aecec9a7c9a21f324800b15e960629aca4cc44eed38e0516281a5a25dcbc8  /output/.config
6fb2c9a82476618ef6d18cfc8341328366e5b3a21b65680ecd9d1bef0c5ef6dd  /output/build/linux-custom/.config
aa2f67d4e43fba5802559453fe0f73d35d23a67aa7a41c7fb6ac7c64daebecf0  /output/build/busybox-1.37.0/.config
```

The generated Linux configuration differs from the maintained input only in
compiler/binutils capability detection and Buildroot's generated
`CONFIG_INITRAMFS_SOURCE="${BR_BINARIES_DIR}/rootfs.cpio"`. The settings that
form the current reconciliation baseline are:

```text
CONFIG_ARCH_HISI=y
CONFIG_SMP=y
CONFIG_NR_CPUS=2
CONFIG_VMSPLIT_3G=y
CONFIG_PAGE_OFFSET=0xC0000000
CONFIG_ARM_APPENDED_DTB=y
# CONFIG_ARM_ATAG_DTB_COMPAT is not set
# CONFIG_ARM_ERRATA_754322 is not set
CONFIG_ARM_ERRATA_764369=y
# CONFIG_ARM_ERRATA_775420 is not set
CONFIG_STMMAC_ETH=y
CONFIG_GPIO_PL061=y
CONFIG_I2C_GPIO=y
# CONFIG_RTC_DRV_PL031 is not set
```

BusyBox has `MKE2FS` and `MKDOSFS` enabled in its generated configuration, but
the post-build script deliberately removes the corresponding binaries from the
target. It reports that writers are absent and read-only tools are present.

## Artifacts

All artifacts below were installed at 2026-08-13 16:02 local time. The uImages
use load and entry address `0x80008000`.

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `hi3531-dhb-ax-ethernet.dtb` | 6,456 | `eb45cceec28d4ae5034177cdd342bbafa0e0e97ded56a207e7353e7bb5ebcd58` |
| `hi3531-dhb-ax.dtb` | 1,888 | `bf72deeb4e56a5db3375ec653ca2f2ff6df97305a3f5137a52726946e1d43a12` |
| `rootfs.cpio` | 8,512,512 | `4e366c97a4ad39a9c41a5bba7837ef485a7acc5e7bfbb7d06620c7da37e438ad` |
| `rootfs.tar` | 9,297,920 | `775a7436df5e6c30a881b8ce508a53fd105a3b63e3031607b93431d06eb7e526` |
| `uImage-hi3531-dhb-ax` | 6,868,496 | `d67dda80bffe956f2039671fc3f3337b4abeeec54e3a8eda77a42c9715e284ed` |
| `uImage-hi3531-dhb-ax-ethernet` | 6,873,064 | `577225cb63ff50569b4e97f4b2c91b042eee251e822288040e42153670fcbc00` |
| `zImage` | 6,866,544 | `cd4e2dbdb84149762a85f9b0dfca6a756a8c5bbda2262c89e7718b1f67bc7c83` |
| `zImage-hi3531-dhb-ax-appended-dtb` | 6,868,432 | `230ac82c6f3a2733846b9d0d4e37501586c7330ab1c0186e018d0ea0abf6965e` |
| `zImage-hi3531-dhb-ax-ethernet-appended-dtb` | 6,873,000 | `5c2b5fbdbefc838f59e5b28d7b728d4108f44f397ff1f2a9c95241f3cce50810` |

The uImage metadata identifies both payloads as uncompressed Linux/ARM 6.18.42
images. Their names are `Linux-6.18.42 hi3531-dhb-ax` and the U-Boot-truncated
`Linux-6.18.42 hi3531-dhb-ax-ethe`.

## Patch integrity

The nine patches were applied in lexical order to a fresh extraction of
`kernel/linux-6.18.42.tar.xz`, independently of Buildroot, using:

```text
patch --batch --forward --fuzz=0 -p1
```

Every patch applied successfully. The resulting temporary verification tree
also contains the expected Hi3531 DWMAC, AHCI, and USB PHY Kconfig additions.
Buildroot's successful kernel build provides a second check that the applied
tree compiles.

## Baseline diagnostics

No error remained at build completion. Diagnostics worth retaining for later
comparison were:

- BusyBox Kconfig warns that `ASH_SLEEP` is a nonexistent symbol at line 1154
  of its generated configuration.
- BusyBox emits ignored-return-value warnings for `setgid`/`setuid` in
  `libbb/appletlib.c` and `write` in `shell/ash.c`.
- Nested make reported jobserver-unavailable warnings and fell back to `-j1`.
- A target-finalization `find` reported that `/output/target/usr/libexec/` did
  not exist; the surrounding operation and build continued successfully.
- BusyBox configuration refresh printed a large prompt/default transcript but
  required no user input and completed successfully.

These are baseline tool/package diagnostics, not evidence for any porting-guide
discrepancy. Step 8 will distinguish persistent upstream/build-system warnings
from warnings introduced by reconciliation changes.
