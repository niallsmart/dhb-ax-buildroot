# Step 4: Cortex-A9 Erratum Workarounds

Completed on 2026-08-14.

## Conclusion

Both CPUs are Cortex-A9 r3p0. The guide's erratum conclusion is correct for
Linux 6.18.42: retain erratum 764369 and enable the previously missing 754322
and 775420 workarounds. The maintained kernel configuration changed; the guide
does not need a correction for this discrepancy.

## Runtime identity evidence

The board was running the maintained Linux 6.18.42 SMP kernel from the NFS
root. Both `/proc/cpuinfo` entries reported:

```text
CPU implementer : 0x41
CPU architecture: 7
CPU variant     : 0x3
CPU part        : 0xc09
CPU revision    : 0
```

These fields encode MIDR `0x413fc090`: ARM implementer, Cortex-A9, variant 3,
revision 0, or r3p0. CPU0 and CPU1 reported the same identity and were both
online.

## Linux 6.18.42 scope audit

The pinned upstream `arch/arm/Kconfig` states:

- `ARM_ERRATA_754322` applies to Cortex-A9 r2p* and r3p*. Its workaround adds
  barriers around the ASID switch in `arch/arm/mm/proc-v7-2level.S`.
- `ARM_ERRATA_764369` applies to SMP Cortex-A9 of all current revisions. Its
  workaround adds barriers to the relevant cache-maintenance paths.
- `ARM_ERRATA_775420` explicitly includes Cortex-A9 r3p0. Its workaround adds
  a DSB to the abort path for cache maintenance that may fault.

All dependencies are satisfied by the maintained `CPU_V7=y` and `SMP=y`
configuration. Workarounds for errata described as fixed before r3p0 were not
enabled as part of this step.

## Source and build validation

`br2-external/board/dhb_ax/linux.config` now contains:

```text
CONFIG_ARM_ERRATA_754322=y
CONFIG_ARM_ERRATA_764369=y
CONFIG_ARM_ERRATA_775420=y
```

Buildroot reapplied the maintained defconfig, regenerated the Linux
configuration, and preserved all three settings. The incremental kernel build
completed without a new source warning. The relevant artifacts were:

| Artifact | SHA-256 |
|---|---|
| `hi3531-dhb-ax-ethernet.dtb` | `053dbff2b574ef33af8704c943daf3e2068f198343ae962c043cab42ed975e02` |
| `zImage` | `75a54a639426cee1657b01ea1547b727ce0c0e565f6925a4c3c74641b0a86205` |
| `uImage-hi3531-dhb-ax-ethernet` | `9474b59d7554cda6769d2dd8bdaa9566c78dd171f5dac353c4d4c8b47beb92fc` |

The unchanged DTB checksum is expected because this step changes only kernel
code generation.

## Target validation

The image was staged as `uImage-hi3531-dhb-ax-step4` and booted from RAM. It
reached the existing NFS root as Linux 6.18.42 build `#4`, with both r3p0 CPUs
online. Two concurrent 256 MiB SHA-256 streams completed with the same digest:

```text
a6d72ac7690f53be6ae46ba88506bd97302a093f7108472bd9efc3cefda06484
```

Four concurrent process-churn workers completed 4,000 `/bin/true` executions
with status zero. Both CPUs remained online, SSH and cron remained running,
and the kernel log contained no panic, Oops, BUG, RCU stall, lockup, SError, or
unhandled-fault signature.

## Guide disposition

Disposition for `CPU-01`: **Source changed**, with high confidence. The guide's
r3p0 identification and workaround selection are confirmed on this target.
