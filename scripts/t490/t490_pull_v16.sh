#!/usr/bin/env bash
# 拉 v16 完整日志
exec > /mnt/e/02_competition/中电杯/tmp/t490_pull_v16.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
DST=/mnt/e/02_competition/中电杯/tmp/t490-evidence
LOGDIR=$($SSH mo@10.249.63.140 'ls -td ~/xk6/evidence/*/ | head -1' | tr -d '\r')
scp -o BatchMode=yes "mo@10.249.63.140:${LOGDIR}console.log" "$DST/v16-console.log"
echo "pulled $(wc -l < "$DST/v16-console.log") lines"
# 顺带查 weston-desktop-shell 是否在镜像 + weston 包的 libexec 内容
$SSH mo@10.249.63.140 'cd ~/x-kernel
echo "=== /usr/libexec 内容 ==="
debugfs -R "ls -l /usr/libexec" disk.img 2>/dev/null | head -12'
