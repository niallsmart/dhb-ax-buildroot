// SPDX-License-Identifier: GPL-2.0-only
/*
 * HiSilicon Hi3531 (godnet) DWMAC glue
 *
 * Hi3531 integrates two DWMAC1000 MACs around a shared MDIO block, a
 * three-channel DMA and a TNK/TOE interrupt aggregator.  GMAC1 is the MAC
 * wired to the board's Realtek PHY:
 *
 *   shared MDIO and register base   0x101c0000
 *   GMAC0 control registers         base + 0x0000
 *   GMAC1 control registers         base + 0x4000
 *   DMA channel n                   base + 0x1000 + n * 0x100
 *   TNK interrupt aggregator        base + 0x9000
 *
 * This layout is confirmed against the vendor 3.0.8 stmmac.ko, which derives
 * each MAC base as base + n * 0x4000, software-resets DMA channels at
 * +0x1000, +0x1100 and +0x1200 in turn, and requests a single IRQ 119
 * (GIC SPI 87) for all of them.
 *
 * A one-queue stmmac instance drives hardware channel 1 by pointing
 * priv->dmaaddr at the channel-1 register block and mac_device_info::pcsr at
 * the GMAC1 control block.  priv->ioaddr stays at offset 0 so that the
 * generic MDIO code keeps using the shared MDIO window.  The vendor TNK/TOE
 * acceleration engine is not used.
 */

#include <linux/bitops.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/platform_device.h>

#include "common.h"
#include "stmmac.h"
#include "stmmac_platform.h"

#define HI3531_GMAC1_MAC_OFFSET		0x4000
#define HI3531_GMAC1_DMA_OFFSET		0x0100
#define HI3531_DMA_CHAN_BASE		0x1000
#define HI3531_DMA_CHAN_STRIDE		0x0100
#define HI3531_DMA_CHANNELS		3
#define HI3531_DMA_BUS_MODE_SWR		BIT(0)
#define HI3531_TNK_INTR_STAT		0x9000
#define HI3531_TNK_INTR_EN		0x9004
#define HI3531_TNK_ID			0x900c

/*
 * Aggregator bit assignment, read out of the vendor ISR: DMA channel n
 * reports in bit 2 + n and MAC n reports in bit 5 + n.  The remaining bits
 * (0, 1, 4 and 7) belong to the TOE engine.
 */
#define HI3531_TNK_INTR_DMA_CH1		BIT(3)
#define HI3531_TNK_INTR_GMAC1		BIT(6)
#define HI3531_TNK_INTR_GMAC1_MASK	(HI3531_TNK_INTR_GMAC1 | \
					 HI3531_TNK_INTR_DMA_CH1)

#define HI3531_CRG_TOE_CLK_SRST		0x00cc
#define HI3531_GMAC_IF_RESET		0x00c8
#define HI3531_GMAC_IF_CONFIG		0x00ec
#define HI3531_CRG_MDIO_CLK_ALT		BIT(4)
#define HI3531_GMAC1_IF_RESET		BIT(1)
#define HI3531_GMAC1_IF_SHIFT		16
#define HI3531_GMAC_IF_MASK		0xffff
#define HI3531_GMAC_IF_TX_ENABLE	BIT(2)
#define HI3531_GMAC_IF_LINK		BIT(3)
#define HI3531_GMAC_IF_FULL_DUPLEX	BIT(4)
#define HI3531_GMAC_IF_RGMII		BIT(5)
#define HI3531_GMAC_IF_SPEED_10		0x1
#define HI3531_GMAC_IF_SPEED_100	0x3

struct hi3531_dwmac {
	struct device *dev;
	void __iomem *gmac;
	void __iomem *syscfg;
};

static int hi3531_get_hw_feature(void __iomem *ioaddr,
				 struct dma_features *dma_cap)
{
	/* This pre-3.50 multi-channel integration has no usable CSR58. */
	return -EOPNOTSUPP;
}

static struct mac_device_info *hi3531_dwmac_setup(void *arg)
{
	struct stmmac_priv *priv = arg;
	struct stmmac_dma_ops *dma_ops;
	struct mac_device_info *mac;

	mac = devm_kzalloc(priv->device, sizeof(*mac), GFP_KERNEL);
	if (!mac)
		return NULL;

	dma_ops = devm_kmemdup(priv->device, &dwmac1000_dma_ops,
			       sizeof(*dma_ops), GFP_KERNEL);
	if (!dma_ops)
		return NULL;

	dma_ops->get_hw_feature = hi3531_get_hw_feature;

	priv->hw = mac;
	if (dwmac1000_setup(priv))
		return NULL;

	mac->dma = dma_ops;

	/*
	 * Redirect the two windows that differ from a single-MAC DWMAC1000:
	 * MAC control registers belong to GMAC1, and the DMA registers this
	 * instance owns are those of shared channel 1.  Everything reached
	 * through priv->ioaddr (MDIO) keeps using the shared window.
	 */
	mac->pcsr = priv->ioaddr + HI3531_GMAC1_MAC_OFFSET;
	priv->dmaaddr = priv->ioaddr + HI3531_GMAC1_DMA_OFFSET;

	return mac;
}

/*
 * Interface mode, speed and duplex live in a 16-bit field of a CRG register,
 * one field per MAC, and are sampled while that MAC's interface wrapper is
 * held in reset.  The sequence and the bit assignment below mirror the
 * vendor driver's stmmac_adjust_link().
 */
static void hi3531_fix_mac_speed(void *arg, int speed, unsigned int mode)
{
	struct hi3531_dwmac *dwmac = arg;
	u32 field, old, val;

	field = HI3531_GMAC_IF_LINK | HI3531_GMAC_IF_TX_ENABLE |
		HI3531_GMAC_IF_FULL_DUPLEX | HI3531_GMAC_IF_RGMII;

	switch (speed) {
	case SPEED_1000:
		break;
	case SPEED_100:
		field |= HI3531_GMAC_IF_SPEED_100;
		break;
	case SPEED_10:
		field |= HI3531_GMAC_IF_SPEED_10;
		break;
	default:
		dev_warn(dwmac->dev, "unsupported GMAC1 speed %d\n", speed);
		return;
	}

	old = readl(dwmac->syscfg + HI3531_GMAC_IF_CONFIG);
	val = (old & ~(HI3531_GMAC_IF_MASK << HI3531_GMAC1_IF_SHIFT)) |
		(field << HI3531_GMAC1_IF_SHIFT);

	writel(HI3531_GMAC1_IF_RESET,
	       dwmac->syscfg + HI3531_GMAC_IF_RESET);
	writel(val, dwmac->syscfg + HI3531_GMAC_IF_CONFIG);
	readl(dwmac->syscfg + HI3531_GMAC_IF_CONFIG);
	writel(0, dwmac->syscfg + HI3531_GMAC_IF_RESET);

	dev_info(dwmac->dev, "GMAC1 RGMII speed %d, syscfg %08x -> %08x\n",
		 speed, old, val);
}

/*
 * Reset all three DMA channels, as the vendor driver does at probe.  The SoC
 * reset register does not clear this block, so a kernel started by a warm
 * restart inherits whatever the previous kernel left running.  Resetting only
 * the channel this instance owns is not enough: the receive engine comes up
 * wedged, reporting descriptors unavailable with a current-descriptor
 * register that never latches, and stays that way until the interface is
 * taken down and brought back up.
 */
static int hi3531_reset_dma_channels(struct platform_device *pdev,
				     struct hi3531_dwmac *dwmac)
{
	unsigned int chan;

	for (chan = 0; chan < HI3531_DMA_CHANNELS; chan++) {
		void __iomem *bus_mode = dwmac->gmac + HI3531_DMA_CHAN_BASE +
					 chan * HI3531_DMA_CHAN_STRIDE;
		u32 value;
		int ret;

		writel(HI3531_DMA_BUS_MODE_SWR, bus_mode);

		ret = readl_poll_timeout(bus_mode, value,
					 !(value & HI3531_DMA_BUS_MODE_SWR),
					 100, 100000);
		if (ret) {
			dev_err(&pdev->dev,
				"DMA channel %u stuck in reset (%08x)\n",
				chan, value);
			return ret;
		}
	}

	return 0;
}

static int hi3531_dwmac_init(struct platform_device *pdev, void *arg)
{
	struct hi3531_dwmac *dwmac = arg;
	u32 clk_srst, intr_en, new_intr_en;
	int ret;

	dev_info(&pdev->dev,
		 "GMAC0 ver=%08x GMAC1 ver=%08x TNK id=%08x stat=%08x\n",
		 readl(dwmac->gmac + 0x20),
		 readl(dwmac->gmac + HI3531_GMAC1_MAC_OFFSET + 0x20),
		 readl(dwmac->gmac + HI3531_TNK_ID),
		 readl(dwmac->gmac + HI3531_TNK_INTR_STAT));

	clk_srst = readl(dwmac->syscfg + HI3531_CRG_TOE_CLK_SRST);
	dev_info(&pdev->dev,
		 "CRG cc=%08x interface reset=%08x config=%08x\n",
		 clk_srst,
		 readl(dwmac->syscfg + HI3531_GMAC_IF_RESET),
		 readl(dwmac->syscfg + HI3531_GMAC_IF_CONFIG));

	/*
	 * This driver does not manage the block's clocks or resets; it relies
	 * on the boot loader having released them.  The vendor's
	 * mdio_clk_init() reads this same bit (its TOE_CLK_DEF_100M) and
	 * returns either half the bus clock or a fixed default, so warn when
	 * the MDIO clock is not the bus-derived rate the device tree
	 * describes.
	 */
	if (clk_srst & HI3531_CRG_MDIO_CLK_ALT)
		dev_warn(&pdev->dev,
			 "CRG selects the fixed default MDIO clock, not bus/2\n");

	ret = hi3531_reset_dma_channels(pdev, dwmac);
	if (ret)
		return ret;

	/*
	 * Own the aggregator mask outright instead of OR-ing into it: the
	 * vendor driver enables every source, including the TOE bits nothing
	 * here can service, and only clears them from its remove path.  A
	 * kernel started after the vendor kernel would otherwise inherit
	 * interrupt sources it cannot acknowledge.
	 */
	intr_en = readl(dwmac->gmac + HI3531_TNK_INTR_EN);
	new_intr_en = HI3531_TNK_INTR_GMAC1_MASK;
	writel(new_intr_en, dwmac->gmac + HI3531_TNK_INTR_EN);
	dev_info(&pdev->dev, "TNK interrupt enable %08x -> %08x\n",
		 intr_en, new_intr_en);

	return 0;
}

static void hi3531_dwmac_exit(struct platform_device *pdev, void *arg)
{
	struct hi3531_dwmac *dwmac = arg;

	writel(0, dwmac->gmac + HI3531_TNK_INTR_EN);
}

static int hi3531_dwmac_probe(struct platform_device *pdev)
{
	struct plat_stmmacenet_data *plat;
	struct stmmac_resources res;
	struct hi3531_dwmac *dwmac;
	int ret;

	ret = stmmac_get_platform_resources(pdev, &res);
	if (ret)
		return ret;

	plat = devm_stmmac_probe_config_dt(pdev, res.mac);
	if (IS_ERR(plat))
		return PTR_ERR(plat);

	dwmac = devm_kzalloc(&pdev->dev, sizeof(*dwmac), GFP_KERNEL);
	if (!dwmac)
		return -ENOMEM;

	dwmac->dev = &pdev->dev;
	dwmac->gmac = res.addr;
	dwmac->syscfg = devm_platform_ioremap_resource(pdev, 1);
	if (IS_ERR(dwmac->syscfg))
		return PTR_ERR(dwmac->syscfg);

	plat->bsp_priv = dwmac;
	plat->setup = hi3531_dwmac_setup;
	plat->fix_mac_speed = hi3531_fix_mac_speed;
	plat->init = hi3531_dwmac_init;
	plat->exit = hi3531_dwmac_exit;

	/*
	 * "snps,dwmac-3.40a" turns on checksum insertion, but this
	 * integration reports no usable feature register, so nothing
	 * confirms the engine is present.  Keep it off until a bring-up
	 * measures it; the cost is software checksums.
	 */
	plat->tx_coe = 0;

	return devm_stmmac_pltfr_probe(pdev, plat, &res);
}

static const struct of_device_id hi3531_dwmac_match[] = {
	{ .compatible = "hisilicon,hi3531-dwmac" },
	{ }
};
MODULE_DEVICE_TABLE(of, hi3531_dwmac_match);

static struct platform_driver hi3531_dwmac_driver = {
	.probe = hi3531_dwmac_probe,
	.driver = {
		.name = "hi3531-dwmac",
		.pm = &stmmac_pltfr_pm_ops,
		.of_match_table = hi3531_dwmac_match,
	},
};
module_platform_driver(hi3531_dwmac_driver);

MODULE_DESCRIPTION("HiSilicon Hi3531 DWMAC glue layer");
MODULE_LICENSE("GPL");
