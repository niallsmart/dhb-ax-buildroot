# Porting Guide Reconciliation Plan

## Purpose and scope

Reconcile the maintained port sources, primarily under `br2-external/`, with
the official Hi3531 porting guide at:

```text
/Users/niallsmart/workspace/hi3531-porting-guide
```

The porting guide is an early release and is a review input, not an unquestioned
authority. Existing material under this repository's `docs/` directory remains
excluded as technical evidence. Reconcile each difference from the strongest
available evidence rather than automatically changing the maintained port to
match the guide.

Use this evidence order while investigating a discrepancy:

1. Repeatable measurements on the target hardware, with the running kernel and
   test conditions recorded.
2. The Hi3531 datasheet and other authoritative chip documentation.
3. Board-specific behavior established from the vendor firmware, binaries,
   configuration, PCB, or flash captures.
4. Relevant HiSilicon SDK source, accounting for differences between its demo
   board and this target board.
5. Current upstream Linux implementation and binding requirements.
6. Maintained port source comments and the early porting guide, each treated as
   claims whose supporting evidence must be checked.

Evidence can move a conclusion in either direction. If the guide has the
better-supported conclusion, update the maintained port. If a specific,
repeatable finding from the maintained work or target hardware contradicts the
guide, preserve the correct port behavior and update the guide instead. Record
uncertain conflicts as open questions without rewriting either side as fact.

This work must preserve the repository's operational safeguards: boot test
kernels from RAM, do not write SPI-NOR or NAND, and keep the attached SATA disk
read-only.

## Plan

### 1. Capture a clean baseline

- [x] Inventory existing unrelated worktree changes and preserve them.
- [x] Build the current `br2-external` configuration without modifying its source.
- [x] Record the resulting kernel configuration, DTBs, image names, compiler
  diagnostics, and relevant artifact checksums for later comparison.
- [x] Confirm that the current patch queue applies with zero fuzz.
- [x] Create a discrepancy ledger that records the maintained-source claim, guide
  claim, evidence supporting each, confidence, and eventual disposition.

Baseline records: [`reconciliation/STEP-1-BASELINE.md`](reconciliation/STEP-1-BASELINE.md)
and [`reconciliation/DISCREPANCY-LEDGER.md`](reconciliation/DISCREPANCY-LEDGER.md).

### 2. Reconcile the DRAM description and kernel virtual split

- [x] Reproduce or validate the guide's independent-bank test before changing the
  maintained memory description; explicitly resolve the source's contrary
  aliasing claim.
- [x] If the independent 512 MiB DDR1 result is confirmed, add its range at
  `0xc0000000` to the maintained DTS. If it is disproved, correct the guide and
  retain the hardware-supported source description.
- [x] Retain the 512 MiB DDR0 range at `0x80000000`.
- [x] If DDR1 is confirmed independent, remove maintained-source comments claiming
  that it aliases DDR0 and select `CONFIG_VMSPLIT_2G=y` so both banks are low
  memory.
- [x] Keep `CONFIG_ARM_ATAG_DTB_COMPAT` disabled so U-Boot's incomplete ATAG memory
  description cannot overwrite the DT memory ranges.
- [x] Verify the resulting DTB contains both ranges before booting it.

Evidence and build record:
[`reconciliation/STEP-2-MEMORY.md`](reconciliation/STEP-2-MEMORY.md).

### 3. Reconcile Hi3531 SMP operations

- [x] Verify the actual writes and observable effects of the current Hi3620 method
  against the pinned upstream implementation and safe runtime evidence before
  replacing it.
- [x] The guide's incompatibility finding was confirmed; replace
  `enable-method = "hisilicon,hi3620-smp"` with a Hi3531-specific method that:
  - enables the Cortex-A9 SCU during SMP preparation;
  - releases CPU1 only by writing `__pa_symbol(secondary_startup)` to
    `SYS_CTRL + 0x134` from the secondary-boot operation;
  - performs no Hi3620 power, reset, or wakeup-IPI sequence; and
  - provides no CPU-hotplug callbacks until a correct Hi3531 hotplug sequence
    exists.
- [x] Keep CPU1 out of the first validation boot if necessary, then enable it only
  after the memory-only baseline succeeds.

Evidence and build/boot record:
[`reconciliation/STEP-3-SMP.md`](reconciliation/STEP-3-SMP.md).

### 4. Reconcile Cortex-A9 erratum workarounds

- [x] Confirm the CPU variant and revision from a current boot or direct CPU ID
  evidence.
- [x] Retain `CONFIG_ARM_ERRATA_764369=y`.
- [x] Cortex-A9 r3p0 was confirmed; enable `CONFIG_ARM_ERRATA_754322=y` and
  `CONFIG_ARM_ERRATA_775420=y` as required by the upstream workaround scopes.
- [x] Confirm that `olddefconfig` preserves all three settings in the final kernel
  configuration.

Evidence and build/boot record:
[`reconciliation/STEP-4-ERRATA.md`](reconciliation/STEP-4-ERRATA.md).

### 5. Reconcile GPIO enumeration

- [x] Reconcile the guide's invalid-AMBA-ID measurements with the maintained
  source's claim that GPIO0 identified as PL061 and with any existing probe
  logs.
- [x] If the hardware IDs are absent or invalid, add
  `arm,primecell-periphid = <0x00041061>` to all nineteen PL061-compatible GPIO
  nodes. If valid IDs are repeatably observed, retain normal enumeration and
  correct the guide.
- [x] Retain the deliberate no-parent-IRQ behavior for GPIO users that only need
  output or polled input.
- [x] Check whether the mainline PL061/gpiolib interfaces can represent GPIO18's
  six implemented pins. If not, document the two invalid offsets and avoid
  exposing them to consumers until a driver quirk is justified.
- [x] Verify that GPIO12 binds before testing its I2C consumers.

Evidence and source/guide disposition:
[`reconciliation/STEP-5-GPIO.md`](reconciliation/STEP-5-GPIO.md).

### 6. Reconcile RTC support

- [x] Bring up `i2c-gpio` only after GPIO12 enumerates reliably.
- [x] Validate the external RTC's identity or confirmed register compatibility
  before treating `dallas,ds1307` as final.
- [x] Investigate the on-chip PL031 clock/reset state to reconcile the guide's
  expected support with the maintained source's observation that the block was
  clock-gated and non-functional.
- [x] If the maintained runtime observation is reproduced, update the guide's claim
  that a PL031 node alone produces a working RTC. If the guide is confirmed,
  correct the maintained DTS and kernel configuration.
- [x] Select the validated RTC as `rtc0` and verify the intended `hctosys`
  behavior. Do not set persistent time until the owner explicitly authorizes
  that write.

Evidence and source/guide disposition:
[`reconciliation/STEP-6-RTC.md`](reconciliation/STEP-6-RTC.md).

### 7. Reconcile Ethernet binding metadata

- [x] Establish which behavior the current `snps,dwmac-3.40a` fallback intentionally
  selects and which of those quirks are proven on the 3.60 core.
- [x] Replace the 3.40a identity with a generic `snps,dwmac` fallback if the guide's
  binding recommendation preserves the required behavior; otherwise encode the
  verified behavior explicitly in the Hi3531 glue and update the guide with the
  reason the generic sketch is insufficient.
- [x] Move only independently confirmed capabilities and integration quirks into
  the Hi3531 glue driver, including enhanced descriptors if still required.
- [x] Retain the source-backed shared-block implementation: GMAC1, DMA channel 1,
  TNK interrupt masking, PHY address 1, plain RGMII mode, the board MAC address,
  and the upper 16-bit `CRG + 0xec` speed field.
- [x] Confirm that removing the 3.40a compatible does not accidentally re-enable
  unsupported checksum, jumbo-frame, PMT, or store-and-forward behavior.

Evidence and build/boot record:
[`reconciliation/STEP-7-ETHERNET.md`](reconciliation/STEP-7-ETHERNET.md).

### 8. Run static and clean-build validation

- [x] Regenerate the full kernel configuration with the pinned Linux version.
- [x] Compile both maintained DTBs and appended-DTB uImages from a clean Buildroot
  output.
- [x] Run applicable device-tree schema checks, or document any unavailable local
  schema tooling and perform an equivalent binding review.
- [x] Decompile and inspect the produced DTBs for memory ranges, CPU enable method,
  GPIO peripheral IDs, compatible strings, interrupts, clocks, and PHY links.
- [x] Verify that the complete patch queue applies with zero fuzz and introduces no
  compiler warnings.

Evidence and build record:
[`reconciliation/STEP-8-STATIC-VALIDATION.md`](reconciliation/STEP-8-STATIC-VALIDATION.md).

### 9. Perform staged read-only hardware validation

Load the kernel and appended DTB into RAM over TFTP. The test system may mount
its root filesystem over NFS from the Raspberry Pi when bundling a rootfs would
exceed the vendor U-Boot/kernel image-size limits. NFS root is an approved
validation path and does not change the prohibition on writing board flash or
the attached SATA disk.

Validate in this order:

- [x] Boot CPU0 with the reconciled memory description.
- [x] Confirm the validated DRAM topology is present; if it contains DDR1, verify
  that the selected split does not report `Ignoring RAM`.
- [x] Enable CPU1 with the validated SMP implementation and verify stable SMP
  operation and warm reboot behavior.
- [x] Verify all expected GPIO banks, then GPIO12-backed I2C and the selected RTC.
- [x] Exercise Ethernet traffic and link transitions at the available negotiated
  speeds without changing unrelated board state.
- [x] Confirm SATA controller, port multiplier, partitions, and disk identity
  while keeping every filesystem unmounted or mounted read-only.
- [x] Verify EHCI/OHCI enumeration and USB PHY reference handling.
- [x] Validate SP805 timing using temporary watchdog operation only when a safe
  recovery path is ready.

Record the running kernel version before interpreting every runtime result.

### 10. Finalize maintained sources and handoff evidence

- [x] Update DTS comments, kernel configuration, and patch commit messages to state
  only validated conclusions.
- [x] Add YAML bindings for the remaining local Hi3531 compatibles and run
  `dtbs_check`, or explicitly record any binding work that remains deferred.
- [x] Update the porting guide wherever repeatable hardware findings, authoritative
  documentation, or validated port behavior disprove an early guide claim.
- [x] Keep this repository's `docs/` material excluded from the technical evidence
  chain for this reconciliation.
- [x] Record remaining guide/source contradictions separately, with the exact
  source, guide section, and runtime or build evidence for each.
- [x] For every resolved discrepancy, record whether the maintained source changed,
  the guide changed, both changed, or neither changed because the apparent
  conflict was contextual.
- [x] Produce a final comparison of baseline and reconciled behavior, including
  memory size, CPU count, peripheral probe status, and any deliberately deferred
  features.

Final record: [`reconciliation/STEP-10-FINALIZATION.md`](reconciliation/STEP-10-FINALIZATION.md).

## Initial discrepancy checklist

- [x] Discrepancy ledger created with evidence and confidence for every item
- [x] DDR0/DDR1 topology resolved and represented according to the evidence
- [x] Kernel virtual split matches the validated memory topology
- [x] SMP-method discrepancy resolved from upstream and hardware evidence
- [x] CPU release and hotplug behavior matches the validated Hi3531 sequence
- [x] Erratum selection matches the confirmed CPU variant and revision
- [x] PL061 identification and enumeration reconciled with hardware evidence
- [x] External RTC compatibility validated
- [x] PL031 clock/reset discrepancy resolved
- [x] DWMAC compatible and quirk selection reconciled with verified behavior
- [x] Clean build and DT inspection complete
- [x] Staged read-only hardware validation complete
- [x] Confirmed contradictions corrected in the porting guide
