#!/bin/bash
#=================================================
# 一键构建固件：更新上游 → 应用本地补丁/配置 → 编译
#
# 用法:
#   ./scripts/build.sh            # 增量构建（复用 openwrt/ 树，刷新 feeds）
#   ./scripts/build.sh --fresh    # 全新构建（重新 clone 源码，跟最新上游）
#
# 本地定制存放位置（更新上游后自动保留）:
#   devices/common/settings.ini          版本号 10.01
#   devices/common/.config               全局配置选择（含 --disable-libcc1）
#   devices/qualcommax_ipq60xx/.config   机型配置选择（vantage/quickstart，禁 docker）
#   devices/qualcommax_ipq60xx/patches/999-local-fixes.patch  全部代码修复
#=================================================
set -e
set -o pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-qualcommax_ipq60xx}"
[ "$TARGET" = "--fresh" ] && { TARGET=qualcommax_ipq60xx; FRESH=1; }
[ "${2:-}" = "--fresh" ] && FRESH=1
cd "$ROOT"

echo "==== [1/5] 同步上游最新代码（本地提交自动保留） ===="
git pull --no-rebase upstream 25.12 2>/dev/null || echo "  (拉取跳过：无远端更新或离线，继续)"

echo "==== [2/5] 准备源码树 ===="
if [ -n "${FRESH:-}" ] && [ -d openwrt ]; then
  echo "  --fresh：备份并重建源码树"
  mv openwrt "openwrt.old.$(date +%s)"
fi
if [ ! -d openwrt ]; then
  git clone https://github.com/openwrt/openwrt -b openwrt-25.12 openwrt
  # 保留旧树的下载缓存，加速全新构建
  OLDEST=$(ls -dt openwrt.old.* 2>/dev/null | head -1)
  [ -n "$OLDEST" ] && cp -rn "$OLDEST/dl" openwrt/ 2>/dev/null || true
fi

echo "==== [3/5] 构建环境检查 ===="
./scripts/setup-build-env.sh
cd openwrt
export PATH="$PWD/.tools/bin:$PATH"

echo "==== [4/5] 应用本地定制（配置 + 补丁） ===="
source ../devices/common/settings.ini
export FIRMWARE_REVISION
export TARGET
cp -rf ../devices/common/. ./
cp -rf ../devices/$TARGET/. ./
cp -rf ../devices ./
bash devices/common/diy.sh
cp -f devices/common/.config .config
cat devices/$TARGET/.config >> .config
[ -f devices/$TARGET/diy.sh ] && bash devices/$TARGET/diy.sh || true
# 与 CI workflow 一致：展平 diy/ 覆盖层进源码树（NSS 支持、自研包等）
cp -Rf ./diy/* ./ || true
# 设备补丁（与 CI workflow Apply patches 逻辑一致）
cp -rn devices/common/patches devices/$TARGET/ 2>/dev/null || true
find devices/$TARGET/patches -maxdepth 1 -name '*.revert.patch' -print0 2>/dev/null | sort -z | xargs -r -0 -I% patch -R -N --no-backup-if-mismatch -p1 -F1 -i '%'
find devices/$TARGET/patches -maxdepth 1 -name '*.patch' ! -name '*.revert.patch' ! -name '*.bin.patch' -print0 2>/dev/null | sort -z | xargs -r -0 -I% patch -N --no-backup-if-mismatch -p1 -F1 -i '%'
make defconfig
# 非无线平台关闭无线驱动（复刻 CI 行为）
if ! echo "$TARGET" | grep -qE 'x86|armsr|bcm27|rockchip|sunxi|amlogic|siflower'; then
  sed -n '/# Wireless Drivers/,/# end of Wireless Drivers/p' .config | sed -e 's/=m/=n/' >> .config
  sed -i "s/\(kmod-qca.*\)=m/\1=n/" .config
  make defconfig
fi

echo "==== [5/5] 编译（$(nproc) 线程） ===="
make -j"$(nproc)" 2>&1 | tail -20 || { echo "编译失败，查看 openwrt/build.log"; exit 1; }
echo
# 产物附加带日期（月日）副本，便于区分每次构建
for f in bin/targets/*/*/*.bin; do
  [ -f "$f" ] && cp -f "$f" "${f%.bin}-$(date +%m%d).bin"
done

echo "==== 完成 ===="
ls -lh bin/targets/*/*/*.bin 2>/dev/null || ls -lh bin/targets/qualcommax/ipq60xx/*.bin
