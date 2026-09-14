# Line-by-Line Review of linux_defconfig

This document reviews every configuration entry in [linux_defconfig](file:///Users/niallsmart/workspace/dhb-ax-buildroot/br2-external/board/dhb-ax/linux_defconfig) (Linux 6.18.42) for the Shenzhen TVT Digital `DHB_AX V1.2` motherboard (LTS LTD2704XE-P DVR) deployed as a headless server.

## Target Hardware and Operating Profile

The target platform is built around the HiSilicon Hi3531 SoC with dual ARM Cortex-A9 cores (ARMv7-A, VFPv3-D16 hardware floating point, no NEON) and an integrated HiSilicon L2 Cache V200 controller. System memory consists of two 512 MiB DDR3 memory banks at `0x80000000` and `0xc0000000` (1 GiB total), separated by an unmapped address hole, necessitating a 2G/2G virtual memory split (`CONFIG_VMSPLIT_2G=y`). On-board I/O comprises an ARM PrimeCell PL011 UART (`ttyAMA0` serial console, `ttyAMA1` front-panel MCU), Synopsys DesignWare MAC (STMMAC) GMAC1 with an external Realtek RTL8211E Gigabit PHY, platform-mapped AHCI SATA, ARM PrimeCell SP805 watchdog, 19 banks of ARM PrimeCell PL061 GPIOs, bit-banged I2C over GPIO driving a Dallas DS1307 real-time clock, and an on-chip USB 2.0 PHY with platform EHCI/OHCI host controllers. The vendor U-Boot bootloader loads a single uImage without separate device tree support, requiring an appended device tree blob (`CONFIG_ARM_APPENDED_DTB=y`) and ATAGs compatibility (`CONFIG_ARM_ATAG_DTB_COMPAT=y`).

The intended operational role is a headless server running Debian Trixie armhf userspace booted from SATA HDD, with Buildroot initramfs retained for recovery and deployment. Server duties include SSH administration, daemon management via systemd, rootful container support via Docker under unified cgroup v2, and stateful host firewalling with nftables. Because the system is headless and operates with 1 GiB RAM, interactive virtual terminals (`CONFIG_VT`), mouse/keyboard input devices (`CONFIG_INPUT`), framebuffers, and unused network/block drivers are stripped to preserve memory and reduce attack surface.

## Assessment and Disposition Methodology

Each entry in [linux_defconfig](file:///Users/niallsmart/workspace/dhb-ax-buildroot/br2-external/board/dhb-ax/linux_defconfig) is assessed under one of three dispositions:

- **Stay as-is**: The configuration setting aligns with the hardware architecture and headless server requirements. Crucially, in Linux Kconfig, options that default to `y` upstream require explicit `# CONFIG_FOO is not set` directives in a minimal defconfig. Removing these lines would cause Kconfig to silently re-enable unwanted subsystems (such as PC input devices, virtual terminals, or third-party NIC drivers). Therefore, all necessary explicit disablements are assessed as `Stay as-is`.
- **Change**: The configuration should be modified (for example, enabling compiler/kernel security hardening features) to better suit a network-accessible server.
- **Remove**: The configuration line is redundant or obsolete and can be safely eliminated without changing the effective kernel configuration.

## Configuration Review Table

| Line | Config Entry | Current Value | Disposition | Rationale and Target Assessment |
|---|---|---|---|---|
| 1 | `# CONFIG_LOCALVERSION_AUTO is not set` | `not set` | **Stay as-is** | Disabling automatic git commit suffixes prevents kernel release string churn (e.g. `uname -r`), ensuring deterministic module installation paths under `/lib/modules/6.18.42/` across Buildroot and Debian userspace builds. |
| 2 | `CONFIG_KERNEL_XZ=y` | `y` | **Stay as-is** | XZ compression yields the smallest kernel image size, significantly reducing TFTP network loading times and USB staging transfer sizes while decompressing quickly on the dual Cortex-A9 cores. |
| 3 | `CONFIG_SYSVIPC=y` | `y` | **Stay as-is** | System V IPC (shared memory, message queues, semaphores) is a mandatory requirement for Debian userspace, glibc, databases, web servers, and standard Linux daemons. |
| 4 | `CONFIG_POSIX_MQUEUE=y` | `y` | **Stay as-is** | POSIX message queues are strictly required by systemd and standard multi-threaded server software on a modern headless system. |
| 5 | `# CONFIG_CROSS_MEMORY_ATTACH is not set` | `not set` | **Stay as-is** | Disabling `process_vm_readv` and `process_vm_writev` reduces inter-process attack surface on a dedicated headless server where cross-process debuggers (like gdb) or MPI profiling are not required in production. |
| 6 | `CONFIG_NO_HZ_IDLE=y` | `y` | **Stay as-is** | Suppresses periodic timer ticks when CPUs are idle, reducing CPU overhead, context switches, and power consumption on a predominantly idle headless server. |
| 7 | `CONFIG_HIGH_RES_TIMERS=y` | `y` | **Stay as-is** | Enables microsecond timer resolution, essential for accurate network timeouts, high-performance event loops, and modern userspace server daemons. |
| 8 | `CONFIG_BPF_SYSCALL=y` | `y` | **Stay as-is** | Enables the `bpf()` system call, required by systemd v257+ and container runtimes (Docker) for cgroup v2 device access control and sandboxing. |
| 9 | `CONFIG_BPF_JIT=y` | `y` | **Stay as-is** | Compiles eBPF programs to native ARMv7 machine code, dramatically improving the performance of cgroup device filters and socket filters on the Cortex-A9 CPU. |
| 10 | `# CONFIG_CPU_ISOLATION is not set` | `not set` | **Stay as-is** | Disables CPU isolation; on a dual-core SoC, isolating a CPU core would remove 50% of the total compute capacity from general server scheduling. |
| 11 | `CONFIG_CGROUPS=y` | `y` | **Stay as-is** | Mandatory foundational infrastructure for process grouping, resource accounting, systemd service management, and container isolation. |
| 12 | `CONFIG_MEMCG=y` | `y` | **Stay as-is** | Enables memory resource control and accounting under cgroup v2, critical on a 1 GiB RAM server to constrain memory-hungry services or Docker containers and prevent system-wide OOM thrashing. |
| 13 | `CONFIG_BLK_CGROUP=y` | `y` | **Stay as-is** | Enables block I/O accounting and cgroup management, essential for monitoring and throttling disk activity on the board's shared SATA HDD. |
| 14 | `CONFIG_CGROUP_SCHED=y` | `y` | **Stay as-is** | Enables CPU bandwidth scheduling in cgroups, required for fair CPU allocation and throttling across systemd services and container workloads. |
| 15 | `CONFIG_CFS_BANDWIDTH=y` | `y` | **Stay as-is** | Provides hard CPU quota enforcement (`--cpus` in Docker, `CPUQuota=` in systemd), preventing background tasks or runaway containers from monopolizing the two CPU cores. |
| 16 | `CONFIG_CGROUP_PIDS=y` | `y` | **Stay as-is** | Enforces maximum process limits per cgroup, providing vital protection against fork bombs and process table exhaustion in Docker containers and systemd services. |
| 17 | `CONFIG_CGROUP_BPF=y` | `y` | **Stay as-is** | Enables cgroup BPF hooks, the modern Linux mechanism used by Docker and systemd for device access filtering (`/dev` whitelisting) under cgroup v2. |
| 18 | `CONFIG_NAMESPACES=y` | `y` | **Stay as-is** | Enables mount, UTS, IPC, PID, and network namespaces, fundamental prerequisites for container isolation and systemd security sandboxing. |
| 19 | `CONFIG_BLK_DEV_INITRD=y` | `y` | **Stay as-is** | Mandatory for booting initial ramdisks, required by the board's Buildroot recovery and staging profiles (`buildroot-tftp`, `buildroot-usb`). |
| 20 | `# CONFIG_RD_GZIP is not set` | `not set` | **Stay as-is** | Disables gzip ramdisk decompression (upstream default y) to eliminate unneeded decompressor code; the system standardizes on XZ for initramfs. |
| 21 | `# CONFIG_RD_BZIP2 is not set` | `not set` | **Stay as-is** | Disables bzip2 ramdisk decompression (upstream default y); unused algorithm on this platform. |
| 22 | `# CONFIG_RD_LZMA is not set` | `not set` | **Stay as-is** | Disables legacy LZMA ramdisk decompression (upstream default y) in favor of modern XZ. |
| 23 | `# CONFIG_RD_LZO is not set` | `not set` | **Stay as-is** | Disables LZO ramdisk decompression (upstream default y), avoiding dead decompressor code. |
| 24 | `# CONFIG_RD_LZ4 is not set` | `not set` | **Stay as-is** | Disables LZ4 ramdisk decompression (upstream default y); unused on this platform. |
| 25 | `# CONFIG_RD_ZSTD is not set` | `not set` | **Stay as-is** | Disables ZSTD ramdisk decompression (upstream default y); saves kernel code space since XZ is used for all ramdisk archives. |
| 26 | `# CONFIG_INITRAMFS_PRESERVE_MTIME is not set` | `not set` | **Stay as-is** | Disables preserving archive mtimes during initramfs unpack (upstream default y), saving time and metadata handling during boot into ramdisk. |
| 27 | `CONFIG_EXPERT=y` | `y` | **Stay as-is** | Exposes advanced kernel configuration options across Kconfig, necessary to strip desktop/VT subsystems and configure fine-grained platform options for this embedded SoC. |
| 28 | `CONFIG_ARCH_HISI=y` | `y` | **Stay as-is** | Mandatory architectural parent configuration symbol for HiSilicon ARM SoCs. |
| 29 | `CONFIG_ARCH_HI3xxx=y` | `y` | **Stay as-is** | Mandatory platform configuration symbol for the HiSilicon Hi3531 SoC on this board. |
| 30 | `CONFIG_CACHE_HIL2V200=y` | `y` | **Stay as-is** | Enables hardware support for the HiSilicon L2 Cache V200 controller on the Hi3531, critical for memory throughput and SMP cache performance. |
| 31 | `# CONFIG_ARM_ERRATA_643719 is not set` | `not set` | **Stay as-is** | Disables erratum 643719 workaround (upstream default y) which applies only to pre-r1p0 Cortex-A9; the Hi3531 has Cortex-A9 r2pX, so this workaround is inapplicable overhead. |
| 32 | `CONFIG_ARM_ERRATA_754322=y` | `y` | **Stay as-is** | Enables critical workaround for Cortex-A9 r2p*/r3p* erratum 754322 (faulty MMU translation following ASID switch), preventing micro-TLB corruption and kernel crashes under SMP. |
| 33 | `CONFIG_ARM_ERRATA_764369=y` | `y` | **Stay as-is** | Enables workaround for Cortex-A9 r2p*/r3p* erratum 764369 (speculative memory access instruction fetch issue), preventing CPU deadlocks under SMP. |
| 34 | `CONFIG_ARM_ERRATA_775420=y` | `y` | **Stay as-is** | Enables workaround for Cortex-A9 r2p2/r3p0 erratum 775420 (out-of-order L2 cache accesses), ensuring cache coherency between CPU and L2 cache. |
| 35 | `CONFIG_SMP=y` | `y` | **Stay as-is** | Mandatory to enable symmetric multiprocessing across both Cortex-A9 cores of the Hi3531 SoC. |
| 36 | `# CONFIG_SMP_ON_UP is not set` | `not set` | **Stay as-is** | Disables runtime uniprocessor patching infrastructure (upstream default y); the Hi3531 hardware is fixed dual-core and will never boot on a uniprocessor chip. |
| 37 | `# CONFIG_ARM_CPU_TOPOLOGY is not set` | `not set` | **Stay as-is** | Disables CPU topology parsing (upstream default y); the SoC has two identical symmetric cores in a single cluster with no big.LITTLE or asymmetrical scheduling requirements. |
| 38 | `CONFIG_VMSPLIT_2G=y` | `y` | **Stay as-is** | Configures a 2G/2G user/kernel virtual memory split, essential because the board's 1 GiB physical RAM spans from 0x80000000 to 0xdfffffff across two DDR controllers with a 512 MiB hole, requiring 2 GiB of kernel address space to map lowmem and I/O. |
| 39 | `CONFIG_NR_CPUS=2` | `2` | **Stay as-is** | Matches the exact physical core count of the dual-core Hi3531, minimizing per-CPU kernel data structures and bitmap sizing. |
| 40 | `# CONFIG_ARM_PATCH_IDIV is not set` | `not set` | **Stay as-is** | Cortex-A9 lacks hardware integer divide; disabling IDIV instruction patching avoids useless runtime trapping and patching code. |
| 41 | `# CONFIG_ARM_PAN is not set` | `not set` | **Change** | Recommend changing to `CONFIG_ARM_PAN=y` (subject to trial). ARM Privileged Access Never emulation via memory domains prevents the kernel from executing or dereferencing userspace memory directly, offering strong hardening against privilege escalation attacks on a network-facing server. |
| 42 | `# CONFIG_ARM_MODULE_PLTS is not set` | `not set` | **Stay as-is** | Disables module PLT trampolines into vmalloc space (upstream default y); the system's small set of compiled modules fits easily within the 16 MiB ARM module virtual memory range. |
| 43 | `# CONFIG_ATAGS is not set` | `not set` | **Stay as-is** | Disables legacy non-DTB ATAGS boot data passing (upstream default y); the kernel boots via appended Device Tree, rendering legacy ATAG parsing redundant. |
| 44 | `CONFIG_ARM_APPENDED_DTB=y` | `y` | **Stay as-is** | Mandatory for booting on this board because vendor U-Boot only loads legacy uImages and cannot load separate FDT blobs; the DTB must be appended to the kernel image. |
| 45 | `CONFIG_ARM_ATAG_DTB_COMPAT=y` | `y` | **Stay as-is** | Essential bridge allowing Linux to extract command-line arguments (`bootargs`) and memory layout passed by vendor U-Boot in ATAGs and inject them into the appended DTB chosen node. |
| 46 | `CONFIG_VFP=y` | `y` | **Stay as-is** | Mandatory hardware floating-point support required by Debian `armhf` userspace ABI and Cortex-A9 VFPv3-D16 hardware. |
| 47 | `# CONFIG_SUSPEND is not set` | `not set` | **Stay as-is** | Disables suspend-to-RAM (upstream default y); the headless server runs 24/7 and the board lacks power-management/PMIC suspend drivers. |
| 48 | `# CONFIG_STACKPROTECTOR is not set` | `not set` | **Change** | Recommend changing to `CONFIG_STACKPROTECTOR=y` and `CONFIG_STACKPROTECTOR_STRONG=y`. Compiler-generated stack canaries detect buffer overflows and stack-smashing attacks, providing essential baseline security for a network-connected server. |
| 49 | `# CONFIG_VMAP_STACK is not set` | `not set` | **Change** | Recommend changing to `CONFIG_VMAP_STACK=y` (subject to trial). Allocates kernel stacks in virtually mapped memory with guard pages, catching stack overflows with an immediate page fault instead of silent memory corruption. |
| 50 | `# CONFIG_STRICT_KERNEL_RWX is not set` | `not set` | **Change** | Recommend changing to `CONFIG_STRICT_KERNEL_RWX=y`. Enforces W^X memory protection on kernel code and data, marking kernel text as read-only and preventing arbitrary code execution in kernel space. |
| 51 | `# CONFIG_STRICT_MODULE_RWX is not set` | `not set` | **Change** | Recommend changing to `CONFIG_STRICT_MODULE_RWX=y`. Extends W^X memory protection to kernel loadable modules, preventing writable executable module mappings. |
| 52 | `# CONFIG_GCC_PLUGINS is not set` | `not set` | **Stay as-is** | Disables GCC compiler plugin infrastructure (upstream default y); avoids cross-compilation toolchain plugin build dependencies while standard compiler hardening options remain available. |
| 53 | `CONFIG_MODULES=y` | `y` | **Stay as-is** | Enables loadable kernel module support, allowing optional drivers and container networking features to load on demand rather than permanently consuming resident memory. |
| 54 | `CONFIG_MODULE_UNLOAD=y` | `y` | **Stay as-is** | Allows unloading unused modules (`rmmod`), reclaiming memory on a 1 GiB RAM system and facilitating driver development and testing. |
| 55 | `# CONFIG_BLOCK_LEGACY_AUTOLOAD is not set` | `not set` | **Stay as-is** | Disables deprecated legacy block device driver autoloading upon device node open (upstream default y); modern userspace relies on udev/systemd-udevd hardware discovery. |
| 56 | `# CONFIG_BLK_DEV_WRITE_MOUNTED is not set` | `not set` | **Stay as-is** | Prevents direct writes to block devices that have mounted filesystems (upstream default y), protecting filesystem integrity from accidental userspace corruption. |
| 57 | `CONFIG_BLK_DEV_THROTTLING=y` | `y` | **Stay as-is** | Enables block device I/O rate throttling (bps/iops) in the block cgroup controller, used by Docker and systemd to prevent background tasks from starving disk I/O. |
| 58 | `# CONFIG_MQ_IOSCHED_KYBER is not set` | `not set` | **Stay as-is** | Disables the Kyber multiqueue I/O scheduler (upstream default y), which is targeted at fast NVMe storage; the board uses SATA AHCI with mq-deadline. |
| 59 | `# CONFIG_SLAB_MERGE_DEFAULT is not set` | `not set` | **Stay as-is** | Disables merging of compatible slab caches (upstream default y), isolating object caches to harden the kernel against heap exploitation (use-after-free and heap feng-shui). |
| 60 | `# CONFIG_COMPAT_BRK is not set` | `not set` | **Stay as-is** | Disables legacy heap positioning (upstream default y), enabling modern Address Space Layout Randomization (ASLR) for userspace heap memory. |
| 61 | `CONFIG_NET=y` | `y` | **Stay as-is** | Mandatory core networking subsystem for a headless, network-managed server. |
| 62 | `CONFIG_PACKET=y` | `y` | **Stay as-is** | Enables AF_PACKET raw sockets, required by DHCP clients, network diagnostics (tcpdump), and container virtual ethernet bridges. |
| 63 | `CONFIG_UNIX=y` | `y` | **Stay as-is** | Mandatory AF_UNIX local IPC sockets, required by systemd, D-Bus, Docker socket (`/var/run/docker.sock`), and general userspace daemons. |
| 64 | `CONFIG_UNIX_DIAG=m` | `m` | **Stay as-is** | Modular socket monitoring interface for AF_UNIX sockets, used by `ss -x` for diagnostic inspection without permanently occupying resident RAM. |
| 65 | `CONFIG_INET=y` | `y` | **Stay as-is** | Core IPv4/TCP/UDP network protocol stack, essential for all remote access and server operations. |
| 66 | `CONFIG_IP_ADVANCED_ROUTER=y` | `y` | **Stay as-is** | Enables advanced routing features, a prerequisite for multiple routing tables and policy-based routing required by container networks and VPNs. |
| 67 | `CONFIG_IP_MULTIPLE_TABLES=y` | `y` | **Stay as-is** | Enables policy-based routing tables for IPv4, used by Docker, container networking plugins, and VPN routing. |
| 68 | `CONFIG_SYN_COOKIES=y` | `y` | **Stay as-is** | Enables TCP SYN cookies to mitigate TCP SYN-flood denial-of-service attacks against listening server ports (SSH, HTTP). |
| 69 | `CONFIG_INET_DIAG=m` | `m` | **Stay as-is** | Netlink socket monitoring module, enabling `ss` from iproute2 to inspect TCP/UDP sockets on demand. |
| 70 | `CONFIG_INET_UDP_DIAG=m` | `m` | **Stay as-is** | Modular UDP socket diagnostic interface for `ss -u`. |
| 71 | `# CONFIG_IPV6_SIT is not set` | `not set` | **Stay as-is** | Disables IPv6-over-IPv4 (SIT) tunneling (upstream default y); unused on a modern local network or native dual-stack setup. |
| 72 | `CONFIG_IPV6_MULTIPLE_TABLES=y` | `y` | **Stay as-is** | Enables policy routing tables for IPv6, providing parity with IPv4 for dual-stack container networking. |
| 73 | `CONFIG_NETFILTER=y` | `y` | **Stay as-is** | Core packet filtering framework, mandatory for firewalling (nftables), container NAT, and port publishing. |
| 74 | `CONFIG_BRIDGE_NETFILTER=m` | `m` | **Stay as-is** | Passes bridged traffic through Netfilter, required by Docker to filter and forward container traffic across bridge interfaces (`docker0`). |
| 75 | `CONFIG_NF_CONNTRACK=y` | `y` | **Stay as-is** | Connection tracking engine, essential for stateful firewall rules and NAT translation. |
| 76 | `CONFIG_NF_LOG_SYSLOG=m` | `m` | **Stay as-is** | Netfilter syslog logging backend, allowing nftables `log` rules to output dropped packets directly to systemd-journald/syslog. |
| 77 | `CONFIG_NF_CONNTRACK_ZONES=y` | `y` | **Stay as-is** | Enables conntrack zones, preventing connection tracking collisions across isolated container network namespaces. |
| 78 | `CONFIG_NF_TABLES=m` | `m` | **Stay as-is** | Modern packet filtering framework (`nftables`), the primary firewall infrastructure in Debian Trixie; compiled as a module for on-demand loading and reduced boot image size. |
| 79 | `CONFIG_NF_TABLES_INET=y` | `y` | **Stay as-is** | Enables the `inet` address family in nftables, allowing combined IPv4/IPv6 firewall rulesets. |
| 80 | `CONFIG_NFT_CT=m` | `m` | **Stay as-is** | Nftables connection tracking match module, required for stateful firewalling (`ct state established,related accept`). |
| 81 | `CONFIG_NFT_LOG=m` | `m` | **Stay as-is** | Nftables logging expression module, enabling firewall rule logging for intrusion detection and security auditing. |
| 82 | `CONFIG_NFT_LIMIT=m` | `m` | **Stay as-is** | Nftables rate-limiting module, essential for defending against connection flooding and SSH brute-force attempts. |
| 83 | `CONFIG_NFT_MASQ=m` | `m` | **Stay as-is** | Nftables masquerading module, required for source NAT to allow Docker containers on bridge networks outbound LAN/Internet access. |
| 84 | `CONFIG_NFT_NAT=m` | `m` | **Stay as-is** | Nftables NAT module, required for Docker port forwarding (`-p`) and destination NAT. |
| 85 | `CONFIG_NFT_REJECT=m` | `m` | **Stay as-is** | Nftables reject target module, allowing clean TCP RST or ICMP unreachable responses instead of silent timeouts. |
| 86 | `CONFIG_NFT_FIB_IPV4=m` | `m` | **Stay as-is** | Nftables IPv4 FIB lookup module, enabling reverse-path filtering (`rpfilter`) against IP address spoofing. |
| 87 | `CONFIG_NFT_FIB_IPV6=m` | `m` | **Stay as-is** | Nftables IPv6 FIB lookup module, providing reverse-path filtering for IPv6 firewalling. |
| 88 | `CONFIG_BRIDGE=m` | `m` | **Stay as-is** | Modular Ethernet bridge driver, mandatory for Docker bridge networking (`docker0`) and virtual network switches. |
| 89 | `# CONFIG_RPS is not set` | `not set` | **Stay as-is** | Disables Receive Packet Steering (upstream default y); on this dual-core SoC, software interrupt steering creates inter-core cache bouncing and has historically triggered Ethernet receive regressions on the STMMAC controller. |
| 90 | `# CONFIG_BQL is not set` | `not set` | **Stay as-is** | Disables Byte Queue Limits (upstream default y); keeps queueing behavior simple and avoids known throughput/receive instability on this SoC's STMMAC Ethernet driver. |
| 91 | `# CONFIG_WIRELESS is not set` | `not set` | **Stay as-is** | Disables the wireless subsystem (upstream default y); the DVR hardware has no Wi-Fi interface, so omitting 802.11 saves memory and removes unneeded attack surface. |
| 92 | `CONFIG_DEVTMPFS=y` | `y` | **Stay as-is** | Core kernel-managed `/dev` filesystem, mandatory for modern Linux device node management. |
| 93 | `CONFIG_DEVTMPFS_MOUNT=y` | `y` | **Stay as-is** | Automatically mounts devtmpfs at `/dev` during early boot, required by Buildroot and Debian systemd init. |
| 94 | `CONFIG_BLK_DEV_LOOP=m` | `m` | **Stay as-is** | Modular loopback block device driver, enabling mounting and management of raw filesystem images (`mount -o loop`, `losetup`) on demand without requiring floppy, CD-ROM, or other legacy block drivers. |
| 95 | `# CONFIG_SCSI_PROC_FS is not set` | `not set` | **Stay as-is** | Disables obsolete `/proc/scsi` interface (upstream default y); modern storage management relies on sysfs (`/sys/class/scsi_disk/`). |
| 96 | `CONFIG_BLK_DEV_SD=y` | `y` | **Stay as-is** | Mandatory built-in driver for SCSI/SATA disks, essential for mounting the root filesystem from the SATA HDD and accessing USB flash drives. |
| 97 | `# CONFIG_BLK_DEV_BSG is not set` | `not set` | **Stay as-is** | Disables SCSI Block Generic v4 interface (upstream default y); standard SATA disk operation and SMART monitoring under libata do not require BSG. |
| 98 | `# CONFIG_SCSI_LOWLEVEL is not set` | `not set` | **Stay as-is** | Disables discrete parallel SCSI host bus adapter drivers (upstream default y), none of which exist on this SoC. |
| 99 | `CONFIG_ATA=y` | `y` | **Stay as-is** | Core libata subsystem, mandatory for the on-chip SATA controller. |
| 100 | `CONFIG_SATA_AHCI_PLATFORM=y` | `y` | **Stay as-is** | Platform driver framework for non-PCI memory-mapped AHCI SATA host controllers. |
| 101 | `CONFIG_AHCI_HI3531=y` | `y` | **Stay as-is** | SoC-specific AHCI glue driver initializing clocks and PHYs for the Hi3531 SATA controller; essential for HDD access. |
| 102 | `# CONFIG_ATA_SFF is not set` | `not set` | **Stay as-is** | Disables legacy Small Form Factor PATA/IDE register interfaces (upstream default y); the Hi3531 is pure AHCI SATA. |
| 103 | `CONFIG_NETDEVICES=y` | `y` | **Stay as-is** | Core framework enabling physical and virtual network devices. |
| 104 | `CONFIG_TUN=m` | `m` | **Stay as-is** | Universal TUN/TAP driver, providing virtual network interface support for VPNs (WireGuard, OpenVPN, Tailscale) and userspace networking. |
| 105 | `CONFIG_VETH=m` | `m` | **Stay as-is** | Virtual Ethernet pair driver, mandatory for connecting Docker container network namespaces to the host bridge. |
| 106 | `# CONFIG_NET_VENDOR_ALACRITECH is not set` | `not set` | **Stay as-is** | Disables Alacritech Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 107 | `# CONFIG_NET_VENDOR_AMAZON is not set` | `not set` | **Stay as-is** | Disables Amazon ENA Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 108 | `# CONFIG_NET_VENDOR_AQUANTIA is not set` | `not set` | **Stay as-is** | Disables Aquantia Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 109 | `# CONFIG_NET_VENDOR_ARC is not set` | `not set` | **Stay as-is** | Disables ARC Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 110 | `# CONFIG_NET_VENDOR_ASIX is not set` | `not set` | **Stay as-is** | Disables Asix Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 111 | `# CONFIG_NET_VENDOR_BROADCOM is not set` | `not set` | **Stay as-is** | Disables Broadcom Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 112 | `# CONFIG_NET_VENDOR_CADENCE is not set` | `not set` | **Stay as-is** | Disables Cadence MACB Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 113 | `# CONFIG_NET_VENDOR_CAVIUM is not set` | `not set` | **Stay as-is** | Disables Cavium Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 114 | `# CONFIG_NET_VENDOR_CIRRUS is not set` | `not set` | **Stay as-is** | Disables Cirrus Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 115 | `# CONFIG_NET_VENDOR_CORTINA is not set` | `not set` | **Stay as-is** | Disables Cortina Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 116 | `# CONFIG_NET_VENDOR_DAVICOM is not set` | `not set` | **Stay as-is** | Disables Davicom Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 117 | `# CONFIG_NET_VENDOR_ENGLEDER is not set` | `not set` | **Stay as-is** | Disables Engleder Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 118 | `# CONFIG_NET_VENDOR_EZCHIP is not set` | `not set` | **Stay as-is** | Disables EZchip Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 119 | `# CONFIG_NET_VENDOR_FARADAY is not set` | `not set` | **Stay as-is** | Disables Faraday Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 120 | `# CONFIG_NET_VENDOR_FUNGIBLE is not set` | `not set` | **Stay as-is** | Disables Fungible Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 121 | `# CONFIG_NET_VENDOR_GOOGLE is not set` | `not set` | **Stay as-is** | Disables Google virtual NIC drivers (upstream default y); no such hardware on this SoC. |
| 122 | `# CONFIG_NET_VENDOR_HISILICON is not set` | `not set` | **Stay as-is** | Disables HiSilicon Ethernet vendor drivers (`hix5hd2`/`femac`/`hip04`; upstream default y); the Hi3531 GMAC is driven by `STMMAC_ETH`, not this menu. |
| 123 | `# CONFIG_NET_VENDOR_HUAWEI is not set` | `not set` | **Stay as-is** | Disables Huawei Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 124 | `# CONFIG_NET_VENDOR_INTEL is not set` | `not set` | **Stay as-is** | Disables Intel Ethernet vendor drivers (e1000/ixgb/ice; upstream default y); no PCI/PCIe slots exist on this board. |
| 125 | `# CONFIG_NET_VENDOR_LITEX is not set` | `not set` | **Stay as-is** | Disables LiteX Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 126 | `# CONFIG_NET_VENDOR_MARVELL is not set` | `not set` | **Stay as-is** | Disables Marvell Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 127 | `# CONFIG_NET_VENDOR_MELLANOX is not set` | `not set` | **Stay as-is** | Disables Mellanox ConnectX Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 128 | `# CONFIG_NET_VENDOR_META is not set` | `not set` | **Stay as-is** | Disables Meta Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 129 | `# CONFIG_NET_VENDOR_MICREL is not set` | `not set` | **Stay as-is** | Disables Micrel Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 130 | `# CONFIG_NET_VENDOR_MICROCHIP is not set` | `not set` | **Stay as-is** | Disables Microchip Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 131 | `# CONFIG_NET_VENDOR_MICROSEMI is not set` | `not set` | **Stay as-is** | Disables Microsemi Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 132 | `# CONFIG_NET_VENDOR_MICROSOFT is not set` | `not set` | **Stay as-is** | Disables Microsoft MANA Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 133 | `# CONFIG_NET_VENDOR_NI is not set` | `not set` | **Stay as-is** | Disables National Instruments Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 134 | `# CONFIG_NET_VENDOR_NATSEMI is not set` | `not set` | **Stay as-is** | Disables National Semiconductor Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 135 | `# CONFIG_NET_VENDOR_NETRONOME is not set` | `not set` | **Stay as-is** | Disables Netronome Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 136 | `# CONFIG_NET_VENDOR_PENSANDO is not set` | `not set` | **Stay as-is** | Disables Pensando Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 137 | `# CONFIG_NET_VENDOR_QUALCOMM is not set` | `not set` | **Stay as-is** | Disables Qualcomm Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 138 | `# CONFIG_NET_VENDOR_RENESAS is not set` | `not set` | **Stay as-is** | Disables Renesas Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 139 | `# CONFIG_NET_VENDOR_ROCKER is not set` | `not set` | **Stay as-is** | Disables Rocker Ethernet switch drivers (upstream default y); no such hardware on this SoC. |
| 140 | `# CONFIG_NET_VENDOR_SAMSUNG is not set` | `not set` | **Stay as-is** | Disables Samsung Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 141 | `# CONFIG_NET_VENDOR_SEEQ is not set` | `not set` | **Stay as-is** | Disables SEEQ Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 142 | `# CONFIG_NET_VENDOR_SOLARFLARE is not set` | `not set` | **Stay as-is** | Disables Solarflare Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 143 | `# CONFIG_NET_VENDOR_SMSC is not set` | `not set` | **Stay as-is** | Disables SMSC Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 144 | `# CONFIG_NET_VENDOR_SOCIONEXT is not set` | `not set` | **Stay as-is** | Disables Socionext Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 145 | `CONFIG_STMMAC_ETH=y` | `y` | **Stay as-is** | Mandatory built-in Ethernet MAC driver for the on-chip Synopsys DesignWare GMAC1 controller, essential for network access and headless server operation. |
| 146 | `# CONFIG_DWMAC_GENERIC is not set` | `not set` | **Stay as-is** | Disables generic PCI/platform DWMAC glue (upstream default y); the Hi3531 uses device tree platform bindings directly. |
| 147 | `# CONFIG_NET_VENDOR_SYNOPSYS is not set` | `not set` | **Stay as-is** | Disables Synopsys Ethernet vendor menu (upstream default y); the controller is driven via `STMMAC_ETH`. |
| 148 | `# CONFIG_NET_VENDOR_VERTEXCOM is not set` | `not set` | **Stay as-is** | Disables Vertexcom Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 149 | `# CONFIG_NET_VENDOR_VIA is not set` | `not set` | **Stay as-is** | Disables VIA Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 150 | `# CONFIG_NET_VENDOR_WANGXUN is not set` | `not set` | **Stay as-is** | Disables Wangxun Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 151 | `# CONFIG_NET_VENDOR_WIZNET is not set` | `not set` | **Stay as-is** | Disables Wiznet Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 152 | `# CONFIG_NET_VENDOR_XILINX is not set` | `not set` | **Stay as-is** | Disables Xilinx Ethernet vendor drivers (upstream default y); no such hardware on this SoC. |
| 153 | `CONFIG_REALTEK_PHY=y` | `y` | **Stay as-is** | Mandatory PHY driver for the on-board Realtek RTL8211E Gigabit Ethernet PHY connected via RGMII to GMAC1. |
| 154 | `CONFIG_USB_NET_DRIVERS=m` | `m` | **Stay as-is** | Modular USB network adapter subsystem and common drivers (RTL8152, CDC-Ethernet, ASIX), enabling optional USB Ethernet dongles or 4G modems on demand. |
| 155 | `# CONFIG_WLAN is not set` | `not set` | **Stay as-is** | Disables wireless LAN drivers (upstream default y); the hardware has no Wi-Fi interface. |
| 156 | `# CONFIG_INPUT is not set` | `not set` | **Stay as-is** | Disables the entire input subsystem (upstream default y); this headless DVR has no keyboard, mouse, or touchscreen, saving substantial memory and eliminating input event threads. |
| 157 | `# CONFIG_SERIO is not set` | `not set` | **Stay as-is** | Disables PS/2 and serio input bus controllers (upstream default y) on hardware with no PC keyboard/mouse ports. |
| 158 | `# CONFIG_VT is not set` | `not set` | **Stay as-is** | Disables virtual terminals and frame-buffer consoles (upstream default y); console access is exclusively via serial UART (`ttyAMA0`) and SSH. |
| 159 | `# CONFIG_LEGACY_PTYS is not set` | `not set` | **Stay as-is** | Disables deprecated BSD-style pseudo-terminals (upstream default y); modern SSH and terminal sessions exclusively use Unix98 PTYs. |
| 160 | `# CONFIG_LEGACY_TIOCSTI is not set` | `not set` | **Stay as-is** | Disables insecure TIOCSTI terminal injection ioctl (upstream default y), eliminating a notorious privilege escalation and container sandbox escape vector. |
| 161 | `# CONFIG_LDISC_AUTOLOAD is not set` | `not set` | **Stay as-is** | Hardening measure disabling automatic loading of obscure line discipline modules via ioctl (upstream default y). |
| 162 | `CONFIG_SERIAL_AMBA_PL011=y` | `y` | **Stay as-is** | Mandatory built-in serial driver for the on-chip ARM PrimeCell PL011 UART controllers (`uart0` console, `uart1` front panel MCU). |
| 163 | `CONFIG_SERIAL_AMBA_PL011_CONSOLE=y` | `y` | **Stay as-is** | Enables serial console support on `ttyAMA0`, the sole physical console and recovery interface for the DVR. |
| 164 | `# CONFIG_HW_RANDOM is not set` | `not set` | **Stay as-is** | Disables hardware random number generator framework (upstream default m); the SoC has no supported mainline TRNG driver, and kernel entropy is gathered from CPU timers and interrupts. |
| 165 | `# CONFIG_DEVPORT is not set` | `not set` | **Stay as-is** | Disables `/dev/port` (upstream default y); ARM architecture lacks x86 I/O port space, making this device node useless and insecure. |
| 166 | `CONFIG_I2C=y` | `y` | **Stay as-is** | Core I2C subsystem, mandatory for communication with the battery-backed DS1307 real-time clock. |
| 167 | `CONFIG_I2C_CHARDEV=m` | `m` | **Stay as-is** | Exposes `/dev/i2c-X` userspace device interface as a module for debugging and bus scanning (`i2cdetect`) without permanent RAM residency. |
| 168 | `CONFIG_I2C_GPIO=y` | `y` | **Stay as-is** | Mandatory built-in driver for the board's bit-banged I2C bus implemented over PL061 GPIO bank 12 pins 4 and 5 to talk to the DS1307 RTC. |
| 169 | `# CONFIG_PTP_1588_CLOCK is not set` | `not set` | **Stay as-is** | Disables IEEE 1588 PTP hardware clock support (upstream default y); standard NTP network time sync is sufficient for this general-purpose server. |
| 170 | `CONFIG_GPIOLIB=y` | `y` | **Stay as-is** | Core GPIO descriptor framework, required for the 19 on-chip PL061 GPIO banks, bit-banged I2C, and board control lines. |
| 171 | `# CONFIG_GPIO_CDEV_V1 is not set` | `not set` | **Stay as-is** | Disables deprecated legacy GPIO character device ABI v1 (upstream default y); modern tools use the robust v2 ABI. |
| 172 | `CONFIG_GPIO_PL061=y` | `y` | **Stay as-is** | Mandatory built-in driver for the 19 on-chip ARM PrimeCell PL061 GPIO controller blocks. |
| 173 | `# CONFIG_HWMON is not set` | `not set` | **Stay as-is** | Disables hardware monitoring subsystem (upstream default y); board hardware lacks supported temperature or voltage sensors. |
| 174 | `CONFIG_WATCHDOG=y` | `y` | **Stay as-is** | Core watchdog timer subsystem. |
| 175 | `# CONFIG_WATCHDOG_HANDLE_BOOT_ENABLED is not set` | `not set` | **Stay as-is** | U-Boot explicitly stops the watchdog at boot, and SoC reset wiring on timeout is unverified; keeping disabled prevents false watchdog handling. |
| 176 | `CONFIG_WATCHDOG_SYSFS=y` | `y` | **Stay as-is** | Exposes watchdog device attributes in sysfs for status inspection and testing. |
| 177 | `CONFIG_ARM_SP805_WATCHDOG=m` | `m` | **Stay as-is** | Driver for the on-chip ARM PrimeCell SP805 watchdog; appropriately kept as a module until external SoC reset routing on expiry is proven. |
| 178 | `CONFIG_USB=y` | `y` | **Stay as-is** | Core USB host subsystem, required for USB storage staging, recovery boot, and maintenance ports. |
| 179 | `# CONFIG_USB_DEFAULT_PERSIST is not set` | `not set` | **Stay as-is** | Disables USB device persistence across system power suspends (upstream default y); unneeded on a 24/7 server without suspend states. |
| 180 | `CONFIG_USB_EHCI_HCD=y` | `y` | **Stay as-is** | Mandatory built-in driver for the Hi3531 on-chip High-Speed (480 Mbps) USB 2.0 EHCI host controller. |
| 181 | `# CONFIG_USB_EHCI_TT_NEWSCHED is not set` | `not set` | **Remove** | Removed to adopt the upstream `default y` setting; enables modern Transaction Translator periodic scheduling for downstream low/full-speed devices on external USB hubs without microframe starvation. |
| 182 | `CONFIG_USB_EHCI_HCD_PLATFORM=y` | `y` | **Stay as-is** | Platform bus glue driver attaching EHCI to the Hi3531 memory-mapped controller registers. |
| 183 | `CONFIG_USB_OHCI_HCD=y` | `y` | **Stay as-is** | Mandatory built-in companion driver for Full-Speed/Low-Speed (12/1.5 Mbps) USB 1.1 OHCI host controller. |
| 184 | `CONFIG_USB_OHCI_HCD_PLATFORM=y` | `y` | **Stay as-is** | Platform bus glue driver attaching OHCI to the Hi3531 memory-mapped controller registers. |
| 185 | `CONFIG_USB_STORAGE=m` | `m` | **Stay as-is** | Modular USB Mass Storage driver, enabling USB thumb drive staging and maintenance without permanently consuming kernel memory when unplugged. |
| 186 | `CONFIG_USB_SERIAL=m` | `m` | **Stay as-is** | Core framework for USB-to-serial adapters, kept modular. |
| 187 | `CONFIG_USB_SERIAL_FTDI_SIO=m` | `m` | **Stay as-is** | Modular driver for FTDI USB-serial adapters used in board development and external serial communications; can be removed if FTDI adapters are no longer needed, but harmless as a module. |
| 188 | `CONFIG_RTC_CLASS=y` | `y` | **Stay as-is** | Core real-time clock subsystem, mandatory for persistent hardware timekeeping. |
| 189 | `# CONFIG_RTC_SYSTOHC is not set` | `not set` | **Stay as-is** | Disables periodic 11-minute kernel RTC synchronization over bit-banged I2C (upstream default y); userspace NTP daemons sync the RTC explicitly upon clock discipline lock. |
| 190 | `# CONFIG_RTC_NVMEM is not set` | `not set` | **Stay as-is** | Disables nvmem framework binding for the DS1307's 56-byte internal SRAM (upstream default y); unused for system operations. |
| 191 | `CONFIG_RTC_DRV_DS1307=y` | `y` | **Stay as-is** | Mandatory built-in driver for the board's battery-backed Dallas/Maxim DS1307 RTC chip, setting the initial system time at boot (`hctosys`). |
| 192 | `# CONFIG_VIRTIO_MENU is not set` | `not set` | **Stay as-is** | Disables VirtIO guest device drivers (upstream default y); the kernel runs on bare-metal hardware, not inside a virtual machine. |
| 193 | `# CONFIG_VHOST_MENU is not set` | `not set` | **Stay as-is** | Disables vhost virtualization acceleration (upstream default y); Cortex-A9 lacks virtualization extensions and cannot act as a KVM host. |
| 194 | `# CONFIG_COMMON_CLK_HI3516CV300 is not set` | `not set` | **Stay as-is** | Disables clock driver for Hi3516CV300 SoC (upstream default y). |
| 195 | `# CONFIG_COMMON_CLK_HI3519 is not set` | `not set` | **Stay as-is** | Disables clock driver for Hi3519 SoC (upstream default y). |
| 196 | `# CONFIG_COMMON_CLK_HI3559A is not set` | `not set` | **Stay as-is** | Disables clock driver for Hi3559A SoC (upstream default y). |
| 197 | `# CONFIG_COMMON_CLK_HI3660 is not set` | `not set` | **Stay as-is** | Disables clock driver for Hi3660 SoC (upstream default y). |
| 198 | `# CONFIG_COMMON_CLK_HI3670 is not set` | `not set` | **Stay as-is** | Disables clock driver for Hi3670 SoC (upstream default y). |
| 199 | `# CONFIG_COMMON_CLK_HI3798CV200 is not set` | `not set` | **Stay as-is** | Disables clock driver for Hi3798CV200 SoC (upstream default y). |
| 200 | `# CONFIG_COMMON_CLK_HI6220 is not set` | `not set` | **Stay as-is** | Disables clock driver for Hi6220 SoC (upstream default y). |
| 201 | `# CONFIG_IOMMU_SUPPORT is not set` | `not set` | **Stay as-is** | Disables IOMMU subsystem (upstream default y); the Hi3531 SoC lacks an IOMMU, using direct physical memory for all DMA. |
| 202 | `# CONFIG_COMMON_RESET_HI3660 is not set` | `not set` | **Stay as-is** | Disables reset controller driver for Kirin 960 (upstream default y). |
| 203 | `# CONFIG_COMMON_RESET_HI6220 is not set` | `not set` | **Stay as-is** | Disables reset controller driver for Kirin 620 (upstream default y). |
| 204 | `CONFIG_PHY_HI3531_USB=y` | `y` | **Stay as-is** | Mandatory hardware-specific PHY driver for the Hi3531 on-chip USB PHY; required for USB port functionality. |
| 205 | `CONFIG_EXT4_FS=y` | `y` | **Stay as-is** | Mandatory built-in filesystem driver for the primary root filesystem and storage partitions on SATA HDD. |
| 206 | `# CONFIG_EXT4_USE_FOR_EXT2 is not set` | `not set` | **Stay as-is** | Disables claiming legacy ext2 filesystems with ext4 driver (upstream default y); standardizes on native ext4 filesystem format. |
| 207 | `CONFIG_EXT4_FS_POSIX_ACL=y` | `y` | **Stay as-is** | Enables POSIX Access Control Lists on ext4, required by systemd (journald, logind) and granular Debian file permissions. |
| 208 | `CONFIG_EXT4_FS_SECURITY=y` | `y` | **Stay as-is** | Enables security extended attributes (xattrs) on ext4, required for POSIX file capabilities (`setcap`) and security labels. |
| 209 | `# CONFIG_DNOTIFY is not set` | `not set` | **Stay as-is** | Disables obsolete dnotify directory notification API (upstream default y); modern userspace uses inotify. |
| 210 | `CONFIG_AUTOFS_FS=y` | `y` | **Stay as-is** | Autofs filesystem driver, required by systemd for on-demand automounting of partitions and directories (`.automount`). |
| 211 | `CONFIG_OVERLAY_FS=m` | `m` | **Stay as-is** | OverlayFS filesystem module, mandatory for Docker container image layering (`overlay2`) and read-only rootfs overlays. |
| 212 | `CONFIG_VFAT_FS=m` | `m` | **Stay as-is** | Modular FAT/VFAT filesystem driver, providing compatibility for FAT32 USB thumb drives and boot media. |
| 213 | `CONFIG_TMPFS=y` | `y` | **Stay as-is** | Mandatory in-memory filesystem driver for `/run`, `/tmp`, `/dev/shm`, and systemd runtime mounts. |
| 214 | `CONFIG_TMPFS_POSIX_ACL=y` | `y` | **Stay as-is** | Enables POSIX ACLs on tmpfs, required by systemd and D-Bus for access control on runtime directories (`/run`). |
| 215 | `# CONFIG_MISC_FILESYSTEMS is not set` | `not set` | **Stay as-is** | Disables miscellaneous legacy/specialized filesystems (romfs, cramfs, squashfs, minix, etc.; upstream default y) unneeded by the server storage model. |
| 216 | `CONFIG_NLS_CODEPAGE_437=m` | `m` | **Stay as-is** | Modular DOS codepage 437 character mapping, required by VFAT to decode standard ASCII filenames on USB drives. |
| 217 | `CONFIG_NLS_ISO8859_1=m` | `m` | **Stay as-is** | Modular ISO-8859-1 (Latin 1) codepage, required for VFAT long filenames. |
| 218 | `CONFIG_KEYS=y` | `y` | **Stay as-is** | Mandatory Linux kernel keyrings subsystem, required by container runtimes (Docker/containerd per-container session keyrings) and systemd credentials. |
| 219 | `# CONFIG_XZ_DEC_X86 is not set` | `not set` | **Stay as-is** | Disables x86 BCJ branch filter decoder (upstream default y); completely inapplicable on a 32-bit ARM processor. |
| 220 | `# CONFIG_XZ_DEC_POWERPC is not set` | `not set` | **Stay as-is** | Disables PowerPC BCJ branch filter decoder (upstream default y); inapplicable on ARM. |
| 221 | `# CONFIG_XZ_DEC_ARM is not set` | `not set` | **Stay as-is** | Disables ARM BCJ branch filter decoder (upstream default y); plain LZMA2 XZ decompression is used for Buildroot initramfs, saving decompressor code size. (Can change to enable if BCJ-filtered archives are used in future). |
| 222 | `# CONFIG_XZ_DEC_ARMTHUMB is not set` | `not set` | **Stay as-is** | Disables Thumb BCJ branch filter decoder (upstream default y); standard XZ archives on this platform do not employ Thumb branch filtering. |
| 223 | `# CONFIG_XZ_DEC_ARM64 is not set` | `not set` | **Stay as-is** | Disables 64-bit ARM (AArch64) BCJ branch filter decoder (upstream default y); inapplicable on 32-bit ARMv7. |
| 224 | `# CONFIG_XZ_DEC_SPARC is not set` | `not set` | **Stay as-is** | Disables SPARC BCJ branch filter decoder (upstream default y); inapplicable on ARM. |
| 225 | `# CONFIG_XZ_DEC_RISCV is not set` | `not set` | **Stay as-is** | Disables RISC-V BCJ branch filter decoder (upstream default y); inapplicable on ARM. |
| 226 | `CONFIG_PRINTK_TIME=y` | `y` | **Stay as-is** | Prefixes kernel dmesg logs with timestamps relative to boot, indispensable for boot timing, driver debugging, and syslog correlation on a headless server. |
| 227 | `# CONFIG_SYMBOLIC_ERRNAME is not set` | `not set` | **Change** | Recommend enabling (`CONFIG_SYMBOLIC_ERRNAME=y`); costs only ~3 KiB of read-only data on a 1 GiB board and provides human-readable error names (`-ETIMEDOUT`, `-EPROBE_DEFER`) in serial console and dmesg logs. |
| 228 | `# CONFIG_SECTION_MISMATCH_WARN_ONLY is not set` | `not set` | **Stay as-is** | Causes section mismatch warnings during build to be treated as fatal errors (upstream default y), enforcing build hygiene and preventing subtle runtime memory bugs between init and runtime code. |
| 229 | `CONFIG_MAGIC_SYSRQ=y` | `y` | **Stay as-is** | Critical recovery tool over the serial UART console (`ttyAMA0`), allowing emergency disk syncing (`s`), remounting read-only (`u`), dumping state (`t`), and clean rebooting (`b`) of frozen systems without hard power-cycling. |
| 230 | `# CONFIG_FTRACE is not set` | `not set` | **Stay as-is** | Disables function tracing infrastructure (upstream default y); ftrace adds substantial memory overhead, trace tables, and instruction patching overhead inappropriate for a 1 GiB RAM headless production server. |
| 231 | `# CONFIG_RUNTIME_TESTING_MENU is not set` | `not set` | **Stay as-is** | Disables in-kernel runtime test suites and benchmark modules (upstream default y), eliminating unnecessary test code from production builds. |

## Summary of Recommendations

Of the 231 configuration entries in [linux_defconfig](file:///Users/niallsmart/workspace/dhb-ax-buildroot/br2-external/board/dhb-ax/linux_defconfig), 224 entries are recommended to **Stay as-is**, 6 entries are recommended to **Change**, and 1 entry was **Removed** (`# CONFIG_USB_EHCI_TT_NEWSCHED is not set` to adopt the upstream default).

The 6 recommended changes focus on kernel security hardening and serial/dmesg diagnostic readability for an internet- or network-facing headless server:

1. **Stack Protection (Line 48):** Change `# CONFIG_STACKPROTECTOR is not set` to `CONFIG_STACKPROTECTOR=y` and `CONFIG_STACKPROTECTOR_STRONG=y` to detect stack buffer overflows.
2. **Kernel Memory Permissions (Line 50):** Change `# CONFIG_STRICT_KERNEL_RWX is not set` to `CONFIG_STRICT_KERNEL_RWX=y` to enforce W^X permissions on kernel code and data.
3. **Module Memory Permissions (Line 51):** Change `# CONFIG_STRICT_MODULE_RWX is not set` to `CONFIG_STRICT_MODULE_RWX=y` to enforce W^X permissions on dynamically loaded modules.
4. **Guarded Virtual Stacks (Line 49):** Change `# CONFIG_VMAP_STACK is not set` to `CONFIG_VMAP_STACK=y` (subject to hardware validation) to detect kernel stack overflow before memory corruption occurs.
5. **Privileged Access Never (Line 41):** Change `# CONFIG_ARM_PAN is not set` to `CONFIG_ARM_PAN=y` (subject to hardware validation) to emulate PAN using ARM memory domains, preventing the kernel from executing or dereferencing userspace memory.
6. **Symbolic Error Names (Line 227):** Change `# CONFIG_SYMBOLIC_ERRNAME is not set` to `CONFIG_SYMBOLIC_ERRNAME=y` to format `%pe` error prints with human-readable error names (`-ETIMEDOUT`, `-EPROBE_DEFER`) in serial console and dmesg logs at a trivial 3 KiB cost.

Additionally, modular loop block devices (`CONFIG_BLK_DEV_LOOP=m` at Line 94) and modular USB network adapters (`CONFIG_USB_NET_DRIVERS=m` at Line 154) are enabled for on-demand use, and modular FTDI serial support (`CONFIG_USB_SERIAL_FTDI_SIO=m` at Line 187) may be removed if external FTDI debugging dongles are no longer used.
