# General

+ migrate kernel configuration to defconfig files
* replace local.env with .env / .env.local (that is more canonical?)
* remove the Justfile
* consolidate kernel and Buildroot sources under sources/, vendor/ or upstream/?

# Stage and Boot tooling

* load addresses belong in a board-level config, not in boot profiles
* boot profiles should be in profile/ not config/
* remove check_console (runs on the Raspberry Pi)
* computed property such as profile.uses_tftp might simplify guards
* get dvr-console.sh to show an error when picocom fails (e.g., because it's already running outside `dvr` tmux)
* lib.sh -> common.sh
* fix profile naming and remove unused profiles
* print wall clock time after completion (boot, stage)

# Buildroot

## General
* rename bootstrap-sources.sh, upgrade Buildroot and remove version embedded in path
* review/consolidate files in br2-external (Config.in, external.mk, post-build scripts, etc)
* stage TFTP on local macOS (?)


## Worktree support
* what are "elevated commands" and what project configuration did it create in `codex/benchmark-xz`
* debug UV/Docker socket permission issues (maybe should have local UV cache?)
* independent volumes
* allow agents to prepare sources
* fix console log (what is this?)
* fix how SSH keys are handled (should not be in in artifacts/local)
* reuse or copy buildroot tgz to save time on a new branch (maybe?)

## Docker

* does root-owned /work still make sense, or should it be $HOME/work?
* make --shell drop into ~/output?
* replace the Debian package list with a shorthand version?
* review some of the complications that have crept into Dockerfile (dtschema, LANG)


# Ethernet Driver

* Revisit hi3531_fix_mac_speed(): it currently always programs the Hi3531 interface-control field for full duplex because the stmmac hook does not pass duplex. The board-specific glue can recover its net_device through dev_get_drvdata(dwmac->dev) and use ndev->phydev->duplex, warning instead of guessing if no valid PHY duplex is available.

* Revisit the hi3531_get_hw_feature() override that suppresses CSR58 capability discovery. CSR58 reads 0x016def37 at all three DMA-channel locations; determine whether this is a valid shared/aliased capability register, validate its advertised features against the hardware, and then consider restoring generic stmmac discovery.

* Refactor hi3531_reset_dma_channels() to call dwmac1000_dma_ops.reset() once for each physical DMA-channel window instead of duplicating the generic reset sequence. Pass dwmac->gmac + channel * 0x100; the generic helper adds the DMA_BUS_MODE offset itself.

* Review hi3531_dwmac_init(), which prepares the shared Ethernet hardware before generic stmmac initialization. Understand its three substantive responsibilities: validate the clock state inherited from U-Boot, reset all three physical DMA channels, and replace the shared TNK interrupt mask so only GMAC1 and DMA channel 1 can interrupt Linux.
