# Vendor kernel runtime probe

Captured 2026-08-04 from the LTS LTD2704XE-P's stock TVT firmware (Linux
3.0.8, built 2013-03-11), booted from NAND. Read-only inspection; nothing was
written.

This is the authoritative record of what hardware **this board** (`DHB_AX V1.2`,
per the PCB silkscreen) actually has
and uses, as distinct from what the HiSilicon reference tree says the SoC
family contains.

## CPU

    processors: 2          <- dual-core Cortex-A9

The port currently declares one CPU and builds with `CONFIG_SMP=n`, so it uses
half the machine. IPI counters confirm CPU1 is genuinely scheduled
(24914 timer broadcasts).

## Interrupts

Vendor numbers are GIC SPI + 32.

| Vendor IRQ | SPI | Device | Port status |
|---:|---:|---|---|
| 35 | 3 | System timer (SP804) | in use |
| 40 | 8 | uart-pl011 (UART0) | in use |
| 41 | 9 | uart-pl011 (UART1) | available |
| 42 | 10 | uart-pl011 (UART2) | available |
| 48 | 16 | Hi_IR infrared receiver | available |
| 61 | 29 | HiSilicon DMAC | available |
| 63 | 31 | ehci_hcd (USB 2.0) | available |
| 64 | 32 | ohci_hcd (USB 1.1) | available |
| 67 | 35 | hi_mci (SD/MMC) | **no slot on this board** — zero interrupts |
| 68 | 36 | ahci (SATA) | in use — confirms inferred value |
| 69–71 | 37–39 | L2 cache error/combined | not used |
| 79–103 | — | VPSS, VIU, VOU, VEDU, JPEGU, VDEC, TDE, VDA, VOIE, SCD | out of scope |
| 119 | 87 | stmmaceth (Ethernet) | in use — confirms inferred value |

Both interrupt numbers this port had *inferred* rather than read (SATA SPI 36,
GMAC SPI 87) are confirmed correct.

## Claimed IO memory

    10000000-10000100   hinand              NAND controller
    10010000-100100ff   hi_sfc              SPI NOR
    10020000-10020fff   hi_mci.0            SD/MMC          <- driver bound, nothing attached
    10080000-1008ffff   ahci.0              SATA
    100a0000-100affff   hiusb-ohci.0 -> ohci_hcd
    100b0000-100bffff   hiusb-ehci.0 -> ehci_hcd
    101c0000-101dffff   stmmaceth.0         Ethernet
    20080000-200bffff   uart:0..3           all four are uart-pl011
    20700000-2070ffff   l2cache.0           L2 cache controller
    20800000-20800fff   hisi pcie root complex.0
    30000000-377fffff   PCIE0 memory space
    60000000-677fffff   PCIE1 memory space
    80000000-8dffffff   System RAM (224 MiB; 32 MiB reserved for media)

USB uses **stock mainline `ehci_hcd` and `ohci_hcd`** under a thin
`hiusb-*` platform wrapper — the same shape as the AHCI glue this port already
has, so a clock/PHY init step is the expected work.

## PCIe

    0000:00:00.0   vendor 19e5 device 3531
    0000:02:00.0   vendor 19e5 device 3531

Vendor `19e5` is HiSilicon. **The two PCIe devices are further Hi3531 chips.**
This explains the cascade/host/slave modules in the vendor rootfs
(`hi35xx_dev_host.ko`, `hi35xx_dev_slv.ko`, `mcc_drv_*`, `pcit_dma_*`,
`pinctrl_cas_hi3531.sh`). The DVR is a multi-SoC design, with additional
Hi3531s handling extra video channels.

## Flash layout

    mtd0  2 MiB   boot
    mtd1  8 MiB   kernel
    mtd2 16 MiB   rootfs
    mtd3 64 MiB   user
    mtd4 32 MiB   hdr000000

## Registered devices of note

    50 ds1307        external I2C RTC, registered
   166 ttyACM        USB CDC ACM
   180 usb / 188 ttyUSB / 189 usb_device
    29 fb            framebuffer
    13 input
     8 sd / 11 sr / 21 sg / 254 bsg
    90 mtd / 31 mtdblock

## Two ambiguities resolved

The PrimeCell ID probe read all zeros at the DMA and I2C windows. The runtime
data explains both:

- **DMA is real and busy** (IRQ 29, 22873 counts under the vendor kernel), so
  the zero read was a gated clock, not absent hardware.
- **I2C is bit-banged over GPIO by the vendor** (`gpioi2c.ko` in the rootfs;
  no hardware I2C interrupt or IO range is claimed). The hardware block exists
  but the vendor never enables it, which is consistent with it reading as zero.

## Capturing this again

Boot the vendor firmware (let U-Boot autoboot rather than interrupting it),
log in as `root` with password `1001chin`, then read `/proc/cpuinfo`,
`/proc/interrupts`, `/proc/iomem`, `/proc/mtd`, `/proc/devices` and
`/proc/bus/pci/devices`. All read-only.

Worth re-reading if a question arises that the mainline port cannot answer
about how the vendor drives a block.
