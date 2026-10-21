# SPDX-License-Identifier: GPL-3.0-only
#
# Copyright (C) 2026 szwjp

include $(TOPDIR)/rules.mk

PKG_NAME:=honk
PKG_VERSION:=2026.10.21
PKG_RELEASE:=1

# Pinned honk-core revision (daeuniverse/honk main), cross-compiled by
# ci/build-core.sh. The per-architecture asset/hash are filled by that script;
# keep a committed fallback so the feed still evaluates without a staging run.
CORE_COMMIT:=3188b6b7aa4caa228d94cd3d19abe8062442500d

-include $(CURDIR)/generated-stage.mk

HONK_ASSET_X86_64?=honk-core-$(CORE_COMMIT)-x86_64.tar.gz
HONK_ASSET_AARCH64?=honk-core-$(CORE_COMMIT)-aarch64.tar.gz
HONK_ASSET_ARMV7?=honk-core-$(CORE_COMMIT)-armv7.tar.gz
HONK_HASH_X86_64?=SKIP
HONK_HASH_AARCH64?=SKIP
HONK_HASH_ARMV7?=SKIP

# ARCH_PACKAGES is the package arch (e.g. arm_cortex-a7_neon-vfpv4);
# ARCH is the CPU arch (x86_64/aarch64/arm) and coincides for 64-bit.
ifeq ($(ARCH_PACKAGES),x86_64)
  HONK_ASSET:=$(HONK_ASSET_X86_64)
  HONK_HASH:=$(HONK_HASH_X86_64)
else ifeq ($(filter aarch64%,$(ARCH_PACKAGES)),$(ARCH_PACKAGES))
  HONK_ASSET:=$(HONK_ASSET_AARCH64)
  HONK_HASH:=$(HONK_HASH_AARCH64)
else ifeq ($(filter arm_%,$(ARCH_PACKAGES)),$(ARCH_PACKAGES))
  HONK_ASSET:=$(HONK_ASSET_ARMV7)
  HONK_HASH:=$(HONK_HASH_ARMV7)
endif

# The core is GPL-3.0-only; the package ships that binary.
PKG_LICENSE:=GPL-3.0-only
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=szwjp

PKG_SOURCE:=$(HONK_ASSET)
PKG_SOURCE_URL?=https://github.com/szwjp/luci-app-honk/releases/download/staging/
PKG_HASH:=$(HONK_HASH)

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/honk
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Web Servers/Proxies
  TITLE:=Honk transparent proxy core
  URL:=https://github.com/daeuniverse/honk
  DEPENDS:=@(x86_64||aarch64||arm) +ca-bundle +ip-full +ubus +kmod-sched-core +kmod-sched-bpf +kmod-veth +kmod-nft-queue +jsonfilter +jshn +sqlite3-cli +libubox +usign +coreutils-stat +v2ray-geoip +v2ray-geosite +@KERNEL_DEBUG_INFO_BTF
endef

define Package/honk/description
  Honk is a transparent proxy core for OpenWrt (x86_64, aarch64, armv7).
endef

define Package/honk/conffiles
/etc/config/honk
/etc/honk/config.dae
/etc/honk/system.dae
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(TAR) -xzf $(DL_DIR)/$(PKG_SOURCE) -C $(PKG_BUILD_DIR) --strip-components=1
endef

define Build/Compile
endef

define Package/honk/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/honk-core $(1)/usr/bin/honk-core

	$(INSTALL_DIR) $(1)/usr/share/licenses/honk
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/LICENSE $(1)/usr/share/licenses/honk/LICENSE

	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) $(CURDIR)/files/honk.config $(1)/etc/config/honk

	$(INSTALL_DIR) $(1)/etc/honk
	$(INSTALL_CONF) $(CURDIR)/files/config.dae $(1)/etc/honk/config.dae
	$(INSTALL_CONF) $(CURDIR)/files/system.dae $(1)/etc/honk/system.dae
	chmod 0444 $(1)/etc/honk/system.dae
	$(INSTALL_DIR) $(1)/etc/honk/state
	chmod 0700 $(1)/etc/honk/state

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) $(CURDIR)/files/honk.init $(1)/etc/init.d/honk
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(CURDIR)/files/90-honk-boot $(1)/etc/uci-defaults/90-honk

	$(INSTALL_DIR) $(1)/usr/share/honk
	$(INSTALL_DATA) $(CURDIR)/files/config.dae $(1)/usr/share/honk/default-config.dae
	$(INSTALL_DATA) $(CURDIR)/generated-provenance.json $(1)/usr/share/honk/provenance.json
	$(INSTALL_BIN) $(CURDIR)/files/control.sh $(1)/usr/share/honk/control.sh
	$(INSTALL_BIN) $(CURDIR)/files/lock.sh $(1)/usr/share/honk/lock.sh
	$(INSTALL_BIN) $(CURDIR)/files/firewall.sh $(1)/usr/share/honk/firewall.sh
	$(INSTALL_BIN) $(CURDIR)/files/lifecycle.sh $(1)/usr/share/honk/lifecycle.sh
	$(INSTALL_BIN) $(CURDIR)/files/maintenance.sh $(1)/usr/share/honk/maintenance.sh
	$(INSTALL_BIN) $(CURDIR)/files/job.sh $(1)/usr/share/honk/job.sh
	$(INSTALL_BIN) $(CURDIR)/files/update.sh $(1)/usr/share/honk/update.sh
	$(INSTALL_BIN) $(CURDIR)/files/redact-log.sh $(1)/usr/share/honk/redact-log.sh
	$(INSTALL_BIN) $(CURDIR)/files/log-level-filter.sh $(1)/usr/share/honk/log-level-filter.sh
	$(INSTALL_DATA) $(CURDIR)/files/log-lines.sh $(1)/usr/share/honk/log-lines.sh
endef

define Package/honk/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
. /usr/share/honk/firewall.sh
port=$(uci -q get honk.main.listen_port)
[ -n "$port" ] || port=9527
honk_firewall_apply "$port" || exit 0
exit 0
endef

define Package/honk/postrm
#!/bin/sh
# postrm runs after the package files are removed, so it must not source
# /usr/share/honk/firewall.sh. Keep the two UCI section names in sync with
# files/firewall.sh.
[ -n "$${IPKG_INSTROOT}" ] && exit 0
if command -v uci >/dev/null 2>&1; then
	uci -q delete firewall.honk_native_api_lan
	uci -q delete firewall.honk_native_api_wan
	uci commit firewall || :
	/etc/init.d/firewall reload >/dev/null 2>&1 || :
fi
exit 0
endef

$(eval $(call BuildPackage,honk))
