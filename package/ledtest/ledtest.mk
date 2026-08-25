################################################################################
#
# ledtest
#
################################################################################

LEDTEST_VERSION = 1.0
LEDTEST_SITE = $(BR2_EXTERNAL_LICHEEPI_NANO_PATH)/package/ledtest
LEDTEST_SITE_METHOD = local
LEDTEST_LICENSE = GPL-2.0+
LEDTEST_LICENSE_FILES = ledtest.c

define LEDTEST_BUILD_CMDS
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -o $(@D)/ledtest $(@D)/ledtest.c
endef

define LEDTEST_INSTALL_TARGET_CMDS
	$(INSTALL) -D -m 0755 $(@D)/ledtest $(TARGET_DIR)/usr/bin/ledtest
endef

$(eval $(generic-package))
