# Kernel configuration review: Debian-compatible headless server

Reviewed on 2026-09-13 against repository commit `6207838` and patched kernel commit `7262c362d479` (Linux 6.18.42).

## Baseline and priorities

The appropriate Debian reference is **Trixie armhf, standard armmp**, matching the [Debian userspace definition](../debian/README.md). Debian's flavour metadata describes armmp as ARMv7 multiplatform; armmp-lpae is a separate flavour. This board needs its own Hi3531 kernel support, so Debian is a reference for userspace interfaces, security and server facilities, not a replacement kernel or a hardware-driver checklist.

This review compares a fresh expansion of [linux_defconfig](../br2-external/board/dhb-ax/linux_defconfig) with the immutable Debian `6.12.43-1` [common configuration][debian-common] and [armhf configuration][debian-armhf]. The [flavour metadata][debian-flavours] and directory listing confirm there is no separate standard-armmp config fragment at that tag. This is a reproducible Trixie-era policy baseline, not a claim about the latest Debian security package. Debian values below are explicit fragment settings; its complete generated configuration was not built. Differences between Linux 6.12 and 6.18 still require Kconfig interpretation.

The current configuration already provides much of the necessary Debian foundation: seccomp filters, namespaces other than user namespaces, CPU and PID cgroups, IPv6, Unix PTYs, inotify, autofs, ext4 ACLs/security attributes, and tmpfs xattrs. An option missing from the defconfig is not necessarily disabled.

Recommended order:

1. Restore basic hardening, SYN cookies, firewall logging and socket diagnostics; remove unused virtual-terminal/input support.
2. Add memory/IO resource controls and pressure reporting, then test timing and queueing improvements on the board.
3. Add AppArmor, eBPF-dependent service restrictions or optional storage/container modules only with a concrete userspace consumer.

Here, **enable** means a recommended default, **trial** means validate on hardware before adopting, and **conditional** means leave the current setting until the stated need exists. Size and runtime costs are qualitative: no candidate kernel was compiled or benchmarked. Modules avoid permanent residency only while unloaded; they still enlarge the module archive/root filesystem.

## 1. Kernel hardening

These are useful on a network-accessible headless machine and do not require broad driver support. Debian explicitly enables the first three groups in its common configuration.[debian-common]

| Recommendation | Current expanded configuration | Reason and qualification |
|---|---|---|
| Enable `CONFIG_STACKPROTECTOR=y` and `CONFIG_STACKPROTECTOR_STRONG=y` | Stack protector disabled | Restore compiler-generated stack corruption checks. Kconfig also selects the supported per-task implementation. |
| Enable `CONFIG_STRICT_KERNEL_RWX=y` and `CONFIG_STRICT_MODULE_RWX=y` | Both disabled | Protect executable code and read-only data; avoid writable executable mappings. Exercise the custom cache code and module loading during validation. |
| Enable `CONFIG_HARDENED_USERCOPY=y`, `CONFIG_FORTIFY_SOURCE=y`, `CONFIG_SLAB_FREELIST_RANDOM=y`, and `CONFIG_SLAB_FREELIST_HARDENED=y` | All disabled | Restore copy-boundary and allocator protections. These add checks or allocator metadata, not a collection of modules. |
| Trial `CONFIG_ARM_PAN=y` and `CONFIG_VMAP_STACK=y` | Both explicitly disabled | ARM PAN uses CPU domains on this non-LPAE configuration; it does not require ARMv8 PAN hardware. Guarded virtual stacks help detect stack overflow. Both are supported by the current tree and normally default on when eligible. Test syscall-heavy work, SMP and interrupts. |
| Enable `CONFIG_SECURITY_DMESG_RESTRICT=y` and `CONFIG_SECURITY_YAMA=y` | Both disabled | Restrict unprivileged kernel-log access and provide ptrace policy. The existing `CONFIG_LSM` string already includes `yama`; verify the active LSM list and ptrace sysctl after boot. |
| Conditional: `CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y` | Disabled; Debian enables it | Worth considering after the preceding protections. Zeroing newly allocated memory has a direct bandwidth/CPU cost; measure on this SoC. Leave free-time zeroing off initially. |

The ARM-specific rationale comes from the checked-in [ARM Kconfig](../kernel/linux/arch/arm/Kconfig); generic protection semantics and dependencies are in [architecture Kconfig](../kernel/linux/arch/Kconfig) and [hardening Kconfig](../kernel/linux/security/Kconfig.hardening). ARM PAN is an upstream-default recommendation here, not an explicitly observed Debian fragment setting.

`CONFIG_DEVMEM=y` with `CONFIG_STRICT_DEVMEM=n` remains a development-oriented exception. For a deployed server, recommend `CONFIG_STRICT_DEVMEM=y`; disable `CONFIG_DEVMEM` entirely once register-access diagnostics are no longer needed. Debian retains `/dev/mem` but enables strict access restrictions. Keep unrestricted access a deliberate development choice, not a prerequisite of SSH or normal hardware drivers.

Do not copy Debian's signing/certificate configuration as part of this work. Module-signing enforcement requires a maintained key and release process; merely enabling signature generation does not establish verified boot on this U-Boot system.

## 2. Service isolation and resource control

The main functional gap is incomplete service resource control, rather than failure to boot systemd. Debian enables memory and block-IO cgroups, PSI and cgroup BPF.[debian-common]

| Recommendation | Current | Benefit and cost |
|---|---|---|
| Enable `CONFIG_MEMCG=y`; keep `CONFIG_MEMCG_V1=n` | Memory controller disabled | Per-service memory accounting/limits on cgroup v2. Adds accounting and metadata overhead, justified by containing a runaway service. No legacy memory-controller requirement is evident. |
| Enable `CONFIG_BLK_CGROUP=y` and `CONFIG_BLK_DEV_THROTTLING=y` | IO controller disabled | Enable block-IO accounting and rate limits for background work. Generic block cgroups alone do not implement every IO policy; do not promise proportional weight control from these settings alone. Leave IOCOST/IOLATENCY off initially. |
| Enable `CONFIG_PSI=y`, with `CONFIG_PSI_DEFAULT_DISABLED=n` | Disabled | Expose CPU, memory and IO pressure. Useful for diagnosing a slow server; also supports a future systemd-oomd deployment together with MEMCG. This does not install or configure an OOM daemon. |
| Conditional: `CONFIG_BPF_SYSCALL=y`, `CONFIG_BPF_JIT=y`, `CONFIG_CGROUP_BPF=y`, retaining `CONFIG_BPF_UNPRIV_DEFAULT_OFF=y` | Classic BPF enabled; BPF syscall/JIT disabled | Add when using BPF-backed systemd network/device restrictions. The ARM eBPF JIT capability exists, but this expands the programmable kernel interface. Keep disabled for the lean baseline unless those restrictions are actually configured. |
| Conditional: `CONFIG_USER_NS=y` | Disabled | Needed for user-namespace isolation such as `PrivateUsers=` and rootless containers. Preserve the existing UTS/IPC/PID/network namespaces, but defer this additional interface until required. |

The [systemd v257 requirements][systemd] distinguish basic operation from optional sandboxing: seccomp and network namespaces already work at the configuration level; user namespaces and cgroup BPF enable additional restrictions. `CONFIG_CGROUP_DEVICE=y` alone is not the cgroup-v2 BPF device-control mechanism. Verify actual unit behaviour instead of assuming every hardening directive is effective. Do not add CPUSET, RDMA controllers, checkpoint/restore or a full container stack just to resemble Debian.

### AppArmor and other LSMs

Debian enables AppArmor and places it in its LSM order. The DVR has `CONFIG_SECURITY=y`, but `CONFIG_SECURITY_APPARMOR=n`, no `apparmor` entry in `CONFIG_LSM`, and no explicitly requested AppArmor userspace package in [packages.txt](../debian/packages.txt).

**Conditional recommendation:** adopt `CONFIG_SECURITY_APPARMOR=y` together with Debian's AppArmor userspace and selected service profiles. Add `apparmor` to the existing `CONFIG_LSM` order; enabling the Kconfig symbol alone is insufficient with the current explicit order. Kconfig selects AUDIT, SECURITY_PATH, SECURITY_NETWORK and SECURITYFS. Test profiles before enforcement. Until that policy work is intended, Yama plus seccomp is the smaller useful increment. Do not enable SELinux, SMACK and TOMOYO alongside it merely because Debian offers them. Landlock can remain disabled until an application uses it.

## 3. Networking and firewall usability

| Recommendation | Current | Reason |
|---|---|---|
| Enable `CONFIG_SYN_COOKIES=y` | Disabled | Restore the standard TCP SYN-flood fallback. Debian enables it. Verify `net.ipv4.tcp_syncookies` at runtime; compiling support is not a substitute for checking the sysctl. |
| Enable `CONFIG_NF_LOG_SYSLOG=y` | `NFT_LOG=y`, but both syslog and netlink logging backends disabled | Supply the backend for ordinary nftables `log` rules. Debian's IPv4/IPv6 logging selections pull in this backend; the 6.18 tree describes those per-family options as compatibility selectors. No ulogd/netlink logging stack is needed for basic journal logging. |
| Add `CONFIG_INET_DIAG=m`, `CONFIG_INET_TCP_DIAG=m`, `CONFIG_INET_UDP_DIAG=m`, `CONFIG_UNIX_DIAG=m` | Socket diagnostics disabled | Restore useful `ss` diagnostics for the already-installed iproute2 package. This is a small, purposeful module set. TCP diagnostics follows INET_DIAG through Kconfig. |
| Trial `CONFIG_NET_SCHED=y`, `CONFIG_NET_SCH_FQ_CODEL=y`, `CONFIG_NET_SCH_DEFAULT=y`, `CONFIG_DEFAULT_FQ_CODEL=y` | Network scheduler disabled | Debian uses FQ-CoDel. It is a reasonable server queueing policy without adding every classifier and qdisc. Selecting FQ-CoDel alone does not select it as the default: `NET_SCH_DEFAULT` is also required. Compare latency under load and bidirectional throughput. |

Keep IPv4, IPv6 and stateful nftables filtering. Keep the boot-essential STMMAC/Hi3531/Realtek PHY path built in. BQL and RPS are disabled; treat re-enabling them as separate performance experiments, not Debian-compatibility fixes. This port has a history of Ethernet receive regressions, so queueing changes deserve targeted testing.

For further trimming, disable the currently built-in `CONFIG_IPV6_SIT` if there is no IPv6-over-IPv4 tunnel use. NAT/masquerading (`CONFIG_NFT_NAT`, `CONFIG_NFT_MASQ`) and `CONFIG_TUN` are useful for routing/VPNs, not necessary for an ordinary server. Leave them out of the first cleanup batch; remove or modularize them only after checking deployed firewall/VPN use. Keep conntrack and `NFT_CT` for stateful host filtering. Do not add legacy iptables, IPVS, bridges, veth, connection-tracking helpers or additional NIC families without a service that needs them.

## 4. Storage, filesystems and memory

**Enable `CONFIG_MQ_IOSCHED_DEADLINE=y`.** It is disabled today and enabled by Debian. Providing an alternative scheduler is useful for the board's SATA disks, particularly rotating media under mixed IO. This adds the scheduler; it does not guarantee that it becomes the active per-device policy. Compare `none` and `mq-deadline` before choosing runtime defaults.

Keep SATA/AHCI, SCSI disk and ext4 built in: the Debian profile mounts its root directly from HDD, so making this path modular would require a suitable early userspace/module-loading arrangement. Keep ext4 ACLs/security attributes and tmpfs xattrs. Preserve the existing USB-storage and VFAT modules for maintained storage workflows.

Useful conditional additions, with explicit consumers:

| Feature | Proposed setting when needed | Default recommendation |
|---|---|---|
| Loop-mounted disk images | `CONFIG_BLK_DEV=y`, `CONFIG_BLK_DEV_LOOP=m` | Defer unless image mounting is part of server maintenance. The BLK_DEV menu is currently disabled; enabling it does not require enabling unrelated block drivers. |
| FUSE/SSHFS | `CONFIG_FUSE_FS=m` | Defer until a FUSE application is installed; Debian's built-in FUSE is unnecessary here. |
| Overlay-based containers | `CONFIG_OVERLAY_FS=m` | Defer together with the container/networking requirements, rather than partially enabling a container host. |
| LVM/encrypted volumes | `CONFIG_MD=y`, `CONFIG_BLK_DEV_DM=m`, and the specific DM target modules | Defer until storage layout calls for them. Enabling these does not authorize repartitioning. |
| SCSI generic/BSG access | `CONFIG_CHR_DEV_SG=m`, `CONFIG_BLK_DEV_BSG=y` | Add only if an identified management command or udev property requires it. Test SATA SMART first: ordinary libata SMART access does not universally require `/dev/sg*`. |

Do not add every Debian filesystem, RAID target or network filesystem. A userspace file-sharing service does not automatically need an in-kernel client filesystem; NFS server support is a separate, explicit choice.

Swap is already enabled. Leave zram/zswap and compaction as workload-driven decisions: compressed swap trades CPU time for memory, and restoring compaction adds work that should be justified by allocation failures or a service requirement. The current board DTS describes two 512 MiB banks; do not size policy from the vendor's misleading 256 MiB banner. Keep the current 2G virtual split and HIGHMEM choice during this configuration review; changing memory mapping is a separate board validation exercise.

## 5. Headless hardware and console cleanup

**Disable `CONFIG_VT` and `CONFIG_INPUT`.** They remain enabled through defaults even though the defconfig disables keyboards and mice. This removes the unused virtual-terminal, console-translation and dummy-console path. The front-panel controller uses a serial protocol, not the Linux input subsystem in the maintained implementation.

Retain `CONFIG_TTY`, `CONFIG_UNIX98_PTYS`, PL011 and its serial console: serial login and SSH PTYs are required. Confirm both after the cleanup. Keep DRM, framebuffer, sound, HID, wireless and Bluetooth disabled; no desktop stack is warranted.

Preserve the verified Hi3531 platform, cache, SMP/errata, USB PHY, SATA, Ethernet, GPIO, I2C and RTC selections. Do not import Debian's many SoCs, eight-CPU ceiling, NEON, EFI/Xen or LPAE configuration. In particular, the project's verified CPU configuration has VFP but no NEON. Generic Debian hardware coverage does not establish support on this device.

Keep FTDI serial support modular while it serves a real maintenance use; otherwise it is an easy optional-module removal. Keep the watchdog modular and disabled operationally until reset behaviour is proven: [remaining hardware work](remaining-work.md) records that expiry does not currently reset the SoC. Compiling a driver is not evidence of unattended-recovery capability.

## 6. Timers, scheduling and diagnostics

**Trial `CONFIG_NO_HZ_IDLE=y` and `CONFIG_HIGH_RES_TIMERS=y`.** The current kernel uses periodic 100 Hz ticks with high-resolution timers disabled. These changes improve timer granularity and avoid idle ticks without adopting full tick isolation. Validate the custom clock/timer path, monotonic time, RTC synchronisation, idle behaviour and network traffic before making them permanent.

Retain `CONFIG_HZ_100=y` and `CONFIG_PREEMPT_NONE=y` initially. Debian's common configuration requests 250 Hz and voluntary preemption, but neither is a userspace compatibility requirement. A headless server does not need an interactive-desktop or RT scheduling policy. Keep CPU isolation and PREEMPT_RT out of the baseline.

Keep printk timestamps, kallsyms, useful oops reporting and serial recovery. Leave ftrace, debugfs, sanitizers, lockdep, broad selftests and large debug-information features off in the routine server image. `CONFIG_DEBUG_KERNEL=y` is an umbrella, not proof that all expensive debugging is enabled. Review individual options; do not disable the umbrella indiscriminately. `CONFIG_DEBUG_MEMORY_INIT=y` is a possible later cleanup after memory bring-up is considered stable.

Conditional additions are `CONFIG_TASKSTATS=y`, `CONFIG_TASK_DELAY_ACCT=y`, `CONFIG_TASK_XACCT=y`, and `CONFIG_TASK_IO_ACCOUNTING=y` when using tools that consume task delay/IO accounting. Keep them separate from the basic socket diagnostics above. Exporting the generated `.config` with release artifacts is sufficient for reproducibility; `IKCONFIG`/`IKCONFIG_PROC` is optional rather than a reason to enlarge the kernel immediately.

## 7. Validation before adopting recommendations

Only this document changes maintained state. The active configuration and kernel sources were not modified. The current defconfig was freshly expanded with the project's ARM GCC toolchain in a temporary output directory through `scripts/buildroot.sh --shell`. A scratch candidate confirmed Kconfig acceptance of the core hardening, Yama, cgroup/PSI, networking, mq-deadline, timer and headless-cleanup selections. This establishes dependency feasibility, not runtime correctness or a size estimate. Optional AppArmor/BPF/storage combinations were not built or tested.

Implement in logical batches and regenerate the defconfig through `linux-update-defconfig`. For each batch, inspect `scripts/diffconfig` output, including selected dependencies, and compare the compressed kernel size and module archive size. Measure resident memory on the same boot profile before and after; file size alone does not describe runtime cost.

Acceptance checks should include:

- Both maintained Buildroot recovery boot and Debian HDD boot; serial console, SSH/PTYS, DHCP/DNS, RTC and clean reboot. Use the existing staging/boot tools and retain a known-good image.
- Hardening: active LSM list, dmesg/ptrace policy, module load/unload and sustained SMP/network/storage activity. AppArmor, if adopted, also needs profile-status and denial-log review.
- Resource control: a disposable systemd service with a small memory limit, an IO rate-limit test on a designated scratch file, and readable pressure metrics. Test BPF-backed restrictions explicitly if enabled.
- Networking: `ss -tuanp`, IPv4/IPv6 nftables filtering and actual log output, SYN-cookie sysctl, `tc qdisc show`, and the project's Ethernet regression/throughput workflow.
- Storage/timing: non-destructive IO on approved scratch storage, SMART access, module autoloading, scheduler comparison, stable clocks and latency under load.

Do not touch factory flash, saved U-Boot environment or hardware-guide backups. No storage preparation, deployment or device changes were performed for this review.

[debian-common]: https://salsa.debian.org/kernel-team/linux/-/blob/debian/6.12.43-1/debian/config/config
[debian-armhf]: https://salsa.debian.org/kernel-team/linux/-/blob/debian/6.12.43-1/debian/config/armhf/config
[debian-flavours]: https://salsa.debian.org/kernel-team/linux/-/blob/debian/6.12.43-1/debian/config/armhf/defines.toml
[systemd]: https://github.com/systemd/systemd/blob/v257/README
