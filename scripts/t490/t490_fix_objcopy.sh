#!/usr/bin/env bash
# T490: 补 rust-objcopy（llvm-tools-preview + 软链），重跑 make build
exec > /mnt/e/02_competition/中电杯/tmp/t490_fix_objcopy.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'export PATH="$HOME/.cargo/bin:$PATH"
set -x
echo "=== WSL 对照：无（仅记录 T490 现状）==="
command -v rust-objcopy || echo "rust-objcopy MISSING"

# 1. 优先：rustup 组件 llvm-tools-preview（提供 llvm-objcopy）
rustup component add llvm-tools-preview --toolchain 1.95.0 2>&1 | tail -3
LLVM_BIN=$(find "$HOME/.rustup/toolchains/1.95.0-x86_64-unknown-linux-gnu" -name "llvm-objcopy" 2>/dev/null | head -n1)
echo "llvm-objcopy found at: $LLVM_BIN"
if [ -n "$LLVM_BIN" ]; then
  ln -sf "$LLVM_BIN" "$HOME/.cargo/bin/rust-objcopy"
  "$HOME/.cargo/bin/rust-objcopy" --version | head -1
fi

# 2. 兜底：cargo-binutils（提供真正的 rust-objcopy）——仅当软链不可用时
if ! command -v rust-objcopy >/dev/null 2>&1; then
  echo "fallback: cargo install cargo-binutils"
  cargo install cargo-binutils --locked 2>&1 | tail -5
fi

cd "$HOME/x-kernel"
echo "=== 重跑 make build ==="
make build 2>&1 | tail -20
ls -la xkernel_*.bin xkernel_*.elf 2>/dev/null
echo "BUILD_RETRY_DONE"' 
echo T490_FIX_DONE
