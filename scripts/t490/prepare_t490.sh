#!/usr/bin/env bash
# T490 用户级环境准备（无需 sudo）：
#   A. QEMU 10.2.1 解包到 ~/qemu-root（dpkg -x，绕开系统安装）
#   B. rust 1.95.0 toolchain + 两个 target（x-kernel rust-toolchain.toml 要求）
#   C. clone x-kernel（gitee）
exec > /tmp/prepare_t490.log 2>&1
set -x
export PATH="$HOME/.cargo/bin:$PATH"

# ---------- A. QEMU 用户级解包 ----------
mkdir -p "$HOME/qemu-pkgs" "$HOME/qemu-root"
cd "$HOME/qemu-pkgs"
apt-get download qemu-system-arm qemu-system-common qemu-system-data 2>&1 | tail -3
for d in *.deb; do dpkg -x "$d" "$HOME/qemu-root" 2>/dev/null; done
ls -la "$HOME/qemu-root/usr/bin/" | head -10
QEMU="$HOME/qemu-root/usr/bin/qemu-system-aarch64"
"$QEMU" --version | head -1
echo '=== ldd 缺库检查 ==='
ldd "$QEMU" 2>/dev/null | grep -i 'not found' && echo 'MISSING_LIBS_FOUND' || echo 'ldd OK'

# ---------- B. rust toolchain ----------
rustup toolchain install 1.95.0 --profile minimal 2>&1 | tail -3
rustup target add --toolchain 1.95.0 aarch64-unknown-none-softfloat aarch64-unknown-linux-musl 2>&1 | tail -3
rustup target list --installed --toolchain 1.95.0

# ---------- C. x-kernel ----------
[ -d "$HOME/x-kernel" ] || git clone --depth 1 https://gitee.com/openkylin/x-kernel.git "$HOME/x-kernel"
cd "$HOME/x-kernel" && git log --oneline -1

# ---------- D. 解压 musl（若已传入）----------
if [ -f /tmp/aarch64-linux-musl-cross.tgz ]; then
  mkdir -p "$HOME/musl"
  [ -d "$HOME/musl/aarch64-linux-musl-cross" ] || tar -xzf /tmp/aarch64-linux-musl-cross.tgz -C "$HOME/musl"
  "$HOME/musl/aarch64-linux-musl-cross/bin/aarch64-linux-musl-gcc" --version | head -1
else
  echo 'musl tgz not yet uploaded'
fi

echo PREPARE_T490_DONE
