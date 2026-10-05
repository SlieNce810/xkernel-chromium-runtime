#!/usr/bin/env bash
# build_shims.sh — 编译两个 LD_PRELOAD shim + **多库符号覆盖自证** + 打包
#
# 背景（为什么必须有符号自证）
# --------------------------
# LD_PRELOAD 是**逐符号**解析：shim 有的名字走 shim，shim 没有的**静默回退到真库**，
# 真库拿到 shim 的假句柄就会出错。本项目已因此失败过一轮：
#   libseat shim v5 缺 libseat_switch_session / set_log_handler / set_log_level
#   ⇒ weston 在 switch_session 上失败 ⇒ 报 "could not open DRM device"
#   ⇒ libseat_open_device 从未被调用。
#
# 且 consumer 的引用是**带符号版本**的（Alpine 的 libudev 用 `LIBUDEV_183`），
# 所以 shim 也必须用 version script 把符号导出成同一版本，
# 比较时必须 strip 掉 `@版本` 后缀再比。
#
# 两个 shim
#   libseat-shim.so — 绕过 libseat 后端（open_seat 给假 seat、open_device 直接 open）
#                     （libseat 的符号**无版本**，直接用）
#   libudev-shim.so — 绕过 libudev 的 sysfs 依赖（Weston 14 先用 udev 查
#                     /sys/class/drm 才肯去开设备；本 guest 没有 /sys/class/drm）
#                     用 version script 导出为 LIBUDEV_183
#
# 用法（在 T490 上）：bash build_shims.sh
set -euo pipefail

XK6="$HOME/xk6"
SRCDIR="$XK6/scripts/t490"
IMG="$HOME/x-kernel/images/agentos-weston.img"
PKG="$XK6/tmp/shims.tar.gz"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export PATH="$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"

echo "=== 1. 编译两个 shim ==="
aarch64-linux-musl-gcc -shared -fPIC -O2 -Wall \
    -o "$XK6/tmp/libseat-shim.so" "$SRCDIR/libseat_shim.c" -lpthread
aarch64-linux-musl-gcc -shared -fPIC -O2 -Wall \
    -Wl,--version-script="$SRCDIR/libudev_shim.map" \
    -o "$XK6/tmp/libudev-shim.so" "$SRCDIR/libudev_shim.c"
ls -l "$XK6/tmp/libseat-shim.so" "$XK6/tmp/libudev-shim.so"

echo "--- 版本自证：udev shim 的符号应带 @@LIBUDEV_183 ---"
readelf --dyn-syms -W "$XK6/tmp/libudev-shim.so" | grep -c '@@LIBUDEV_183' || true
readelf --dyn-syms -W "$XK6/tmp/libudev-shim.so" | grep 'udev_new\|udev_device_get_devnode' | head -4
echo "COMPILE_OK"

echo "=== 2. 提取消费者库（从被测镜像；注意 Alpine 的库多为符号链接，需要真实文件名）==="
for cand in \
    usr/lib/libweston-14/drm-backend.so \
    usr/lib/libweston-14.so.0 \
    usr/lib/libinput.so.10 \
    usr/lib/libinput.so.10.0.0 \
    usr/lib/libinput.so.10.5.0 ; do
    name="$(basename "$cand")"
    [ -s "$TMP/$name" ] && continue
    debugfs -R "dump /$cand $TMP/$name" "$IMG" >/dev/null 2>&1 || true
    if [ -s "$TMP/$name" ] && head -c 4 "$TMP/$name" | grep -q $'\x7fELF'; then
        echo "  OK  $name ($(stat -c %s "$TMP/$name") bytes)"
    else
        rm -f "$TMP/$name"
        echo "  --  $name 未取到（跳过）"
    fi
done

# 提供集（strip 版本后缀）
readelf --dyn-syms -W "$XK6/tmp/libseat-shim.so" \
    | awk '$4=="FUNC" && $5=="GLOBAL" && $7!="UND" {print $8}' | sed 's/@.*//' | sort -u > "$TMP/prov_seat.txt"
readelf --dyn-syms -W "$XK6/tmp/libudev-shim.so" \
    | awk '$4=="FUNC" && $5=="GLOBAL" && $7!="UND" {print $8}' | sed 's/@.*//' | sort -u > "$TMP/prov_udev.txt"
echo "  提供集：libseat=$(wc -l < "$TMP/prov_seat.txt") 个 / libudev=$(wc -l < "$TMP/prov_udev.txt") 个"

FAIL=0
echo "=== 3. 符号覆盖断言（引用集 ⊆ 提供集，strip 版本后比较）==="
for so in "$TMP"/*.so; do
    [ -f "$so" ] || continue
    base="$(basename "$so")"
    # libseat 家族
    readelf --dyn-syms -W "$so" | awk '$8 ~ /^libseat_/ && $7=="UND" {print $8}' | sed 's/@.*//' | sort -u > "$TMP/ref_seat.txt"
    n=$(wc -l < "$TMP/ref_seat.txt")
    if [ "$n" -gt 0 ]; then
        miss="$(comm -23 "$TMP/ref_seat.txt" "$TMP/prov_seat.txt" || true)"
        if [ -n "$miss" ]; then
            echo "!! $base 引用了 libseat-shim 未提供的符号："; echo "$miss" | sed 's/^/     /'; FAIL=1
        else
            echo "  OK  $base 的 libseat 符号（$n 个）全部覆盖"
        fi
    fi
    # udev 家族
    readelf --dyn-syms -W "$so" | awk '$8 ~ /^udev_/ && $7=="UND" {print $8}' | sed 's/@.*//' | sort -u > "$TMP/ref_udev.txt"
    n=$(wc -l < "$TMP/ref_udev.txt")
    if [ "$n" -gt 0 ]; then
        miss="$(comm -23 "$TMP/ref_udev.txt" "$TMP/prov_udev.txt" || true)"
        if [ -n "$miss" ]; then
            echo "!! $base 引用了 libudev-shim 未提供的符号："; echo "$miss" | sed 's/^/     /'; FAIL=1
        else
            echo "  OK  $base 的 udev 符号（$n 个）全部覆盖"
        fi
    fi
done

if [ "$FAIL" -ne 0 ]; then
    echo "!! 符号覆盖不完整 —— 禁止起会话（否则会以'设备打不开'的假象再次失败）"
    exit 1
fi
echo "SYMBOL_COVERAGE_OK"

echo "=== 4. 打包（两个 shim 一起）==="
rm -rf "$XK6/tmp/shims-pkg"
mkdir -p "$XK6/tmp/shims-pkg"
cp -f "$XK6/tmp/libseat-shim.so" "$XK6/tmp/libudev-shim.so" "$XK6/tmp/shims-pkg/"
tar -czf "$PKG" -C "$XK6/tmp/shims-pkg" libseat-shim.so libudev-shim.so
tar -tzf "$PKG"
ls -l "$PKG"
echo "SHIMS_BUILD_DONE"
