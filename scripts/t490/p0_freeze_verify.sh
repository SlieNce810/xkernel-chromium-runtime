#!/usr/bin/env bash
# 验证 P0 固化结果
exec > /mnt/e/02_competition/中电杯/tmp/p0_freeze_verify.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'cd ~/x-kernel
echo "--- git log ---"
git log --oneline -3
echo "--- git status ---"
git status --short | head -3
echo "--- tags ---"
git tag | tail -3
echo "--- images ---"
ls -la images/ | tail -3
echo "--- QEMU 进程 ---"
pgrep -c -f qemu-system-aarch64 2>/dev/null || echo 0'
