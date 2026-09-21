#!/usr/bin/env bash
# 精确确认残留进程（排除 grep/ssh 自身）
exec > /mnt/e/02_competition/中电杯/tmp/close_E2.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'echo "--- 精确进程名匹配 ---"
pgrep -a -x qemu-system-aarch64 || echo "无 qemu-system-aarch64 进程"
echo "--- run-session ---"
pgrep -a -f "run-session.py" | grep -v pgrep || echo "无 run-session 进程"
echo "--- 释放量核算 ---"
du -sh ~/xk6/tmp /tmp 2>/dev/null
echo "--- 磁盘 ---"
df -h /home | tail -1
echo "--- 镜像与内核 ---"
ls -la ~/x-kernel/images/ ~/x-kernel/xkernel_aarch64-qemu.bin'
