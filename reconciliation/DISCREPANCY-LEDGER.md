# Porting Guide Discrepancy Ledger

This ledger begins with claims, not conclusions. The maintained sources and the
early porting guide are both review inputs. A disposition changes only after
the cited evidence has been independently checked, preferably on the target
hardware under recorded test conditions.

Confidence describes confidence in the current reconciliation conclusion, not
confidence that either document states its own claim accurately.

| ID | Area | Current conclusion | Confidence | Disposition |
|---|---|---|---|---|
| MEM-01 | Physical DRAM topology | Two independent 512 MiB banks | High | Source changed |
| MEM-02 | Kernel virtual split | 2G split maps both banks as low memory | High | Source changed |
| SMP-01 | CPU1 enable method | Dedicated Hi3531 method required | High | Source changed |
| SMP-02 | System-controller fallback | Retain `hisilicon,sysctrl` after the Hi3531 compatible | High | Guide changed |
| CPU-01 | Cortex-A9 errata | Enable 754322, 764369 and 775420 for r3p0 SMP | High | Source changed |
| GPIO-01 | PL061 AMBA identity | All 19 banks have valid native PL061 IDs | High | Guide changed |
| GPIO-02 | GPIO18 width | Six physical lines; upstream ABI exposes eight | High | Source and guide clarified |
| RTC-01 | External RTC identity | DS1307 register compatibility at `0x68` validated | High | Both clarified |
| RTC-02 | On-chip PL031 usability | Needs Hi3531 unlock/reset integration | High | Both changed |
| ETH-01 | DWMAC fallback compatible | Generic fallback plus explicit Hi3531 integration data | High | Both changed |
| SATA-01 | AHCI integration | Hi3531 glue is required for clock, reset and PHY setup | High | Both changed |
| USB-01 | USB integration | Generic host drivers use a shared Hi3531 PHY provider | High | Both changed |

## MEM-01: physical DRAM topology

- Maintained claim: `hi3531-dhb-ax.dtsi` declares one 512 MiB range at
  `0x80000000`. Its comments report wrap at `0xa0000000` and claim addresses at
  `0xc0000000` alias the bottom of DDR0.
- Guide claim: `doc/02-memory-map.md` declares independent 512 MiB banks at
  `0x80000000` and `0xc0000000` and reports a multi-address U-Boot pattern test
  intended to distinguish them.
- Evidence currently recorded: both sides describe empirical pattern tests,
  but their incompatible procedures and observations have not yet been
  reproduced under common conditions. The guide also cites vendor MMZ use of
  DDR1; the maintained source cites a cache-evicting wrap test.
- Required resolution: audit the exact commands and address coverage, then run
  the minimum safe independent-bank test with cache/test conditions recorded.
- Resolution: cache-evicted U-Boot tests reproduced the `0xa8000000` to
  `0x88000000` alias while independently proving that DDR1 does not alias DDR0.
  Distinct patterns 256 MiB apart within each bank and at `0x9f000000` versus
  `0xdf000000` confirm two 512 MiB spans. See `STEP-2-MEMORY.md`.
- Disposition: **Source changed.** The DTS now declares DDR0 and DDR1; its
  comments retain the valid hole-alias result but remove the invalid DDR1
  extrapolation. The guide's topology does not need correction.

## MEM-02: kernel virtual split

- Maintained claim: generated Linux config uses `CONFIG_VMSPLIT_3G=y`,
  `PAGE_OFFSET=0xc0000000`, and no declared DDR1 bank.
- Guide claim: if DDR1 is independent and declared, `CONFIG_VMSPLIT_2G=y` is
  recommended so both discontiguous banks are low memory; a 3G split without
  highmem discards DDR1.
- Evidence currently recorded: the upstream ARM address-window arithmetic is
  internally consistent with the guide, but the change is conditional on
  resolving MEM-01 and must be checked against Linux 6.18.42.
- Required resolution: settle MEM-01, then verify the generated config and
  boot log for the chosen memory model.
- Resolution: Linux 6.18.42 source confirms the 3G split's low-memory ceiling
  falls below DDR1 and would discard it without highmem. The maintained config
  now selects `CONFIG_VMSPLIT_2G=y`, derives `PAGE_OFFSET=0x80000000`, leaves
  highmem off, and continues to disable ATAG/DT compatibility. Both generated
  DTBs contain the two ranges. A TFTP/RAM boot then reported exactly 262,144
  pages, `MemTotal: 1032968 kB`, and both full ranges as System RAM, with no
  `Ignoring RAM` message.
- Disposition: **Source changed.** The guide's virtual-split recommendation is
  correct for the confirmed topology.

## SMP-01: CPU1 enable method

- Maintained claim: `hi3531-dhb-ax.dtsi` uses
  `enable-method = "hisilicon,hi3620-smp"` and says the mainline Hi3620 method
  exactly matches Hi3531 once its optional CPU-control node is absent.
- Guide claim: Hi3531 should have dedicated SMP operations that enable the SCU
  and write `secondary_startup` to `SYS_CTRL + 0x134`; Hi3620-specific power,
  reset, IPI, and hotplug behavior must not be assumed compatible.
- Evidence: Linux 6.18.42's `hi3xxx_boot_secondary()` unconditionally calls
  `hi3xxx_set_cpu()`. That helper finds the generic `hisilicon,sysctrl` node
  present in this DTS and performs Hi3620-specific writes at offsets `0xf4`,
  `0x410`/`0x414`, and `0x200`; the method also sends a wakeup IPI and installs
  Hi3620 hotplug callbacks. The maintained claim that those operations no-op
  without a separate CPU-control node was therefore false.
- Resolution: patch 0010 adds `hisilicon,hi3531-smp`. It enables the SCU and
  writes only `__pa_symbol(secondary_startup)` to `SYS_CTRL + 0x134`; it has no
  reset, power, IPI, or hotplug operations. A TFTP/RAM boot brought CPU1 online.
  Pre/post reads showed offsets `0xf4`, `0x410`, `0x414`, and `0x200` remained
  zero while the jump word changed from zero to `0x80013000`. Two simultaneous
  256 MiB SHA-256 streams completed successfully with equal busy-tick deltas on
  CPU0 and CPU1 and no SMP, RCU, watchdog, lockup, Oops, or panic diagnostics.
  See `STEP-3-SMP.md`.
- Disposition: **Source changed.** The guide's dedicated-method conclusion is
  confirmed and does not need correction for this item.

## SMP-02: system-controller fallback

- Maintained claim: the system-controller node uses
  `"hisilicon,hi3531-sysctrl", "hisilicon,sysctrl"`. The first string lets the
  Hi3531 SMP code locate the block; the second binds Linux's existing HiSilicon
  reboot driver.
- Guide claim: the corresponding DTS example in `doc/01-soc-overview.md` used
  `"hisilicon,hi3531-sysctrl", "syscon"`.
- Resolution: Linux 6.18.42's `hisi-reboot` driver matches
  `hisilicon,sysctrl`, not `syscon`. The maintained fallback passes the new
  schema and the tested kernel repeatedly rebooted through U-Boot. The generic
  `syscon` fallback would omit that reboot integration.
- Disposition: **Guide changed.** The maintained compatible sequence was
  already correct; the guide example now includes `hisilicon,sysctrl`.

## CPU-01: Cortex-A9 errata

- Maintained claim: `ARM_ERRATA_764369=y`; 754322 and 775420 are disabled.
- Guide claim: the target is Cortex-A9 r3p0, so 754322, 764369, and 775420 apply
  to the SMP kernel.
- Evidence currently recorded: the guide reports r3p0 and describes upstream
  workaround scopes. The current generated configuration confirms the source
  settings but does not establish the silicon revision.
- Required resolution: verify MIDR/CPU revision evidence, then confirm the
  Linux 6.18.42 Kconfig scopes and final `olddefconfig` result.
- Resolution: both CPUs report implementer `0x41`, part `0xc09`, variant
  `0x3`, revision `0`, encoding Cortex-A9 r3p0. Linux 6.18.42 scopes 754322 to
  r2p*/r3p*, 764369 to all SMP Cortex-A9 revisions, and 775420 explicitly to
  r3p0. The maintained config now enables all three; Buildroot preserved them
  in the generated configuration, and the RAM-booted kernel passed concurrent
  cache and process-churn workloads with both CPUs online. See
  `STEP-4-ERRATA.md`.
- Disposition: **Source changed.** The guide's r3p0 erratum selection is
  confirmed.

## GPIO-01: PL061 AMBA identity

- Maintained claim: comments in `hi3531-dhb-ax-ethernet.dts` say GPIO0's
  PrimeCell ID registers identify part `0x061`; all 19 banks rely on hardware
  discovery and omit `arm,primecell-periphid`.
- Guide claim: the banks implement the PL061 register layout but their ID
  registers are invalid/unimplemented, so every node needs
  `arm,primecell-periphid = <0x00041061>`.
- Evidence currently recorded: the guide publishes a GPIO0 ID-register dump
  incompatible with a PL061 ID. The maintained comment cites a contrary read
  without preserving its raw values or clock/kernel context in maintained
  source.
- Required resolution: locate existing raw logs if available, otherwise repeat
  individual ID reads with kernel and clock state recorded; avoid serial
  multi-register loops.
- Resolution: on the RAM-booted Linux 6.18.42 build, all nineteen AMBA devices
  bound as `pl061_gpio` with `AMBA_ID=00041061`, despite the live DT containing
  no `arm,primecell-periphid` properties. Individual 32-bit reads on GPIO0,
  GPIO12 and GPIO18 returned PID bytes `61 10 04 00` and CID bytes
  `0d f0 05 b1`. See `STEP-5-GPIO.md`.
- Disposition: **Guide changed.** Native identity is repeatable on this target;
  the maintained source correctly omits the override. Its comment now records
  the all-bank result rather than only GPIO0.

## GPIO-02: GPIO18 width

- Maintained claim: GPIO18 is described like every other PL061 bank and thus
  exposes the driver's normal eight offsets.
- Guide claim: GPIO18 implements only six pins.
- Evidence currently recorded: this is not necessarily a probe blocker, but
  the source currently has no `ngpios` constraint or driver quirk.
- Required resolution: check binding/driver support for a six-line PL061 bank
  and verify which offsets are physically implemented before exposing them to
  consumers.
- Resolution: the datasheet establishes that GPIO18 implements offsets 0..5.
  Linux 6.18.42's PL061 driver sets `gc.ngpio` to its hard-coded value of eight,
  and the binding has no `ngpios` property. A runtime chip-info ioctl therefore
  reported eight lines for GPIO18, as expected. No maintained consumer refers
  to offsets 6 or 7.
- Disposition: **Source and guide clarified.** The DTS documents that offsets 6
  and 7 are invalid even though gpiolib exposes them. No non-binding property or
  target-specific driver quirk was added; the guide now warns about the ABI
  mismatch.

## RTC-01: external RTC identity

- Maintained claim: GPIO12 pins 4 and 5 form the bit-banged bus and the device
  at address `0x68` is described as `dallas,ds1307`.
- Guide claim: the vendor uses a DS1307-family device through GPIO I2C, but the
  exact board part/address compatibility remains to be tried; its pinmux-map
  example labels address `0x68` unverified.
- Evidence currently recorded: vendor module naming and bus idle state support
  the family hypothesis, but neither source records a chip marking or validated
  register-level identification.
- Required resolution: enumerate only after GPIO12 works, then identify the
  part without writing time or control registers.
- Resolution: the vendor module defaults to its DS1307 mode, using I2C address
  byte base `0xd0` (7-bit `0x68`) and registers 0..7; its distinct
  PCF8563-style mode uses `0x51` and registers 2..8. Mainline `rtc-ds1307`
  successfully reads the target at `0x68`, advances exactly five seconds over
  a five-second observation, registers it as `rtc0`, and supplies hctosys. The
  exact package manufacturer remains unidentified, but its required software
  compatibility is established. See `STEP-6-RTC.md`.
- Disposition: **Both clarified.** The maintained DTS keeps
  `dallas,ds1307` and now describes it as a validated compatibility rather than
  an exact part identification. The guide's untested qualification was updated.

## RTC-02: on-chip PL031 usability

- Maintained claim: no PL031 node; comments report that the driver bound but the
  counter did not advance and writable registers rejected writes, consistent
  with a clock-gated block. The vendor loads the external RTC driver instead.
- Guide claim: valid PL031 peripheral IDs identify the block at `0x20060000`,
  and parts of the guide describe a node as sufficient for a working RTC.
- Evidence currently recorded: valid identity proves the IP block but not its
  clock/reset state. The maintained runtime claim and the guide's bring-up
  claim can both be partly true under different clock conditions.
- Required resolution: reproduce the read-only counter behavior and establish
  clock/reset control before deciding whether to change the DTS, driver glue,
  or guide wording.
- Resolution: the reset control is `CRG + 0xe4` bit 2 and was already
  deasserted. Hi3531 adds `RTC_LOCK` at offset `0x20`; the SDK and datasheet
  require writing `0x1acce551` before `RTC_CR` or `RTC_LR`, but mainline
  `rtc-pl031` has no unlock operation. The stopped counter and rejected control
  write were therefore reproduced, but the maintained clock-gating diagnosis
  was false. A volatile unlock followed by `RTC_CR = 1` started exact one-Hz
  counting without loading a time or alarm. See `STEP-6-RTC.md`.
- Disposition: **Both changed.** The maintained source retains no PL031 node
  and the external RTC remains `rtc0`, but its comment now records the actual
  integration requirement. The guide no longer claims that a plain node works;
  a dedicated compatible/driver quirk remains optional future work.

## ETH-01: DWMAC fallback compatible

- Maintained claim: the node uses `hisilicon,hi3531-dwmac` followed by
  `snps,dwmac-3.40a`. The Hi3531 glue explicitly disables TX checksum insertion
  despite the fallback's default because the feature register is unusable.
- Guide claim: the measured core version is 3.60, for which upstream has no
  exact compatible; use generic `snps,dwmac` and put verified integration
  behavior in the Hi3531 glue.
- Evidence currently recorded: both sides agree that `snps,dwmac-3.60a` is not
  an upstream binding value. The maintained source intentionally chose 3.40a
  for behavior rather than identity, but the entire inherited quirk set has not
  yet been enumerated or justified.
- Required resolution: compare the Linux 6.18.42 match data and schema, list
  each behavior selected by 3.40a, and test whether generic fallback plus
  explicit Hi3531 glue preserves only verified behavior.
- Resolution: Linux 6.18.42's `snps,dwmac-3.40a` match data selects enhanced
  descriptors, TX checksum insertion, the jumbo-frame quirk and PMT support.
  The node now uses generic `snps,dwmac`; the Hi3531 glue explicitly retains
  enhanced descriptors while disabling TX/RX checksum offload, jumbo frames,
  PMT/WOL and forced TX store-and-forward. The maximum MTU is 1500. The glue's
  existing GMAC1, DMA1, shared-MDIO, all-channel reset and TNK interrupt
  handling remains required and was retained. See `STEP-7-ETHERNET.md`.
- Disposition: **Both changed.** The maintained source adopted the guide's
  generic Synopsys fallback and made the validated capability set explicit.
  The guide was corrected because its proposed speed-only glue and instruction
  to ignore TNK did not describe the verified shared-block integration.

## SATA-01: AHCI integration

- Maintained claim: the node uses only `hisilicon,hi3531-ahci`, supplies AHCI
  and shared-CRG register windows, and binds a local glue driver that enables
  clocks, sequences resets, configures both PHYs and applies the vendor port
  workarounds before handing the controller to libahci.
- Guide claim: `doc/07-sata-storage.md` described generic `ahci_platform` as
  requiring no new driver and showed
  `"hisilicon,hi3531-ahci", "generic-ahci"`, while separately warning that PHY
  and clock initialization would probably need extracting.
- Resolution: with clocks off the generic register window reads as zero. The
  local glue's vendor-derived initialization made the controller enumerate as
  AHCI 1.2 with two ports, a five-port JMicron multiplier and the attached 1 TB
  disk; a read completed successfully. The generic fallback cannot perform
  that initialization and is not part of the validated binding contract.
- Disposition: **Both changed.** The maintained runtime behavior was retained,
  while its comment and new binding now state the validated contract. The
  guide now describes the required glue and the tested result instead of a
  generic-only expectation.

## USB-01: USB integration

- Maintained claim: the EHCI and OHCI nodes use the standard `generic-ehci`
  and `generic-ohci` compatibles. Both reference a shared
  `hisilicon,hi3531-usb-phy` provider that owns the Hi3531 clock, reset and PHY
  interface sequence.
- Guide claim: `doc/08-usb.md` sketched unimplemented
  `hisilicon,hi3531-ehci` and `hisilicon,hi3531-ohci` wrapper compatibles and
  left the PHY integration unresolved.
- Resolution: the generic host drivers and the shared PHY provider bound
  together. Both two-port root hubs enumerated, and a front-panel high-speed
  USB storage device completed 512 MiB of dispersed destructive write/readback
  validation without a reset, transport or I/O error. No Hi3531-specific host
  compatible or host glue is needed.
- Disposition: **Both changed.** The maintained host topology was retained and
  its PHY binding was added; the guide now uses the generic host compatibles,
  documents the shared PHY provider and records the hardware result.

## Remaining contradictions

None. Every guide/source conflict found in the maintained bring-up scope has a
recorded disposition above. The following are intentional limitations rather
than contradictory claims:

- GPIO18 offsets 6 and 7 remain visible through the upstream PL061 eight-line
  ABI but are physically absent and have no consumers.
- The on-chip PL031 remains disabled until a dedicated Hi3531 unlock quirk is
  implemented; the validated external DS1307-compatible device is `rtc0`.
- CPU hotplug remains unsupported because no safe path back to the vendor poll
  loop or an independently validated WFI/wakeup sequence exists.
- The hard-NFS-root validation boot was not deliberately subjected to a link
  drop; Step 7 separately validated link transitions with the same Ethernet
  implementation.
- Media capture, codecs, scaling and display remain outside this port's stated
  scope.

## Disposition vocabulary

- **Source changed:** guide claim is better supported for this target.
- **Guide changed:** maintained behavior is supported by stronger repeatable
  evidence and contradicts the early guide.
- **Both changed:** each side contains an overstatement or incomplete model.
- **Neither changed:** the apparent conflict is contextual or remains
  insufficiently evidenced.
