# Tools

* Remove the Justfile

* Get dvr-console.sh to show an error when picocom fails (e.g., because it's already running elsewhere)

# Ethernet Driver

* Revisit hi3531_fix_mac_speed(): it currently always programs the Hi3531 interface-control field for full duplex because the stmmac hook does not pass duplex. The board-specific glue can recover its net_device through dev_get_drvdata(dwmac->dev) and use ndev->phydev->duplex, warning instead of guessing if no valid PHY duplex is available.

* Revisit the hi3531_get_hw_feature() override that suppresses CSR58 capability discovery. CSR58 reads 0x016def37 at all three DMA-channel locations; determine whether this is a valid shared/aliased capability register, validate its advertised features against the hardware, and then consider restoring generic stmmac discovery.

* Refactor hi3531_reset_dma_channels() to call dwmac1000_dma_ops.reset() once for each physical DMA-channel window instead of duplicating the generic reset sequence. Pass dwmac->gmac + channel * 0x100; the generic helper adds the DMA_BUS_MODE offset itself.

* Review hi3531_dwmac_init(), which prepares the shared Ethernet hardware before generic stmmac initialization. Understand its three substantive responsibilities: validate the clock state inherited from U-Boot, reset all three physical DMA channels, and replace the shared TNK interrupt mask so only GMAC1 and DMA channel 1 can interrupt Linux.
