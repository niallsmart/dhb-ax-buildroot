#
# BR2_EXTERNAL makefile for the DHB_AX board.
#
# Buildroot includes this after its own package infrastructure.
#
include $(sort $(wildcard $(BR2_EXTERNAL_DHB_AX_PATH)/package/*/*.mk))

DHB_AX_SDK_DIR = /opt/dhb-ax-sdk

.PHONY: dhb-ax-sdk
dhb-ax-sdk: sdk
	$(Q)find "$(DHB_AX_SDK_DIR)" -mindepth 1 -delete
	$(Q)tar -xzf "$(BINARIES_DIR)/$(BR2_SDK_PREFIX).tar.gz" \
		-C "$(DHB_AX_SDK_DIR)" --strip-components=1
	$(Q)"$(DHB_AX_SDK_DIR)/relocate-sdk.sh"
	@echo "installed SDK -> $(DHB_AX_SDK_DIR)"
