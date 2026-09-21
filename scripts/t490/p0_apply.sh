#!/usr/bin/env bash
# P0-S2/S3：应用 card0.rs 补丁 + 编译内核
exec > /mnt/e/02_competition/中电杯/tmp/p0_apply.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"

# 0. 停残留 QEMU（改内核前保险）
$SSH mo@10.249.63.140 'pgrep -f qemu-system-aarch64 >/dev/null && { pkill -TERM -f qemu-system-aarch64; sleep 3; } || true'

# 1. 推送补丁脚本
scp -o BatchMode=yes /mnt/e/02_competition/中电杯/scripts/t490/modify_card0.py mo@10.249.63.140:/tmp/modify_card0.py
$SSH mo@10.249.63.140 'sed -i "s/\r$//" /tmp/modify_card0.py'

# 2. 记录基线 + 应用补丁 + 展示 diff
$SSH mo@10.249.63.140 'set -e
cd ~/x-kernel
echo "=== 改动前 git 状态 ==="
git status --short | head -5
echo "=== 应用补丁 ==="
python3 /tmp/modify_card0.py io/drmdevice/src/card0.rs
echo "=== git diff 统计 ==="
git diff --stat
echo "=== git diff（前 80 行）==="
git diff | head -80'

# 3. 编译
$SSH mo@10.249.63.140 'set -e
export PATH="$HOME/.cargo/bin:$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"
cd ~/x-kernel
make build 2>&1 | tail -8
ls -la xkernel_aarch64-qemu.bin
echo P0_BUILD_DONE'
