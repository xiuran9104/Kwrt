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
export PKG_CONFIG_PATH="$HOME/.local/share/mise/installs/conda-ncurses/$(ls $HOME/.local/share/mise/installs/conda-ncurses | grep -E "^[0-9]+\.[0-9]+" | head -1)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

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
# 上游 op-packages 若出现与 quectel-cm 同名重复定义的包目录会导致 Kconfig 自引用死循环，剔除之
rm -rf feeds/kiddin9/quectel_cm_5G package/feeds/kiddin9/quectel_cm_5G
# LiBwrt 0600-1 的 conntrack 段与 coolsnowwolf 613（tcp_no_window_check 系列全部 7 处）完全重复，
# 且 0980-3 与 generic 980（UBI 警告消除）完全重复 → 删冗余段/hunk，抗上游漂移
rm -f target/linux/qualcommax/patches-6.12/0980-3-mtd-silence-UBI-NAND-warnings.patch
python3 - <<'PYFIX' || true
p = 'target/linux/qualcommax/patches-6.12/0600-1-qca-nss-ecm-support-CORE.patch'
try:
    s = open(p).read()
except OSError:
    raise SystemExit(0)
start = s.find('--- a/net/netfilter/nf_conntrack_ecache.c')
end = s.find('--- a/net/ipv4/ip_gre.c')
if start < 0 or end < 0 or end < start or 'tcp_no_window_check' not in s[start:end]:
    raise SystemExit(0)  # 上游形状已变或已修复，跳过
# 仅保留 ecache 段：删除 WARN_ON_ONCE（register_notifier 已改带 -EBUSY 的新形状）
new_ecache = (
    '--- a/net/netfilter/nf_conntrack_ecache.c\n'
    '+++ b/net/netfilter/nf_conntrack_ecache.c\n'
    '@@ -268,7 +268,6 @@ int nf_conntrack_register_notifier(struct net *net,\n'
    ' \tmutex_lock(&nf_ct_ecache_mutex);\n'
    ' \tnotify = rcu_dereference_protected(net->ct.nf_conntrack_event_cb,\n'
    ' \t\t\t\t\t   lockdep_is_held(&nf_ct_ecache_mutex));\n'
    '-\tWARN_ON_ONCE(notify);\n'
    ' \tif (notify != NULL) {\n'
    ' \t\tret = -EBUSY;\n'
    ' \t\tgoto out_unlock;\n'
)
open(p, 'w').write(s[:start] + new_ecache + s[end:])

# br_if.c 段：br_dev_update_stats 与 generic 953（shortcut-fe）完全重复，删 0600-1 的定义块
lines = open(p).read().split('\n')
seg_start = next((i for i, l in enumerate(lines) if l.startswith('--- a/net/bridge/br_if.c')), -1)
if seg_start >= 0:
    seg_end = next(i for i, l in enumerate(lines) if i > seg_start and l.startswith('--- a/'))
    seg = lines[seg_start:seg_end]
    if any(l.startswith('+void br_dev_update_stats(') for l in seg):
        i0 = next(i for i, l in enumerate(seg) if l.startswith('+/* Update bridge statistics'))
        j0 = next(i for i, l in enumerate(seg) if i > i0 and l.startswith('+EXPORT_SYMBOL_GPL(br_dev_update_stats);'))
        if j0 + 1 < len(seg) and seg[j0 + 1].strip() in ('+', ''):
            j0 += 1
        removed = j0 - i0 + 1
        seg[i0:j0 + 1] = []
        # 只调整包含删除块的 hunk（i0 之前最近的 @@ 头），不能动同段其他 hunk
        hdr = max(k for k in range(i0) if seg[k].startswith('@@'))
        seg[hdr] = _re.sub(r' \+(\d+),(\d+) @@', lambda mm: f' +{mm.group(1)},{int(mm.group(2)) - removed} @@', seg[hdr], count=1)
        lines[seg_start:seg_end] = seg
        open(p, 'w').write('\n'.join(lines))
PYFIX
# apk 升级到 3.0.8（上游修复 GCC16 链接问题）；MIRROR_HASH 置 skip 走 gitlab 直连
sed -i "s|^PKG_SOURCE_VERSION:=.*|PKG_SOURCE_VERSION:=44dcdfc255c26a4e19a4a27f66a54169cce5ca72|; s|^PKG_MIRROR_HASH:=.*|PKG_MIRROR_HASH:=skip|; s|^PKG_VERSION=.*|PKG_VERSION=3.0.8|" package/system/apk/Makefile 2>/dev/null || true
rm -f package/system/apk/patches/0001-openwrt-move-layer-db-to-temp-folder.patch package/system/apk/patches/0002-openwrt-wiki-help-link.patch package/system/apk/patches/0011-genhelp-reproducible-gzip.patch
# 与 CI workflow 一致：展平 diy/ 覆盖层进源码树（NSS 支持、自研包等）
cp -Rf ./diy/* ./ || true
# 设备补丁（与 CI workflow Apply patches 逻辑一致）
cp -rn devices/common/patches devices/$TARGET/ 2>/dev/null || true
find devices/$TARGET/patches -maxdepth 1 -name '*.revert.patch' -print0 2>/dev/null | sort -z | xargs -r -0 -I% sh -c 'patch -R -N -p1 -F1 --dry-run -i "%" >/dev/null 2>&1 || patch -N --no-backup-if-mismatch -p1 -F1 -i "%" || echo "WARN: % 已应用或跳过"'
find devices/$TARGET/patches -maxdepth 1 -name '*.patch' ! -name '*.revert.patch' ! -name '*.bin.patch' -print0 2>/dev/null | sort -z | xargs -r -0 -I% sh -c 'patch -R -N -p1 -F1 --dry-run -i "%" >/dev/null 2>&1 || patch -N --no-backup-if-mismatch -p1 -F1 -i "%" || echo "WARN: % 已应用或跳过"'
make defconfig
# apk 3.0.8 原生支持 ~ 版本后缀，保持上游版本格式和 apk 打包方式。
# base-files 手工覆盖 VERSION；将 ~ 后的点去掉并补齐 APK 的 -rN 修订段。
sed -i 's|$(PKG_RELEASE)~$(lastword $(subst -, ,$(REVISION)))|$(PKG_RELEASE)~$(subst .,,$(lastword $(subst -, ,$(REVISION))))-r1|g' \
  package/base-files/Makefile
# 部分第三方 feed 把发布号写进 PKG_VERSION，避免再追加 PKG_RELEASE 后形成 -rN-rN。
find package feeds -type f -name Makefile -exec \
  sed -i -E '/^[[:space:]]*PKG_VERSION[[:space:]]*:?=/ s/-r([0-9]+)$/~\1/' {} +
# 新版 LuCI 将所选语言直接嵌入应用，不再提供旧的独立 ttyd 中文包。
sed -i 's/ +luci-i18n-ttyd-zh-cn//' feeds/kiddin9/luci-app-quickstart/Makefile 2>/dev/null || true
# luci-app-package-manager 页面无限"正在载入视图…"根治：apk 索引缓存(/var/cache/apk,
# tmpfs 重启即空)不完整时，apk query 会对全部远程仓库逐个起 wget(默认 --timeout 60 秒/
# 仓库)，LuCI load() 同步等待即卡死。缓存缺失时改 --no-network 秒回(可用包列表为空、
# 已安装列表不受影响)；缓存齐全时读缓存本就不联网，联网后页面自动"更新列表"预热。
python3 - <<'PYFIX' || true
p = 'feeds/kiddin9/luci-app-package-manager/root/usr/libexec/package-manager-call'
try:
    s = open(p).read()
except OSError:
    raise SystemExit(0)
if '$apk_nonet' in s:
    raise SystemExit(0)  # 已打补丁
anchor = 'ipkg_bin="opkg"\nfi\n'
guard = anchor + '''
# 索引缓存(/var/cache/apk，tmpfs 重启即空)不完整时禁网查询：否则 apk 会对全部远程仓库
# 逐个起 wget(默认 --timeout 60 秒/仓库)，LuCI 页面 load() 同步等待导致无限"正在载入视图…"。
# 禁网时可用包列表为空、已安装列表不受影响；联网后页面自动/手动"更新列表"即预热缓存。
if [ $ipkg_bin = "apk" ]; then
\tnrepo=$(cat /etc/apk/repositories /etc/apk/repositories.d/*.list 2>/dev/null | grep -cv '^[[:space:]]*\\(#\\|$\\)')
\tncache=$(ls /var/cache/apk/APKINDEX.* 2>/dev/null | wc -l)
\t[ "$ncache" -ge "$nrepo" ] || apk_nonet="--no-network"
fi
'''
if anchor not in s:
    print('WARN: package-manager-call 形状已变，跳过 --no-network 补丁')
    raise SystemExit(0)
s = s.replace(anchor, guard, 1)
n = s.count('$ipkg_bin query --fields all')
s = s.replace('$ipkg_bin query --fields all', '$ipkg_bin $apk_nonet query --fields all')
if n != 2:
    print(f'WARN: package-manager-call query 行数异常({n} 处)，请人工核对')
open(p, 'w').write(s)
PYFIX
# my-default-settings 的 Wi-Fi 探测脚本应覆盖 wifi-scripts 源文件，不能由两个 APK 同时拥有。
if [ -f feeds/kiddin9/my-default-settings/files/etc/hotplug.d/ieee80211/10-wifi-detect ]; then
  cp -f feeds/kiddin9/my-default-settings/files/etc/hotplug.d/ieee80211/10-wifi-detect \
    package/network/config/wifi-scripts/files/etc/hotplug.d/ieee80211/10-wifi-detect
  rm -f feeds/kiddin9/my-default-settings/files/etc/hotplug.d/ieee80211/10-wifi-detect
fi
# APK 固件不安装 opkg；第三方 feed 必须在 feeds.conf 中登记才能进入 packages.adb。
sed -i 's/^CONFIG_PACKAGE_opkg=y/# CONFIG_PACKAGE_opkg is not set/' .config
[ -f key-build ] || staging_dir/host/bin/usign -G -s key-build -p key-build.pub

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
