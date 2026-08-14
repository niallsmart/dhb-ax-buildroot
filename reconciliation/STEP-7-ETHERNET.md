# Step 7: Ethernet binding and capability reconciliation

## Scope and conclusion

This step compares the maintained Ethernet DTS and Linux patch queue with the
early official porting guide. Repository `docs/` content was not used as
technical evidence.

The Synopsys version register identifies a DWMAC1000 core with ID `0x36`
(3.60), for which Linux 6.18.42 has no exact versioned compatible. The source
now uses:

```dts
compatible = "hisilicon,hi3531-dwmac", "snps,dwmac";
```

The unversioned fallback is the correct IP identity. It does not make the
Hi3531 glue optional: this SoC places shared MDIO, GMAC1, DMA channel 1 and the
TNK interrupt aggregator at non-generic offsets.

## Linux match-data audit

In Linux 6.18.42, `snps,dwmac-3.40a` implicitly selects enhanced descriptors,
TX checksum insertion, the jumbo-frame quirk and PMT support. Those defaults
were previously being used as a behavior bundle rather than as an accurate
hardware identity.

The Hi3531 glue now selects the independently supported behavior explicitly:

| Capability | Reconciled setting | Evidence |
|---|---|---|
| Enhanced descriptors | Enabled | Vendor configuration and target probe; extended descriptors operate under traffic |
| TX checksum insertion | Disabled | CSR58 is unusable; enabling the advertised feature fails |
| RX checksum offload | Disabled | No usable hardware feature register; target logs confirm disabled |
| Jumbo frames | Disabled | Unverified; MTU is capped at the validated Ethernet payload size of 1500 |
| PMT/WOL | Disabled | Unverified; final `ethtool` reports only wake-on `d` |
| Forced TX store-and-forward | Disabled | With checksum offload disabled it reproducibly wedges TX DMA after a short burst |

The existing source-backed integration was retained: shared base
`0x101c0000`, GMAC1 control at `+0x4000`, DMA channel 1, shared MDIO, all three
DMA channels reset after warm boot, TNK mask `0x48`, PHY address 1, plain
RGMII, MAC `00:18:ae:3c:a2:49`, and the upper 16-bit field at `CRG + 0xec`.

## Binding and build validation

The local Linux patch adds `hisilicon,hi3531-dwmac.yaml`, references
`snps,dwmac.yaml`, and adds the vendor compatible to the base schema's
selection list. The complete patch applies to pristine Linux 6.18.42 with
`patch -F0` and no fuzz. Ruby/Psych parsed the YAML and assertions confirmed
the exact compatible sequence. Full `dt-schema` tooling was not installed in
the available host or build container; the clean build and equivalent manual
schema review therefore remain the recorded validation for this step.

A clean Buildroot rebuild applied all ten kernel patches, compiled both DTBs
and the kernel without source warnings, and produced:

| Artifact | SHA-256 |
|---|---|
| `hi3531-dhb-ax-ethernet.dtb` | `053dbff2b574ef33af8704c943daf3e2068f198343ae962c043cab42ed975e02` |
| `uImage-hi3531-dhb-ax-ethernet` | `6a88ace78a0e5dd428d9dbaf6adb067d0099a5f984b9d2bc62726ffc7664363d` |

The decompiled DTB contains the two shared register windows, the Hi3531 plus
generic compatible sequence, RGMII, PHY address 1, and the board MAC. The DTC
decompile reported pre-existing warnings for the USB PHY unit address and the
register-less GPIO I2C node; neither concerns the Ethernet node.

## Target validation

The exact clean image above was staged under
`uImage-hi3531-dhb-ax-ethernet-step7` and RAM-booted by the maintained
`tools/dvr-boot.exp`. It transferred 6,873,345 bytes, reached Linux 6.18.42
build `#3` dated `Thu Aug 13 22:00:05 UTC 2026`, and restored the persistent
tmux console. No flash or SATA command was issued.

Probe evidence included:

- Synopsys ID `0x36` and user ID `0x10`;
- no usable hardware DMA feature register;
- enhanced/alternate and extended descriptors enabled;
- TNK interrupt enable changed to `0x48`;
- RX checksum offload, PTP and safety features disabled;
- RTL8211B mainline identity at MDIO address 1; and
- 1 GiB RAM and two CPUs, confirming this was the reconciled kernel.

The final link negotiated 1000 Mb/s, full duplex, with autonegotiation on.
Large-packet traffic passed, `CRG + 0xec` read `0x003c003c`, and relevant
driver counters remained clean:

| Counter | Value |
|---|---:|
| TX underflow | 0 |
| RX overflow | 0 |
| RX CRC errors | 0 |
| TX process stopped | 0 |
| RX process stopped | 0 |
| Fatal bus error | 0 |
| DMA threshold | 64 |

An earlier boot of the same binary configuration, before the schema-only final
patch addition, completed 500 1,400-byte pings with zero loss and exercised a
forced 100/full transition followed by return to 1000/full, also with zero
loss. Attempts to enable TX or RX checksum offload were rejected, and MTU 1501
was rejected while 1500 remained active.

## Guide disposition

The guide was correct that core 3.60 should use generic `snps,dwmac` rather
than an invented or inaccurate Synopsys revision string. It was corrected in
the following respects:

- the binding name now matches the maintained `hisilicon,hi3531-dwmac` ABI;
- the glue is no longer described as only a `fix_mac_speed` callback;
- the shared GMAC1/DMA1/MDIO register model and warm-reset requirement are
  documented;
- the TNK TOE path remains unused, but its interrupt aggregator is not ignored;
  and
- enhanced descriptors and the deliberately disabled capabilities are
  recorded from target evidence.

Disposition for `ETH-01`: **Both changed**, with high confidence.
