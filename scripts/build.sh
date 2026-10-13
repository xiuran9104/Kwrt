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
# 运行期可找到 conda ncurses/tinfo（如宿主工具执行需要）
export LD_LIBRARY_PATH="$HOME/.local/share/mise/installs/conda-ncurses/$(ls $HOME/.local/share/mise/installs/conda-ncurses | grep -E "^[0-9]" | head -1)/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

echo "==== [4/5] 应用本地定制（配置 + 补丁） ===="
source ../devices/common/settings.ini
export FIRMWARE_REVISION
export TARGET
cp -rf ../devices/common/. ./
cp -rf ../devices/$TARGET/. ./
cp -rf ../devices ./

# 与 CI workflow 一致的 git_clone_path（按分支稀疏克隆并合并/移动到源码树）
git_clone_path() {
  branch="$1" rurl="$2" mv="$3"
  [[ "$mv" != "mv" ]] && shift 2 || shift 3
  rootdir="$PWD"
  tmpdir="$(mktemp -d)" || exit 1
  if [ ${#branch} -lt 10 ]; then
    git clone -b "$branch" --depth 1 --filter=blob:none --sparse "$rurl" "$tmpdir"
    cd "$tmpdir"
  else
    git clone --filter=blob:none --sparse "$rurl" "$tmpdir"
    cd "$tmpdir"
    git checkout $branch
  fi
  git sparse-checkout init --cone
  git sparse-checkout set $@
  [[ "$mv" != "mv" ]] && cp -rn ./* $rootdir/ || mv -n $@/* $rootdir/$@/
  cd $rootdir
}
export -f git_clone_path

bash devices/common/diy.sh
awk '!/^#/ && !seen[$1]++ || /^#/' feeds.conf.default > /tmp/f && mv /tmp/f feeds.conf.default
cp -f devices/common/.config .config
cat devices/$TARGET/.config >> .config
rm -rf package/nss-packages package/sqm-scripts-nss
[ -f devices/$TARGET/diy.sh ] && bash devices/$TARGET/diy.sh || true
# LiBwrt 每轮重克隆 mac80211，其 999-800 补丁内含二级指针 bug，固定 sed 修复（抗上游漂移）
sed -i "s|+\tdev_set_threaded(\\&ar->napi_dev, true);|+\tdev_set_threaded(ar->napi_dev, true);|g" package/kernel/mac80211/patches/nss/ath10k/999-800-ath10k-Add-threaded-napi.patch 2>/dev/null || true
# 与 CI workflow 一致：展平 diy/ 覆盖层进源码树（NSS 支持、自研包等）
cp -Rf ./diy/* ./ || true
# 设备补丁（与 CI workflow Apply patches 逻辑一致）
cp -rn devices/common/patches devices/$TARGET/ 2>/dev/null || true
find devices/$TARGET/patches -maxdepth 1 -name '*.revert.patch' -print0 2>/dev/null | sort -z | xargs -r -0 -I% sh -c 'patch -R -N -p1 -F1 --dry-run -i "%" >/dev/null 2>&1 || patch -N --no-backup-if-mismatch -p1 -F1 -i "%" || echo "WARN: % 已应用或跳过"'
find devices/$TARGET/patches -maxdepth 1 -name '*.patch' ! -name '*.revert.patch' ! -name '*.bin.patch' -print0 2>/dev/null | sort -z | xargs -r -0 -I% sh -c 'patch -R -N -p1 -F1 --dry-run -i "%" >/dev/null 2>&1 || patch -N --no-backup-if-mismatch -p1 -F1 -i "%" || echo "WARN: % 已应用或跳过"'
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
