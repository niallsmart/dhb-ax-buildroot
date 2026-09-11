# Linux port for the DHB_AX board

This project is a port of mainline Linux to the LTS LTD2704XE-P DVR. This device is built on the HiSilicon Hi3531 SoC and uses a Shenzhen TVT Digital motherboard silkscreened **`DHB_AX V1.2`**. The same board ships under several other retail brands.

The Hi3531 has no upstream support. This port names the SoC `hisilicon,hi3531` and the board `tvt,dhb-ax`, following mainline convention. HiSilicon's name for their own Hi3531 reference board was `godnet`.

This repository contains the maintained Linux and Buildroot implementation, along with a [Debian root filesystem](debian/README.md) using the Buildroot kernel.

## Hardware Guide

The [DHB_AX hardware guide](https://github.com/niallsmart/dhb-ax-guide/blob/main/doc/README.md) was created as a technical reference for the SoC and board and should be useful to other porting efforts.

## Remaining Work

Remaining port work is tracked [here](doc/remaining-work.md) ranked by value and effort.
