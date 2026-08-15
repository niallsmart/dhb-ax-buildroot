#
# BR2_EXTERNAL makefile for the DHB_AX board.
#
# Buildroot includes this after its own package infrastructure.  It is empty
# because the board needs no out-of-tree packages; the line below picks them
# up automatically if that ever changes.
#
include $(sort $(wildcard $(BR2_EXTERNAL_DHB_AX_PATH)/package/*/*.mk))
