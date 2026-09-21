#!/usr/bin/env bash
# 用户级并行准备：musl-cross 下载 + rustup target + x-kernel clone
# 输出落盘: E:\02_competition\中电杯\tmp\prepare_user.log
exec > /mnt/e/02_competition/中电杯/tmp/prepare_user.log 2>&1
set -x

# ---- 1. musl cross 工具链（musl.cc 可达）----
mkdir -p "$HOME/musl"
cd "$HOME/musl"
if [ ! -x "$HOME/musl/aarch64-linux-musl-cross/bin/aarch64-linux-musl-gcc" ]; then
  curl -fL --connect-timeout 15 --max-time 900 \
    -o aarch64-linux-musl-cross.tgz \
    https://musl.cc/aarch64-linux-musl-cross.tgz \
    || { echo "FATAL: musl-cross download failed"; exit 1; }
  tar -xzf aarch64-linux-musl-cross.tgz -C "$HOME/musl"
fi
"$HOME/musl/aarch64-linux-musl-cross/bin/aarch64-linux-musl-gcc" --version | head -1

# ---- 2. rust target ----
rustup target add aarch64-unknown-none-softfloat
rustup target list --installed

# ---- 3. x-kernel clone（gitee，main 分支）----
if [ ! -d "$HOME/x-kernel" ]; then
  git clone --depth 1 https://gitee.com/openkylin/x-kernel.git "$HOME/x-kernel" \
    || { echo "FATAL: clone failed"; exit 1; }
fi
cd "$HOME/x-kernel" && git log --oneline -1 && git branch --show-current
echo "PREPARE_USER_DONE"
