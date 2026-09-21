#!/usr/bin/env bash
# 判断 apk 瓶颈：块 I/O（写盘=解压中）vs 网络（下载中）
exec > /mnt/e/02_competition/中电杯/tmp/t490_bottleneck.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'QP=$(pgrep -f qemu-system-aarch64 | head -1); echo "QEMU pid=$QP"
echo "=== 块 I/O 采样（间隔 10s）==="
A=$(grep -E "^(read|write)_bytes" /proc/$QP/io); sleep 10; B=$(grep -E "^(read|write)_bytes" /proc/$QP/io)
echo "T0: $A"; echo "T1: $B"
echo "=== QEMU 网络连接（是否在下载 apk）==="
ss -tnp 2>/dev/null | grep -E "qemu|ESTAB" | head -8
echo "=== QEMU 累计网络流量（/proc/pid/net/dev 不可用则跳过）==="
cat /proc/$QP/net/dev 2>/dev/null | head -5
echo "=== 会话/日志状态 ==="
ps -eo pid,etime,cmd | grep run-session.py | grep -v grep | head -2
LOGF=$(ls -t ~/xk6/evidence/*/console.log | head -1); echo "log=$LOGF lines=$(wc -l < $LOGF)"
grep -aE "bootstrap rc|Installing|weston|sync done" "$LOGF" | tail -8'
