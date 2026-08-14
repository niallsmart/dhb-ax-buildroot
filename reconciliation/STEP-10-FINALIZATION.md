# Step 10: maintained-source finalization

Date: 2026-08-14

## Result

Step 10 is complete and ready for review. Maintained comments now state only
validated conclusions, every local Hi3531 compatible used by the maintained
DTBs has a YAML contract, both DTBs pass `dtbs_check`, and a fresh Buildroot
build applies all eleven kernel patches without fuzz and completes without a
new compiler warning.

The reconciliation records remain untracked and are not intended for source
control. This review did not use this repository's `docs/` content as technical
evidence.

## Maintained-source cleanup

- The Ethernet DTS header now describes the validated general-purpose system
  rather than a minimal Ethernet-only image.
- The SATA comment now records the validated AHCI controller, JMicron port
  multiplier, attached disk and read path instead of saying the hardware was
  untested.
- The Buildroot defconfig now counts eleven kernel patches and describes
  `ethtool` and `i2c-tools` by their validated uses rather than as tools for
  open questions.
- Patch 0002 retains its technical reason but drops obsolete patch-generation
  history from the commit message.
- `AGENTS.md` now says that the maintained port declares both 512 MiB banks and
  uses the ARM 2G/2G virtual split.
- The maintained kernel configuration was audited and required no Step 10
  change. Its generated result still selects both CPUs, the 2G/2G split and all
  three applicable Cortex-A9 r3p0 workarounds.

## Binding coverage

Patch `0011-dt-bindings-document-hi3531-platform.patch` adds or extends the
contracts for:

| Maintained interface | Binding |
|---|---|
| `tvt,dhb-ax`, `hisilicon,hi3531` | `arm/hisilicon/hisilicon.yaml` |
| `hisilicon,hi3531-smp` | `arm/hisilicon/hisilicon,hi3531-smp.yaml` |
| `hisilicon,hi3531-sysctrl` | `arm/hisilicon/controller/sysctrl.yaml` |
| `hisilicon,hi3531-uart-mux` | `clock/hisilicon,hi3531-uart-mux.yaml` |
| `hisilicon,hi3531-ahci` | `ata/hisilicon,hi3531-ahci.yaml` |
| `hisilicon,hi3531-usb-phy` | `phy/hisilicon,hi3531-usb-phy.yaml` |
| `hisilicon,hi3531-dwmac` | `net/hisilicon,hi3531-dwmac.yaml` from patch 0003 |

It also registers the `tvt` vendor prefix. There is no schema-only compatible
that lacks a matching implementation, and no local compatible in either
maintained DTB lacks a schema.

## Reproducible validation tools

The Buildroot Docker image now includes `yamllint 1.29.0` and an isolated
Python virtual environment containing pinned `dtschema 2026.6`. The additional
Debian build dependencies are `python3-dev`, `python3-venv` and `swig`.

The seven local or extended binding files passed strict document validation:

```text
dt-doc-validate -u \
  Documentation/devicetree/bindings/arm/hisilicon/hisilicon.yaml \
  Documentation/devicetree/bindings/arm/hisilicon/hisilicon,hi3531-smp.yaml \
  Documentation/devicetree/bindings/arm/hisilicon/controller/sysctrl.yaml \
  Documentation/devicetree/bindings/ata/hisilicon,hi3531-ahci.yaml \
  Documentation/devicetree/bindings/clock/hisilicon,hi3531-uart-mux.yaml \
  Documentation/devicetree/bindings/phy/hisilicon,hi3531-usb-phy.yaml \
  Documentation/devicetree/bindings/net/hisilicon,hi3531-dwmac.yaml
exit 0, no output
```

The same files passed the kernel's `.yamllint` rules with exit status 0 and no
diagnostics. A focused kernel check then validated the compiled trees against
those schemas:

```text
make ARCH=arm CROSS_COMPILE=arm-buildroot-linux-gnueabihf- \
  DT_SCHEMA_FILES=<the seven bindings above, colon-separated> dtbs_check

DTC [C] arch/arm/boot/dts/hisilicon/hi3531-dhb-ax.dtb
DTC [C] arch/arm/boot/dts/hisilicon/hi3531-dhb-ax-ethernet.dtb
exit 0, no schema violation
```

The configured HiSilicon build also checked `hi3620-hi4511.dtb` and
`hi3519-demb.dtb` without a diagnostic. A kernel-wide binding run is not used
as the acceptance gate: it traverses thousands of unrelated upstream schemas
and the newer validator reports pre-existing Linux 6.18.42 lint/schema issues.
The strict checks above isolate every schema changed or introduced by this
port and both of its emitted DTBs.

## Clean build

`scripts/buildroot.sh linux-dirclean` removed the derived kernel tree. A
subsequent `scripts/buildroot.sh` extracted the pinned Linux 6.18.42 archive,
applied patches 0001 through 0011 with Buildroot's zero-fuzz policy, rebuilt the
kernel and both appended-DTB images, and completed successfully.

The generated kernel configuration contains:

```text
CONFIG_NR_CPUS=2
CONFIG_ARM_ERRATA_754322=y
CONFIG_ARM_ERRATA_764369=y
CONFIG_ARM_ERRATA_775420=y
CONFIG_VMSPLIT_2G=y
CONFIG_PAGE_OFFSET=0x80000000
```

Final artifacts from that build are:

| Artifact | Bytes | SHA-256 |
|---|---:|---|
| `hi3531-dhb-ax.dtb` | 1,901 | `e9d11dec700d3e50576d7401f0b8629feddeab2c0c53d10dada54693e1c92295` |
| `hi3531-dhb-ax-ethernet.dtb` | 6,465 | `c7b7e080ee5542e3f2c8c902d4cf25854f8c6c61ce3f94be7599dd23f0b1586d` |
| `rootfs.tar` | 17,510,400 | `8251732879a367dfe764cde13ff19768d1867739edd2a485013f079092c47723` |
| `uImage-hi3531-dhb-ax` | 3,185,045 | `1397d9c1112fae3e899c2d860aa058915ccdf712cd9b06640ebc7fe758218a4b` |
| `uImage-hi3531-dhb-ax-ethernet` | 3,189,609 | `f70a2b654e3eddd5a24756e85ceb01e9df2a79e34ff71a3025726d434c1ec09e` |
| `zImage` | 3,183,080 | `b2b42308bdb0586b5cd081a3a7741e601db0bd50d58e46f887f6fb678495e5da` |
| `zImage-hi3531-dhb-ax-appended-dtb` | 3,184,981 | `2621fe7d1dde0a8897c9284020828818d4ca905893bdf007439a1b2d3aa7642d` |
| `zImage-hi3531-dhb-ax-ethernet-appended-dtb` | 3,189,545 | `d1ae068c03376b8f36d14c9f411cdbcd3c17a4aeac21bd89da9fb32cbe28bd6c` |

## Porting-guide corrections

Earlier reconciliation work already corrected the guide's GPIO, RTC and
Ethernet claims in guide commits `4118094`, `c699ae5` and `0d5696a`. The Step 10
audit found and corrected three more source-guide mismatches:

- `doc/01-soc-overview.md` now retains `hisilicon,sysctrl` as the fallback for
  the Hi3531 system controller because Linux's `hisi-reboot` driver matches it.
- `doc/07-sata-storage.md` now describes the required Hi3531 AHCI clock,
  reset, PHY and port-workaround glue, its exact two-window node, and the
  validated controller/multiplier/disk read path.
- `doc/08-usb.md` now uses generic EHCI/OHCI hosts plus the shared
  `hisilicon,hi3531-usb-phy` provider and records the successful front-panel
  mass-storage test.
- `doc/16-porting-roadmap.md` now summarizes those validated SATA and USB
  implementations.

The guide worktree's pre-existing `.gitignore` and `hi3531.code-workspace`
changes were not touched.

## Baseline versus reconciled behavior

| Area | Step 1 baseline | Reconciled result |
|---|---|---|
| Memory | One 512 MiB bank in DT; 3G/1G split | Two independent 512 MiB banks; 2G/2G split; `MemTotal` about 1,033 MiB and no `Ignoring RAM` |
| CPUs | Two CPUs described through incompatible Hi3620 operations; safe CPU1 release not established | Dedicated Hi3531 release writes only `SYS_CTRL + 0x134`; two CPUs online and stable under concurrent load and warm reboot |
| Errata | Only 764369 enabled | 754322, 764369 and 775420 enabled for confirmed Cortex-A9 r3p0 |
| GPIO | Nineteen PL061 nodes; only a GPIO0 identity claim | All nineteen native IDs and bindings validated; GPIO18 offsets 6 and 7 explicitly excluded from consumers |
| RTC | External DS1307 and an incorrect on-chip clock-gating diagnosis | External `0x68` compatibility, one-Hz advance, `rtc0` and hctosys validated; PL031 correctly deferred for its write-lock quirk |
| Ethernet | 3.40a fallback selected an inaccurate behavior bundle | Generic DWMAC fallback plus explicit Hi3531 shared-block quirks; DHCP, SSH and bidirectional traffic validated |
| SATA | Local glue present but DTS said hardware was unvalidated | AHCI 1.2, two ports, JMicron multiplier, 1 TB disk and raw read validated; schema added |
| USB | Local PHY and generic hosts present but no attached-device validation | Both root hubs and front-panel high-speed mass storage validated, including dispersed write/readback; schema added |
| Watchdog | SP805 node present without current-port timing validation | 3 MHz timing and clean magic close validated without reset |
| Static validation | Nine patches; binding review by inspection because tooling was absent | Eleven zero-fuzz patches; all local contracts documented; strict schema checks and `dtbs_check` clean |

## Remaining limitations, not contradictions

There is no unresolved guide/source contradiction in the maintained bring-up
scope. The deliberate limitations are:

- no GPIO18 consumers may use the physically absent offsets 6 or 7;
- no on-chip PL031 node until a Hi3531 write-unlock quirk is implemented;
- no CPU-hotplug callbacks until a safe offline/re-online sequence is known;
- no deliberate link-drop test while the running system uses a hard NFS root
  (Step 7 separately validated link transitions);
- no media capture, codec, scaling or display support, which remains outside
  the project scope.
