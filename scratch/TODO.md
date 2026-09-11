# Miscellaneous

* Remove the GitHub action

* Remove the Justfile

* Get dvr-console.sh to show an error when picocom fails (e.g., because it's already running elsewhere)

* Move TFTP to macos

# Directory structure

* Consolidate kernel and Buildroot sources under vendor/ or upstream/?

# Stage and Boot tooling

* Fix profile naming and remove unused profiles.

* The load addresses belong in a board-level hardware definition, not in each boot profile.

* Print wall clock time after completion (boot, stage)

* Implement dvr-tail (may require reworking dvr-boot's pipe-pane -- they can't bs shared)

* The directory should be profile/ not config/ (too easily confused with Kconfg)

* Remove check_console (runs on the Raspberry Pi and checks /proc/consoles for an active ttyAMA0 kernel console.)

* A computed property such as profile.uses_tftp might simplify conditional guards

# Buildroot

## Worktree support
* Fix SSH keys in artifacts folder
* Fix console log
* Copy downloaded files to save time

## Other
* Stage TFTP on local macOS
* Consolidate to a single profile?
* Move to .env / .env.local (are they more canonical?)
* Remove song and dance required to set the root password
* Upgrade from LTS
* Review/consolidate files in br2-external (Config.in, external.mk, post-build scripts, etc)
* Does root-owned /work still make sense, or should it be $HOME/work?

## Dockerfile

* Replace the Debian package list with a shorthand version?
* Review some of the complications that have crept into Dockerfile (dtschema, LANG)

# Ethernet Driver

* Revisit hi3531_fix_mac_speed(): it currently always programs the Hi3531 interface-control field for full duplex because the stmmac hook does not pass duplex. The board-specific glue can recover its net_device through dev_get_drvdata(dwmac->dev) and use ndev->phydev->duplex, warning instead of guessing if no valid PHY duplex is available.

* Revisit the hi3531_get_hw_feature() override that suppresses CSR58 capability discovery. CSR58 reads 0x016def37 at all three DMA-channel locations; determine whether this is a valid shared/aliased capability register, validate its advertised features against the hardware, and then consider restoring generic stmmac discovery.

* Refactor hi3531_reset_dma_channels() to call dwmac1000_dma_ops.reset() once for each physical DMA-channel window instead of duplicating the generic reset sequence. Pass dwmac->gmac + channel * 0x100; the generic helper adds the DMA_BUS_MODE offset itself.

* Review hi3531_dwmac_init(), which prepares the shared Ethernet hardware before generic stmmac initialization. Understand its three substantive responsibilities: validate the clock state inherited from U-Boot, reset all three physical DMA channels, and replace the shared TNK interrupt mask so only GMAC1 and DMA channel 1 can interrupt Linux.
