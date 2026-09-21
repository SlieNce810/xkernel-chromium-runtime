#!/usr/bin/env bash
# 收口A：状态核验（只读）
exec > /mnt/e/02_competition/中电杯/tmp/close_A.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'echo "=== 残留进程 ==="
pgrep -a -f "qemu-system|run-session" || echo "无残留进程"
echo "=== git ==="
cd ~/x-kernel && git log --oneline -2 && echo "--- tags ---" && git tag && echo "--- status ---" && git status --short | head -9
echo "=== 镜像 ==="
ls -la images/ && sha256sum images/*.img
echo "=== 磁盘/临时占用基线 ==="
df -h /home | tail -1
du -sh /tmp/* 2>/dev/null | sort -h | tail -8
echo "=== 证据目录 ==="
ls -d ~/xk6/evidence/*/ | wc -l
ls -d ~/xk6/evidence/*/
echo "=== 证据总体积与截图数 ==="
du -sh ~/xk6/evidence
find ~/xk6/evidence -name "*.ppm" | wc -l'
