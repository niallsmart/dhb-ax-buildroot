# Network throughput

`eth0` is the SoC-integrated `hi3531-dwmac` (Synopsys DWMAC1000 core, GMAC
version `00001036`), driving an RTL8211B PHY. It negotiates and holds
1000Mb/s full duplex, but sustained throughput sits far below that: a single
TCP stream between the board and a same-switch gigabit host plateaus around
230Mbit/s, four parallel streams reach 468Mbit/s aggregate, and a 900Mbit/s
UDP offered load lands at ~220-250Mbit/s with ~75% packet loss. An SCP
receive (decrypt and write, 256MB payload) completes at ~68Mbit/s with both
CPU cores at 50-60% utilization — neither saturated. Measured with `iperf3`
and `scp` against a host on the same L2 segment, kernel 6.18.42 and a Debian
trixie rootfs on the `debian-tftp` initramfs profile.

Receive also wedges permanently under sustained inbound load. That is a
separate fault with its own plan: [ethernet-rx-wedge.md](ethernet-rx-wedge.md).

## Software checksumming — the leading suspect

`dmesg` reports:

```
hi3531-dwmac 101c0000.ethernet: No HW DMA feature register supported
hi3531-dwmac 101c0000.ethernet eth0: RX IPC Checksum Offload disabled
```

`ethtool -k eth0` confirms both directions are off despite the stack asking
for them:

```
rx-checksumming: off [requested on]
tx-checksumming: off
	tx-checksum-ipv4: off [requested on]
	tx-checksum-ipv6: off [requested on]
tcp-segmentation-offload: off [fixed]
```

The DWMAC1000 IP normally supports checksum offload, but `stmmac` only enables
it after reading a DMA hardware-capability register; the `hi3531-dwmac` glue
does not expose that register, so the core falls back to `STMMAC_RX_COE_NONE`
and disables checksumming and TSO outright. Every byte of every TCP/UDP packet
is checksummed in software on these ARMv7 cores instead. This is consistent
with the RPS result: the cost is per-byte CPU work that does not improve by
choosing which core runs it.

Fixing it means supplying the DWMAC1000 platform data (`rx_coe`/`tx_coe`)
directly in `hi3531-dwmac` rather than relying on the capability-register
probe, and verifying the silicon computes correct checksums before trusting
it — forcing this on incorrectly risks silently accepting corrupt frames. The
vendor 3.0.8 driver enables RX checksum offload on the same silicon and marks
packets `CHECKSUM_UNNECESSARY`, so its descriptor semantics are the reference.

Not yet attempted. High value, high effort.

## Open

| Item | Value | Effort | Notes |
|---|---|---|---|
| Interrupt coalescing | Low | Low | `ethtool -c eth0`: `rx-usecs 264`, `tx-usecs 5000`/`tx-frames 25`. Untested whether retuning changes the UDP loss rate or CPU load. |
| TX ring size | Low | Low | The RX ring is 1024; TX stays at the 512 default and raising it is untested. |

## Closed

- **RX ring size.** Raised from 512 to 1024 at probe to keep the driver away
  from the RX wedge. Four-stream TCP rose from 386-392 to 468 Mbit/s.
- **L2 cache.** Enabled and measured against a direct cache-off comparison on
  the same zImage and rootfs. Single-stream TCP and UDP did not materially
  improve; only a 256 MiB SCP receive was consistently faster, by 8%. The
  cache does not remove the network bottleneck.
- **RPS.** Compared `rps_cpus` at `0` and `3` across TCP, UDP and SCP. No
  throughput or loss figure moved outside run-to-run noise. `/proc/softirqs`
  confirms RPS functions — `NET_RX` on CPU1 goes from ~0.1% to ~65% of the
  total — it just relieves nothing, because neither core is saturated on
  receive with it off. It also costs an IPI and a cache-line migration per
  redirected packet, and one run showed higher TCP retransmits consistent with
  flow-hash reordering. Leave `rps_cpus` at `0`.
- **CPU frequency scaling.** No `cpufreq` driver is exposed
  (`/sys/devices/system/cpu/cpu*/cpufreq` is absent), so there is no governor
  to tune.
- **TCP buffer sizing.** `net.ipv4.tcp_rmem`/`tcp_wmem` max out at 7MB/4MB,
  well above the ~430KB bandwidth-delay product implied by 230Mbit/s and the
  ~15ms same-switch RTT. `iperf3` shows `cwnd` growing into the low single-digit
  megabytes without hitting a ceiling.
