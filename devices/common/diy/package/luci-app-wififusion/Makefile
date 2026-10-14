# WiFi Fusion —— 双频合一插件
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-wififusion
PKG_VERSION:=1.1.0
PKG_RELEASE:=4
PKG_LICENSE:=MIT
PKG_MAINTAINER:=xiuran9104

LUCI_TITLE:=WiFi Fusion - 双频合一（同 SSID + 802.11k/v 自动漫游）
LUCI_DEPENDS:=+luci-base +usteer
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
