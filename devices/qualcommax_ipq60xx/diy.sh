#!/bin/bash

shopt -s extglob

SHELL_FOLDER=$(dirname $(readlink -f "$0"))

rm -rf package/boot package/firmware/ipq-wifi target/linux/generic target/linux/qualcommax package/firmware/ath11k-firmware package/kernel/mac80211 package/kernel/nat46

git_clone_path 25.12-nss https://github.com/LiBwrt/openwrt-6.x target/linux/generic target/linux/qualcommax package/boot package/firmware/ipq-wifi package/firmware/ath11k-firmware package/kernel/mac80211 package/kernel/nat46

wget -N https://github.com/LiBwrt/LibWrt/raw/refs/heads/25.12-nss/include/image-commands.mk -P include/
wget -N https://github.com/LiBwrt/LibWrt/raw/refs/heads/25.12-nss/config/Config-ipq.in -P config/
wget -N https://github.com/LiBwrt/LibWrt/raw/refs/heads/25.12-nss/Config.in -P ./

rm -rf feeds/kiddin9/shortcut-fe

git clone https://github.com/qosmio/nss-packages.git package/nss-packages
# OpenWrt 25.12 enables NF_CONNTRACK_CHAIN_EVENTS.  qosmio's legacy 5.15
# compatibility patch removes the notifier_block implementation and selects
# the single-listener API by kernel version alone, which no longer compiles.
# Keep the upstream ECM chain-events implementation for this target.
rm -f package/nss-packages/qca-nss-ecm/patches/0006-treewide-rework-notifier-changes-for-5.15.patch
# LiBwrt's kernel patch restores struct genl_info::userhdr and removes the
# genl_info_userhdr() helper.  Keep nss-clients aligned with that API.
sed -i 's/genl_info_userhdr(info)/info->userhdr/g' \
  package/nss-packages/qca-nss-clients/patches*/0025-nss-clients-add-kernel-6.6-support.patch
git clone https://github.com/qosmio/sqm-scripts-nss.git package/sqm-scripts-nss

sed -i "/ECM_INTERFACE_RAWIP_ENABLE/d"  package/nss-packages/qca-nss-ecm/Makefile
rm -rf package/nss-packages/nss-userspace-oss

sed -i "s/luci uboot-envtools wpad-openssl/luci uboot-envtools wpad-mbedtls/" target/linux/qualcommax/Makefile
