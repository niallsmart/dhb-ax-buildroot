# Step 6: RTC Support

Completed on 2026-08-14.

## Conclusion

The battery-backed device at I2C address `0x68` is validated as
DS1307-register-compatible and remains the correct `rtc0`. Its exact package
manufacturer is still unknown, but both the preserved vendor driver and the
running mainline driver establish the compatibility required by the DTS.

The on-chip block is a real PL031 and its one-Hz counter works. A plain
mainline node does not work, however, because Hi3531 adds a write lock that the
generic `rtc-pl031` driver does not unlock. The earlier maintained-source claim
that the block was clock-gated was wrong, while the guide's claim that a node
alone is sufficient was also wrong. Both were corrected.

No external RTC time/control register, persistent storage, flash or disk was
written during this step.

## External RTC compatibility

GPIO12 registered before `i2c-gpio`, and the device appeared as `0-0068`.
Inspection of the preserved vendor `ds1307.ko` established two modes:

- default `g_chip_type = 0`: address byte base `0xd0`, or 7-bit `0x68`,
  with the DS1307 time registers at offsets 0..6;
- alternate PCF8563-style mode: address `0x51`, with time registers at
  offsets 2..8.

The board's normal module load does not override the default. This is stronger
evidence than the module's ambiguous `2408 rtc` banner: the configured protocol
is explicitly the DS1307 mode.

On the RAM-booted Linux 6.18.42 image, mainline `rtc-ds1307` read the device,
registered it as `rtc0`, and performed hctosys:

```text
[    1.202919] rtc-ds1307 0-0068: registered as rtc0
[    1.210269] rtc-ds1307 0-0068: setting system clock to 2026-08-14T12:41:32 UTC
```

Two read-only `since_epoch` samples five seconds apart differed by exactly five
seconds, and the second matched the system UTC second. The observed sysfs
identity was:

```text
rtc-ds1307 0-0068
```

This validates `compatible = "dallas,ds1307"` as a hardware-interface
compatibility. It does not claim the unidentified package was manufactured by
Dallas/Maxim.

## On-chip PL031 integration

The official Hi3531 SDK and datasheet identify:

- PL031 register base `0x20060000`;
- reset control at `CRG + 0xe4` bit 2, where zero deasserts reset;
- Hi3531 `RTC_LOCK` at `RTC + 0x20`;
- unlock value `0x1acce551`; and
- a one-Hz count clock.

The SDK's `hi_rtc.c` explicitly deasserts the reset, writes the unlock value,
and then writes `RTC_CR = 1`. Linux 6.18.42's generic `rtc-pl031.c` writes
`RTC_CR` directly and has no knowledge of `RTC_LOCK`.

Runtime state before the controlled test was:

```text
CRG + 0xe4 = 0x0000c060  (bit 2 clear: reset deasserted)
RTC_DR      = 0x00000000
RTC_CR      = 0x00000000
RTC_LOCK    = 0x00000001
```

`RTC_DR` remained zero over three seconds. A volatile write of the documented
unlock value followed by `RTC_CR = 1` made the control bit stick and exposed
the running count. A subsequent ten-second observation advanced from
`0x0000073b` to `0x00000745`, exactly ten ticks. No load, match, interrupt, or
wall-clock value was written.

## Maintained-source decision

Keep the external device as `rtc0`, retain `CONFIG_RTC_DRV_DS1307=y` and
`CONFIG_RTC_HCTOSYS_DEVICE="rtc0"`, and leave `CONFIG_RTC_DRV_PL031` disabled.
The on-chip RTC has no battery and offers no advantage over the working
external device. If it is wanted later, add a dedicated Hi3531 compatible and
a reviewed driver quirk that performs the unlock and reset sequence; a plain
`arm,pl031` node is incomplete.

## Disposition

- `RTC-01`: **Both clarified**, high confidence.
- `RTC-02`: **Both changed**, high confidence; maintained functional behavior
  remains unchanged.
