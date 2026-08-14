# Step 5: GPIO Enumeration

Completed on 2026-08-14.

## Conclusion

All nineteen GPIO banks have valid native ARM PL061 PrimeCell identities. The
maintained DTS correctly relies on AMBA discovery and must not add
`arm,primecell-periphid`. The early guide's contrary identity reads were not
reproduced and its required-override advice was corrected.

GPIO18 physically implements six lines, but Linux 6.18.42's PL061 driver and
binding cannot describe that width: the driver always registers eight lines.
The two invalid offsets remain visible through gpiolib, are documented in the
DTS, and have no maintained consumers.

## Test context

The target was RAM-booted with the maintained Linux 6.18.42 Step 4 image and
NFS root:

```text
Linux dhb-ax 6.18.42 #4 SMP Fri Aug 14 12:11:21 UTC 2026 armv7l GNU/Linux
```

The live DT contains no `arm,primecell-periphid` properties.

## Native AMBA identity

Every device from `20150000.gpio` through `20270000.gpio` bound to
`pl061_gpio`, and every AMBA uevent reported:

```text
AMBA_ID=00041061
```

Individual 32-bit `devmem` reads, performed over SSH rather than an interleaved
serial loop, gave the same result on representative first, consumer and last
banks:

| Bank | PID0..PID3 at `+0xfe0..+0xfec` | CID0..CID3 at `+0xff0..+0xffc` |
|---|---|---|
| GPIO0 | `61 10 04 00` | `0d f0 05 b1` |
| GPIO12 | `61 10 04 00` | `0d f0 05 b1` |
| GPIO18 | `61 10 04 00` | `0d f0 05 b1` |

The PID encodes peripheral ID `0x00041061`; the CID is the standard PrimeCell
signature. Because AMBA only derives that ID from hardware when the DT does not
supply an override, the successful all-bank result independently confirms the
direct reads.

## Interrupt policy

The maintained nodes intentionally omit parent interrupts. The kernel logged
`IRQ support disabled` followed by successful registration for each bank. This
preserves GPIO output and polled-input use without pretending that upstream's
chained PL061 handler can safely share the paired parent lines above GPIO6.

## GPIO18 width

The Hi3531 datasheet states that GPIO18 has offsets 0..5, for 150 physical GPIOs
in total. Linux 6.18.42 defines `PL061_GPIO_NR` as eight and assigns it directly
to `gc.ngpio`; its PL061 binding does not permit a width property. A read-only
`GPIO_GET_CHIPINFO_IOCTL` probe confirmed the resulting runtime ABI:

```text
/dev/gpiochip18 label=20270000.gpio lines=8
```

Adding `ngpios = <6>` would therefore be both unsupported by the binding and
ignored by the driver. The DTS now warns that offsets 6 and 7 must not be used.
No node in the maintained DTS references GPIO18.

## GPIO12 dependency

Boot ordering and sysfs confirmed that GPIO12 registered before its consumers:

```text
[    0.710628] pl061_gpio 20210000.gpio: IRQ support disabled
[    0.721982] pl061_gpio 20210000.gpio: PL061 GPIO chip registered
[    1.202919] rtc-ds1307 0-0068: registered as rtc0
[    1.223615] i2c-gpio soc:i2c-gpio: using lines 612 (SDA) and 613 (SCL)
```

`/sys/bus/i2c/devices/0-0068` and `/sys/class/rtc/rtc0` were present. This step
uses that only to establish the GPIO dependency; external RTC identity and
on-chip PL031 behavior remain Step 6 work.

## Disposition

- `GPIO-01`: **Guide changed**, high confidence.
- `GPIO-02`: **Source and guide clarified**, high confidence; no functional
  kernel change.
