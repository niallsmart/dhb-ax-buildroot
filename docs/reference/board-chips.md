# Chips on the board

Read off the PCB from photographs in `pcb/`, 2026-08-04. This is a fifth
evidence source alongside the four in the README, and the only one that can
settle what is physically fitted — as opposed to what a chip family offers,
what the vendor built for, or what a driver decided to call something.

The board itself is silkscreened **`DHB_AX V1.2`**.

## Identified

| Marking | Part | Photo | Notes |
|---|---|---|---|
| `LATTICE LFE3-17EA 6FTN256C` | Lattice ECP3-17EA FPGA, 256-ball BGA | 3463 | Malaysia, date code 1315 |
| `nextchip NVP1104B` | Nextchip 4-channel analogue video decoder | 3464 | 128-pin QFP |
| `ATMEL AT89S52 24JU` | Atmel 8051 microcontroller, PLCC-44, 24 MHz | 3465 | date code 1043A |
| `JMicron JMB321` | 5-port SATA port multiplier | 3466 | date code 1325 |
| `REALTEK RTL8211CL` | Gigabit Ethernet PHY, 48-pin QFP | 3467 | Taiwan, `D3G54Q2` |
| `PNS21` + TI logo | unidentified Texas Instruments part, TSSOP-48 | 3471 | near the HDMI connector |
| `NBDG / 638 / 413` | unidentified, small QFN | 3468 | marking code, not a part number |
| (illegible) | unidentified, SOIC-8 | 3470 | package suits SPI flash; marking too worn |

## What this corrects

**The port multiplier is a JMB321, not a JMB325.** This tree previously said
JMB325, inferred from the ID Linux reports:

```text
ata2.15: Port Multiplier 1.2, 0x197b:0x0325 r0, 5 ports
```

`0x197b` is JMicron and `0x0325` is a product ID; reading `325` as the part
number was a guess that the silkscreen disproves. Nothing depends on it.

**The Ethernet PHY is an RTL8211CL, not an RTL8211B.** Linux says:

```text
PHY [stmmac-0:01] driver [RTL8211B Gigabit Ethernet]
```

but that is the driver's name for the ID it matched, not the part fitted.
Confirmed on hardware:

```text
/sys/bus/mdio_bus/devices/stmmac-0:01/phy_id -> 0x001cc912
```

Mainline matches PHY IDs exactly: `0x001cc912` is the RTL8211B entry,
`0x001cc913` the RTL8211C. So this C-series part reports the B-series ID and
binds to the B driver.

That has one real consequence. The RTL8211C entry carries a quirk the B entry
does not:

```c
static int rtl8211c_config_init(struct phy_device *phydev)
{
	/* RTL8211C has an issue when operating in Gigabit slave mode */
	return phy_set_bits(phydev, MII_CTRL1000,
			    CTL1000_ENABLE_MASTER | CTL1000_AS_MASTER);
}
```

We do not get that quirk. Empirically the link is fine — 1 Gbps full duplex,
tens of thousands of packets at 0% loss, sustained transfers — so this is
recorded as a risk, not a fault. **If gigabit link stability ever becomes
flaky, force master mode here first.** The vendor's own driver worked the same
way, since the ID is what it saw too.

## What this explains

**The FPGA is real, and it is never programmed on this board.**
`fpga_jtag.ko` had no matching hardware in any earlier source; the Lattice
ECP3 accounts for it. The module is 526 KB, of which 509,676 bytes are
`.rodata` against 8 KB of code, and it contains Lattice's ispVME JTAG player
(`ispVMShiftExec`, `_SVME1.x`, `slim_vme.c`). So the SoC programs the FPGA by
bit-banging JTAG, with the bitstream embedded in the module — necessary
because an ECP3 is SRAM-based and forgets its configuration at power-off.

But the vendor only loads it for one product variant:

```sh
if [ $SDK_TYPE = "8720p" ]; then
        insmod extdrv/fpga_jtag.ko
fi
```

and `dep2.sh` selects `4hd` for this board: the PCI test looks for
`19e53532` while these companions are `19e5:3531`, and the cmdline test for
`(hdr` matches the flash partition named `hdr000000`. So the FPGA is fitted
but inert under the vendor's own firmware as much as ours — an
eight-channel-720p feature this four-channel board does not use. Nothing is
missing from this port by leaving it alone.

Note the product identity rides on a partition name matching a `grep`. This
port sets its own bootargs with no such partition, so vendor userspace would
misdetect the product type here.

**There is a second processor.** The AT89S52 is an 8051 running its own
firmware, independent of the Hi3531. In DVRs of this era such a part usually
handles the front panel, IR remote and power sequencing, talking to the main
SoC over a serial line. That fits the vendor runtime probe, where UART1
(SPI 9) had 531 interrupts while UART2 had none — UART1 is the likely link.
Bringing up UART1 would let us watch that conversation.

**The video decoder is an NVP1104B**, a four-channel part matching a
four-channel DVR. The vendor ships `nvp1918.ko` — a different part in the same
family — alongside `tw2865.ko` and `tw2960.ko` from a different vendor
entirely. The rootfs is built for a product line, and only one of those
drivers matches this board. A good illustration of why the vendor filesystem
overstates as well as understates.

## Not identified

`PNS21` (TI, TSSOP-48, near HDMI) is a package marking, and TI marking codes
do not map to part numbers without a lookup table. Given the position, an HDMI
level shifter or ESD companion is plausible, but that is a guess. Note the
vendor ships `sil9024.ko` for a Silicon Image HDMI transmitter, so the HDMI
transmitter itself is a different chip that was not photographed.

The QFN marked `NBDG` and the worn SOIC-8 are likewise unidentified. The
SOIC-8's package suits SPI flash, and U-Boot reports an `S25FL216K` 2 MiB SPI
NOR, but the marking cannot be read to confirm it.

## Later correction

The SD/MMC controller was initially recorded as needing a new driver. It does
not: the vendor's `himciv100` register map is Synopsys DesignWare MMC, byte
for byte identical to mainline's `dw_mmc.h`. Mainline's `snps,dw-mshc` should
drive it once the clock and reset are released.

## Board layout, from the full-board photograph

`pcb/PCB.heic`. The main board is silkscreened `DHB_AX V1.2`; the rear I/O
edge carries a second marking, `DHB_AX_B V1.0`. A date sticker reads
`20130921`, consistent with the 2013 chip date codes.

### Ten SATA positions, two fitted — and it explains the probe exactly

The silkscreen labels ten drive positions in pairs: `SATA1/2`, `SATA3/4`,
`SATA5/6`, `SATA7/8`, `SATA9/10`. **Only SATA3 and SATA4 have connectors
soldered**; the other eight are bare footprints. One drive is cabled, in
SATA3.

Ten positions is two SoC SATA ports each behind a five-port multiplier. Only
one multiplier is fitted, on controller port 1, which is why `ata1` reports
link down with no device.

Mapping PMP port *n* to SATA *n+1* reproduces the probe result exactly:

| PMP port | Silkscreen | Fitted? | libata saw |
|---|---|---|---|
| 2.00 | SATA1 | no connector | link down |
| 2.01 | SATA2 | no connector | link down |
| 2.02 | SATA3 | connector + drive | **link up, WD10EURX** |
| 2.03 | SATA4 | connector, empty | link down |
| 2.04 | SATA5 | no connector | link down |

Every observation matches. This makes the enumeration timing actionable: PMP
ports 0, 1 and 4 have no connector and can never hold a drive, so skipping
them costs nothing:

```text
libata.force=2.00:disable,2.01:disable,2.04:disable
```

That saves roughly 3.2 s of the ~15.7 s enumeration while leaving SATA4
(2.03) live, so a second drive can still be added. The larger cost — 10.6 s
before the multiplier answers at all — is untouched by this and remains
unexplained.

### Other details

- **CON1** is an unpopulated 2x10 header with a square pin-1 pad. The pitch
  and pin count match the ARM 20-pin JTAG standard, which would be a useful
  debug route, but nothing confirms that; it could equally be front-panel or
  expansion.
- **U2** is a NANYA DRAM part, date code 1309.
- **BT1**, a coin cell, sits beside the RTC circuitry — the battery backing
  the DS1307.
- **K1, K3, K4** are Hui Ke relays and **BZ1** a buzzer: alarm outputs, which
  are GPIO territory and now reachable, though which pins drive them is
  unknown.
- The Ethernet magnetics are a `PPT PM6C-1001A 1000BASE-T` module.
- Connectors visible but unexplored: VGA, HDMI, `J48`, `J47`, `CON4` (fan),
  `J21`/`J15` (power), and the ribbon headers at `J1`/`J2`.
