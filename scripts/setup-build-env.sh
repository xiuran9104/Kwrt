#!/bin/bash
#=================================================
# 构建环境自检与修复（mise/conda 工具链，免 sudo）
# 幂等：重复执行安全。由 build.sh 自动调用，也可单独运行。
#=================================================
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MISE_INST=~/.local/share/mise/installs

echo "== 1/4 检查 mise 工具 =="
NEED="conda-gcc-linux-64 conda-gxx-linux-64 conda-sysroot-linux-64 conda-gcc_linux-64 conda-gxx_linux-64"
MISS=0
for t in flex bison swig rsync unzip make cmake ccache jq zlib sysroot-linux-64 gcc-linux-64 gxx-linux-64 llvm-tools; do
  found=0
  for d in "$MISE_INST/$t" "$MISE_INST/conda-$t" "$MISE_INST/$t-"* "$MISE_INST/conda-$t-"*; do
    [ -e "$d" ] && { found=1; break; }
  done
  [ "$found" = "1" ] || { echo "  缺: $t"; MISS=1; }
done
[ $MISS = 1 ] && { echo "请先安装缺失工具，例如:"; echo "  mise use -g conda:sysroot-linux-64 conda:zlib conda:flex conda:bison conda:swig conda:rsync conda:unzip conda:gcc_linux-64 conda:gxx_linux-64 make cmake ccache jq"; exit 1; }
echo "  工具齐全 ✓"

echo "== 2/4 编译器包装脚本 (.tools/bin) =="
GCCV=$(ls $MISE_INST/conda-gcc-linux-64/ | grep -E '^[0-9]' | head -1)
GXXV=$(ls $MISE_INST/conda-gxx-linux-64/ | grep -E '^[0-9]' | head -1)
mkdir -p "$ROOT/openwrt/.tools/bin"
cat > "$ROOT/openwrt/.tools/bin/gcc" <<EOF
#!/bin/sh
exec $MISE_INST/conda-gcc-linux-64/$GCCV/bin/x86_64-conda-linux-gnu-gcc "\$@"
EOF
cat > "$ROOT/openwrt/.tools/bin/g++" <<EOF
#!/bin/sh
exec $MISE_INST/conda-gxx-linux-64/$GXXV/bin/x86_64-conda-linux-gnu-g++ "\$@"
EOF
chmod +x "$ROOT/openwrt/.tools/bin/gcc" "$ROOT/openwrt/.tools/bin/g++"
ln -sf gcc "$ROOT/openwrt/.tools/bin/cc"; ln -sf g++ "$ROOT/openwrt/.tools/bin/c++"
echo "  wrappers ✓ (gcc $GCCV / g++ $GXXV)"

echo "== 3/4 conda sysroot 修复（mise 拆分安装导致的缺库/断链） =="
for ENV in conda-gcc-linux-64/$GCCV conda-gxx-linux-64/$GXXV; do
  SR="$MISE_INST/$ENV/x86_64-conda-linux-gnu/sysroot"
  SRC="$MISE_INST/conda-sysroot-linux-64/$(ls $MISE_INST/conda-sysroot-linux-64/ | grep -E '^[0-9]' | head -1)/x86_64-conda-linux-gnu/sysroot"
  cp -rn "$SRC"/* "$SR/" 2>/dev/null
  ln -sfn /home "$SR/home"
  # ld script 绝对路径修复（幂等：仅当仍是原始 /lib64 形式时改写）
  for f in "$SR/lib64/libc.so" "$SR/lib64/libm.so" "$SR/usr/lib64/libc.so" "$SR/usr/lib64/libm.so"; do
    [ -f "$f" ] && grep -q '^GROUP ( /lib64/' "$f" 2>/dev/null && \
      sed -i "s|/usr/lib64/|$SR/usr/lib64/|g; s| /lib64/| $SR/lib64/|g" "$f"
  done
  echo "  $ENV ✓"
done
# libz 链接（rust 等宿主包 -lz 需要）
Z="$MISE_INST/conda-zlib/$(ls $MISE_INST/conda-zlib/ | grep -E '^[0-9]' | head -1)/lib"
for E in conda-gcc-linux-64/$GCCV conda-gxx-linux-64/$GXXV; do
  mkdir -p "$MISE_INST/$E/lib64"
  ln -sfn "$Z/libz.so" "$MISE_INST/$E/lib64/libz.so"
  ln -sfn "$Z/libz.so.1" "$MISE_INST/$E/lib64/libz.so.1"
done
echo "  libz ✓"

echo "== 4/4 完成 =="
echo "工具链环境就绪。"
