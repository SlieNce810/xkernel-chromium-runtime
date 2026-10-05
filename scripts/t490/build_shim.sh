#!/usr/bin/env bash
# build_shim.sh — 编译 libseat shim + **符号覆盖自证** + 打包
#
# 为什么要有"符号覆盖自证"这一步
# ------------------------------
# LD_PRELOAD 是**逐符号**解析的：shim 提供了的名字走 shim；shim 没有提供的名字
# **静默回退到真 libseat.so.1**。而真 libseat 拿到的 seat 指针是 shim 的假 seat
# （内部布局完全不同），一调用就出错。
#
# weston4 轮就是这么失败的：shim v5 缺了 libseat_switch_session /
# set_log_handler / set_log_level 三个符号 ⇒ weston 在 switch_session 上失败 ⇒
# 认定设备不可用 ⇒ 报 `could not open DRM device` ⇒ **open_device 从未被调用**
# （shim 日志里只有 open_seat / close_seat，永远等不到 open(...) 那行）。
#
# 所以本脚本把"引用集 ⊆ 提供集"做成机器断言：只要 drm-backend.so 引用了 shim
# 没导出的 libseat 符号，就直接硬失败，不允许带着隐患起会话。
#
# 用法（在 T490 上）：bash build_shim.sh
set -euo pipefail

XK6="$HOME/xk6"
SRC="$XK6/scripts/t490/libseat_shim.c"
IMG="$HOME/x-kernel/images/agentos-weston.img"
OUT="$XK6/tmp/libseat-shim.so"
PKG="$XK6/tmp/shim.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export PATH="$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"

echo "=== 1. 编译 ==="
aarch64-linux-musl-gcc -shared -fPIC -O2 -Wall -o "$OUT" "$SRC" -lpthread
file "$OUT"
echo "COMPILE_OK"

echo "=== 2. 提取引用集（从被测镜像里的 drm-backend.so）==="
debugfs -R "dump /usr/lib/libweston-14/drm-backend.so $TMP/drm-backend.so" "$IMG" >/dev/null 2>&1 || true
[ -s "$TMP/drm-backend.so" ] || { echo "FATAL: 无法从镜像提取 drm-backend.so"; exit 1; }

readelf --dyn-syms -W "$TMP/drm-backend.so" \
    | awk '/libseat_/ && $7=="UND" {print $8}' | sort -u > "$TMP/ref.txt"
readelf --dyn-syms -W "$OUT" \
    | awk '$4=="FUNC" && $5=="GLOBAL" && $7!="UND" {print $8}' | sort -u > "$TMP/prov.txt"

echo "--- drm-backend.so 引用的 libseat 符号（$(wc -l < "$TMP/ref.txt") 个）---"
cat "$TMP/ref.txt"
echo "--- shim 导出的 libseat 符号（$(wc -l < "$TMP/prov.txt") 个）---"
cat "$TMP/prov.txt"

echo "=== 3. 覆盖断言：引用集 ⊆ 提供集 ==="
MISS="$(comm -23 "$TMP/ref.txt" "$TMP/prov.txt" || true)"
if [ -n "$MISS" ]; then
    echo "!! 缺失符号 —— 会被 LD_PRELOAD 静默回退到真 libseat，禁止起会话："
    echo "$MISS"
    exit 1
fi
echo "SYMBOL_COVERAGE_OK（全部引用符号均已提供，不会回退到真 libseat）"

echo "=== 4. 打包 ==="
rm -rf "$XK6/tmp/shim-pkg"
mkdir -p "$XK6/tmp/shim-pkg"
cp -f "$OUT" "$XK6/tmp/shim-pkg/"
tar -czf "$PKG" -C "$XK6/tmp/shim-pkg" libseat-shim.so
ls -l "$PKG"
echo "SHIM_BUILD_DONE"
