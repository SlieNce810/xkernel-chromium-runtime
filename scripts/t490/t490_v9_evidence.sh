#!/usr/bin/env bash
# 拉取 v9 会话的完整 shim/weston 证据到本地
exec > /mnt/e/02_competition/中电杯/tmp/t490_v9_evidence.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
DST=/mnt/e/02_competition/中电杯/tmp/t490-evidence
mkdir -p "$DST"
LOGDIR=$($SSH mo@10.249.63.140 'ls -td ~/xk6/evidence/*/ | head -1' | tr -d '\r')
echo "LOGDIR=$LOGDIR"
scp -o BatchMode=yes "mo@10.249.63.140:${LOGDIR}console.log" "$DST/v9-console.log"
echo "=== console.log 里所有 libseat-shim 行 ==="
grep -a "libseat-shim" "$DST/v9-console.log"
echo "=== console.log 里 shim 尝试段前后 20 行 ==="
grep -a -A6 "尝试 3：LD_PRELOAD" "$DST/v9-console.log" | head -30
echo "=== weston-fail-ldpreload-shim.log（含 shim 的 stderr？）==="
$SSH mo@10.249.63.140 'echo "--- weston-fail-ldpreload-shim.log ---"; cat /root/weston-fail-ldpreload-shim.log 2>/dev/null; echo "--- 镜像内该文件 ---"; cd ~/x-kernel && debugfs -R "cat /root/weston-fail-ldpreload-shim.log" disk.img 2>/dev/null'
echo "=== 完整 weston.log（最后一次尝试）==="
$SSH mo@10.249.63.140 'cd ~/x-kernel && debugfs -R "cat /tmp/weston.log" disk.img 2>/dev/null | tail -25'
