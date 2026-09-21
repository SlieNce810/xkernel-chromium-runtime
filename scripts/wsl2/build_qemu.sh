#!/usr/bin/env bash
# QEMU >= 8.0 源码编译（WSL2 / T490 通用），TCG-only + aarch64-softmmu + slirp(user 网络)
# 输出全部落盘: E:\02_competition\中电杯\tmp\build_qemu.log
exec > /mnt/e/02_competition/中电杯/tmp/build_qemu.log 2>&1
set -x
set -o pipefail

QEMU_VER=8.2.3
PREFIX="$HOME/qemu-$QEMU_VER"
SRC="$HOME/src/qemu-$QEMU_VER"

mkdir -p "$HOME/src"
cd "$HOME/src"

# ---- 1. 获取源码：GitHub git clone（depth1 + 子模块；国内三大镜像站均无 qemu 源码镜像）----
# 注：release tarball 不含 meson/keycodemapdb 子模块，git clone --recurse-submodules 一步到位
# roms/edk2（UEFI 固件源码，aarch64 TCG 不需要）的巨型递归在弱网下常失败 -> 失败不算 fatal，
# 后续 deinit 掉并在 configure 用 ignore 跳过子模块状态检查
SRC="$HOME/src/qemu"
mkdir -p "$HOME/src"
if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "v$QEMU_VER" \
    --recurse-submodules --shallow-submodules --jobs 4 \
    https://github.com/qemu/qemu.git "$SRC" \
    || echo "WARN: clone failed (may be partial), trying to continue with existing tree"
fi

cd "$SRC"

# 核心子模块兜底（meson 是编译系统，缺了必死）
git submodule update --init --depth 1 meson 2>/dev/null || true
# edk2 不需要：deinit 让树状态干净
git submodule deinit -f roms/edk2 2>/dev/null || true

# ---- 3. configure ----
# TCG-only: 不需要 KVM/Xen；aarch64-softmmu 只编一个目标，省一半时间
# --enable-slirp: user-mode 网络必须，否则 guest 里 apk 无法联网
# meson 用源码树子模块（系统 meson 0.61 太旧，QEMU 8.2 需要 >=0.63.3）
./configure \
  --target-list=aarch64-softmmu \
  --prefix="$PREFIX" \
  --enable-slirp \
  --disable-docs \
  --disable-gtk \
  --disable-sdl \
  --disable-opengl \
  --disable-libusb \
  --disable-dbus-display \
  || { echo "FATAL: configure failed"; tail -30 config.log; exit 1; }

# ---- 4. 编译 + 安装 ----
make -j"$(nproc)" || { echo "FATAL: make failed"; exit 1; }
make install || { echo "FATAL: make install failed"; exit 1; }

# ---- 5. 验证 ----
"$PREFIX/bin/qemu-system-aarch64" --version
echo "BUILD_QEMU_DONE"
