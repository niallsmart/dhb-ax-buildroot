# Linux port for the LTS LTD2704XE-P DVR

Running mainline Linux on an LTS LTD2704XE-P four-channel HD-SDI digital
video recorder.

This DVR is built on a Shenzhen TVT motherboard silkscreened
**`DHB_AX V1.2`**, using the HiSilicon Hi3531 (`godnet`) platform. It shipped
with Linux 3.0.8 and a stack of binary-only vendor modules. This project
replaces that with Linux 6.18.42 LTS. U-Boot loads the kernel from USB flash,
Linux mounts its Buildroot root filesystem from the internal SATA HDD, and
TFTP/NFS remain available for development and recovery. The port drives as
much of the hardware as can be supported without vendor blobs.
