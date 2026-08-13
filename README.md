# Linux port for the LTS LTD2704XE-P DVR

Running mainline Linux on an LTS LTD2704XE-P four-channel HD-SDI digital
video recorder.

This DVR is built on a Shenzhen TVT motherboard silkscreened
**`DHB_AX V1.2`**, using the HiSilicon Hi3531 (`godnet`) platform. It shipped
with Linux 3.0.8 and a stack of binary-only vendor modules. This project
replaces that with Linux 6.18.42 LTS, booted from RAM over the network,
driving as much of the hardware as can be supported without vendor blobs.

