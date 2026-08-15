# Remaining hardware work

Peripherals this port does not yet drive, in descending order of value and then
ascending effort. Items that are working — SMP, USB, the RTC, Ethernet, SATA,
GPIO and the bit-banged I²C bus — are listed in `README.md` and are not repeated
here.

The value and effort columns come from the hardware guide's assessment of the
board. The status column is this repository's.

| Item | Value | Effort | Status and notes |
|---|---|---|---|
| Front panel, buzzer, alarm relays | High | Low–medium | Nothing here drives them. All sit behind the AT89S52 on `ttyAMA1`; the protocol is recovered and verified on the wire, so this is userspace serial work with no kernel driver needed. [Protocol][mcu] |
| Unattended boot | High | Medium | Automatic boot is deliberately deferred; the kernel is booted by hand over the serial console. This U-Boot cannot read SATA, so closing the gap means either writing flash or leaving USB media attached. [Why][sata] |
| Watchdog | High | Medium | `watchdog@20040000` is in the device tree and `sp805-wdt` binds and counts at the measured 3 MHz rate. The first expiry raises the raw interrupt; the second does not reset the SoC. The missing piece is Hi3531 reset routing outside the watchdog block. [Detail][wdt] |
| L2 cache | Medium | Medium | `CONFIG_CACHE_L2X0=y` is set but no L2 node exists, so nothing binds. The block is a HiSilicon L2 Cache V200 with no mainline driver; the vendor `cache-hil2v200.c` would need forward-porting. Performance only — the board boots without it. [Detail][soc] |
| Hardware SPI | Low | Low | An ARM PL022 at `0x200C0000`, IRQ 44. `spi-pl022` binds with no override. The board bit-bangs instead, so the pins need muxing to function 1 first. [Detail][soc] |
| Spare timers | Low | Low | Four SP804 blocks, not two. Timers 1–3 at `0x20010000`, `0x20130000` and `0x20140000` are unused: six spare 32-bit timers. [Detail][soc] |
| Inherited firmware framebuffer | Low | Low | U-Boot leaves one 480x300 ARGB1555 buffer mirrored to its main HD path and both CVBS outputs. Reserving it and using `simple-framebuffer` would give a fixed diagnostic display. [Handoff][vou] |
| SD/MMC | Low | Medium | `dw_mmc` may fit, and the socket may not exist. The pins are function 4 of the `VIU3` run, so enabling it excludes the fourth video input. [Detail][soc] |
| DMA | Low | Medium | An ARM PL080 at `0x100D0000`. Its periphid collides with mainline's Samsung PL080S entry — read the warning before enabling. [Detail][soc] |
| Audio | Low | High | Needs an ASoC platform driver written from scratch. [Detail][audio] |
| Native video output | Low | Very high | VDP is documented, so a VGA DRM/KMS driver is possible. The on-chip HDMI transmitter and TDE/VPSS are not documented. 800x600 is the vendor Linux mode rather than a hardware limit. [Detail][vou] |
| Video capture | Low | Impractical | VICAP is fully documented; the analogue decoder and the FPGA feeding it are not. [Detail][viu] |
| H.264 codec | Low | Impossible | [Why][codec] |

[mcu]: https://github.com/niallsmart/dhb-ax-guide/blob/main/doc/20-front-panel-mcu.md
[sata]: https://github.com/niallsmart/dhb-ax-guide/blob/main/doc/07-sata-storage.md#u-boot-cannot-read-the-sata-disk
[wdt]: https://github.com/niallsmart/dhb-ax-guide/blob/main/doc/10-rtc-watchdog-misc.md
[soc]: https://github.com/niallsmart/dhb-ax-guide/blob/main/doc/01-soc-overview.md
[vou]: https://github.com/niallsmart/dhb-ax-guide/blob/main/doc/12-video-output.md
[viu]: https://github.com/niallsmart/dhb-ax-guide/blob/main/doc/11-video-input.md
[audio]: https://github.com/niallsmart/dhb-ax-guide/blob/main/doc/13-audio.md
[codec]: https://github.com/niallsmart/dhb-ax-guide/blob/main/doc/14-media-codec.md
