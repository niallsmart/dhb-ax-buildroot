// SPDX-License-Identifier: GPL-2.0-only
/*
 * HiSilicon Hi3531 (godnet) USB 2.0 PHY
 *
 * The EHCI and OHCI controllers are stock Synopsys blocks that mainline
 * drives unchanged, but they come out of chip reset with their clock gated
 * and the PHY held in reset, so the generic drivers find nothing.  Two
 * registers bring them up, and both live in windows this port already
 * describes for other peripherals:
 *
 *   CRG      0x200300b8   USB clock enable and the reset request bits
 *   sysctrl  0x20050080   PHY interface configuration
 *
 * The sequence is the vendor 3.0.8 hiusb_start_hcd() from
 * drivers/usb/host/hiusb-godnet.c.  That driver refcounts so that the first
 * of the two controllers starts the PHY and the last stops it; expressing
 * the same thing as a PHY provider gets that behaviour from the USB core
 * instead, which refcounts phy_init() and phy_power_on() across every
 * controller referencing this node.
 */

#include <linux/bitops.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/phy/phy.h>
#include <linux/platform_device.h>

/* CRG, relative to the first reg window. */
#define HI3531_USB_CRG			0x00b8
#define HI3531_USB_AHB_SRST_REQ		BIT(0)
#define HI3531_USBPHY_REQ		BIT(1)
#define HI3531_USBPHY_PORT0_TREQ	BIT(2)
#define HI3531_USBPHY_PORT1_TREQ	BIT(3)
#define HI3531_USB_CTRL_HUB_REG		BIT(4)
#define HI3531_USB_CTRL_UTMI0_REG	BIT(5)
#define HI3531_USB_CTRL_UTMI1_REG	BIT(6)
#define HI3531_USB_CKEN			BIT(7)

#define HI3531_USB_RESETS		(HI3531_USB_AHB_SRST_REQ | \
					 HI3531_USBPHY_REQ | \
					 HI3531_USBPHY_PORT0_TREQ | \
					 HI3531_USBPHY_PORT1_TREQ | \
					 HI3531_USB_CTRL_HUB_REG | \
					 HI3531_USB_CTRL_UTMI0_REG | \
					 HI3531_USB_CTRL_UTMI1_REG)

/* System controller, relative to the second reg window. */
#define HI3531_USB_CFG			0x0080
#define HI3531_WORDINTERFACE		BIT(0)
#define HI3531_ULPI_BYPASS_EN		BIT(3)
#define HI3531_SS_BURST16_EN		BIT(9)
#define HI3531_USBOVR_P_CTRL		BIT(17)

struct hi3531_usb_phy {
	void __iomem *crg;
	void __iomem *sysctrl;
};

static int hi3531_usb_phy_power_on(struct phy *phy)
{
	struct hi3531_usb_phy *priv = phy_get_drvdata(phy);
	u32 val;

	/* Enable the USB clock and release every reset in one write. */
	val = readl(priv->crg + HI3531_USB_CRG);
	val |= HI3531_USB_CKEN;
	val &= ~HI3531_USB_RESETS;
	writel(val, priv->crg + HI3531_USB_CRG);
	udelay(100);

	/*
	 * 8-bit UTMI interface with the ULPI wrapper bypassed.  The vendor
	 * also clears SS_BURST16_EN, commented "disable ehci burst16 mode".
	 */
	val = readl(priv->sysctrl + HI3531_USB_CFG);
	val |= HI3531_ULPI_BYPASS_EN;
	val &= ~(HI3531_WORDINTERFACE | HI3531_SS_BURST16_EN |
		 HI3531_USBOVR_P_CTRL);
	writel(val, priv->sysctrl + HI3531_USB_CFG);
	udelay(100);

	return 0;
}

static int hi3531_usb_phy_power_off(struct phy *phy)
{
	struct hi3531_usb_phy *priv = phy_get_drvdata(phy);
	u32 val;

	val = readl(priv->sysctrl + HI3531_USB_CFG);
	val &= ~HI3531_ULPI_BYPASS_EN;
	val |= HI3531_WORDINTERFACE | HI3531_SS_BURST16_EN |
	       HI3531_USBOVR_P_CTRL;
	writel(val, priv->sysctrl + HI3531_USB_CFG);
	udelay(100);

	val = readl(priv->crg + HI3531_USB_CRG);
	val &= ~HI3531_USB_CKEN;
	val |= HI3531_USB_RESETS;
	writel(val, priv->crg + HI3531_USB_CRG);
	udelay(100);

	return 0;
}

static const struct phy_ops hi3531_usb_phy_ops = {
	.power_on = hi3531_usb_phy_power_on,
	.power_off = hi3531_usb_phy_power_off,
	.owner = THIS_MODULE,
};

static int hi3531_usb_phy_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct phy_provider *provider;
	struct hi3531_usb_phy *priv;
	struct resource *res;
	struct phy *phy;

	priv = devm_kzalloc(dev, sizeof(*priv), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;

	/*
	 * Map both windows without claiming them: the CRG is shared with the
	 * Ethernet and SATA glue, and the system controller with the reboot
	 * and SMP code.
	 */
	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	if (!res)
		return -ENODEV;
	priv->crg = devm_ioremap(dev, res->start, resource_size(res));
	if (!priv->crg)
		return -ENOMEM;

	res = platform_get_resource(pdev, IORESOURCE_MEM, 1);
	if (!res)
		return -ENODEV;
	priv->sysctrl = devm_ioremap(dev, res->start, resource_size(res));
	if (!priv->sysctrl)
		return -ENOMEM;

	phy = devm_phy_create(dev, NULL, &hi3531_usb_phy_ops);
	if (IS_ERR(phy))
		return PTR_ERR(phy);

	phy_set_drvdata(phy, priv);

	provider = devm_of_phy_provider_register(dev, of_phy_simple_xlate);

	return PTR_ERR_OR_ZERO(provider);
}

static const struct of_device_id hi3531_usb_phy_match[] = {
	{ .compatible = "hisilicon,hi3531-usb-phy" },
	{ }
};
MODULE_DEVICE_TABLE(of, hi3531_usb_phy_match);

static struct platform_driver hi3531_usb_phy_driver = {
	.probe = hi3531_usb_phy_probe,
	.driver = {
		.name = "hi3531-usb-phy",
		.of_match_table = hi3531_usb_phy_match,
	},
};
module_platform_driver(hi3531_usb_phy_driver);

MODULE_DESCRIPTION("HiSilicon Hi3531 USB 2.0 PHY");
MODULE_LICENSE("GPL");
