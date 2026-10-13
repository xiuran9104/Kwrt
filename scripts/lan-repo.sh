#!/bin/bash
#=================================================
# 路由器本地 apk 仓库工具（配合 /etc/apk-local file:// 仓库方案）
#
# 背景：dl.openwrt.ai 的 25.12 树没有 apk 格式索引（只有 ipk/opkg），
# 在线软件源不可用。本方案把本机构建并签名的索引放到路由器上。
#
# 用法:
#   ./scripts/lan-repo.sh sign          # 重新生成并签名全部 feed 索引（构建后跑一次）
#   ./scripts/lan-repo.sh push-index    # 推送索引到路由器
#   ./scripts/lan-repo.sh push htop nano...  # 推送指定 .apk 到路由器后即可安装
#
# 密钥: .apk-lan-keys/lan-repo-ec.pem（首次用 openssl 生成，公钥已装在
#       路由器 /etc/apk/keys/lan-repo-ec.pub.pem）
# 仓库布局: 路由器 /etc/apk-local/<feed>/packages.adb（distfeeds.list 指向）
#=================================================
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROUTER="${ROUTER:-root@10.0.0.1}"
BIN="$ROOT/openwrt/bin/packages/aarch64_cortex-a53"
APK="$ROOT/openwrt/staging_dir/host/bin/apk"
KEY="$ROOT/.apk-lan-keys/lan-repo-ec.pem"
FEEDS="base kiddin9 luci packages routing video"
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
SCP_OPTS=("${SSH_OPTS[@]/#-o/-o}") # 同 ssh 选项

cmd="${1:-help}"; shift || true

case "$cmd" in
sign)
  [ -f "$KEY" ] || { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$KEY"; \
    openssl pkey -in "$KEY" -pubout -out "${KEY%.pem}.pub.pem"; echo "已生成新密钥对（记得把公钥装到路由器 /etc/apk/keys/）"; }
  for d in $FEEDS; do
    (cd "$BIN/$d" && "$APK" --allow-untrusted mkndx --sign-key "$KEY" -o packages.adb.new *.apk \
      && mv packages.adb.new packages.adb && echo "$d: $(ls *.apk | wc -l) 包已索引+签名")
  done
  ;;
push-index)
  ssh "${SSH_OPTS[@]}" "$ROUTER" "mkdir -p $(for d in $FEEDS; do echo -n \"/etc/apk-local/$d \"; done)"
  for d in $FEEDS; do
    scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      "$BIN/$d/packages.adb" "$ROUTER:/etc/apk-local/$d/packages.adb" && echo "$d 索引已推送"
  done
  ;;
push)
  for name in "$@"; do
    found=0
    for d in $BIN/*/; do
      feed=$(basename "$d")
      for f in "$d$name"-*.apk; do
        [ -f "$f" ] || continue
        scp -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
          "$f" "$ROUTER:/etc/apk-local/$feed/" && echo "已推送: $feed/$(basename "$f")"
        found=1
      done
    done
    [ "$found" = 0 ] && echo "未找到 $name 的 .apk（先在 openwrt/ 下编译对应包）"
  done
  ;;
*)
  grep '^#' "$0" | sed 's/^# \{0,1\}//'
  ;;
esac
