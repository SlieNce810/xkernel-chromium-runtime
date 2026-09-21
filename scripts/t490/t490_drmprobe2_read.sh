#!/usr/bin/env bash
# 读取 v10 会话里 drmprobe v2 的 libdrm 能力测试结果
exec > /mnt/e/02_competition/中电杯/tmp/t490_drmprobe2.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'LOGDIR=$(ls -td ~/xk6/evidence/*/ | head -1); echo "LOGDIR=$LOGDIR"
echo "=== drmprobe v2 全文 ==="
sed -n "/drmprobe v2/,/drmprobe done/p" "$LOGDIR/console.log" | head -60
echo "=== 或用 autorun.log 里持久化的版本 ==="
cd ~/x-kernel && debugfs -R "cat /root/autorun.log" disk.img 2>/dev/null | sed -n "/drmprobe v2/,/drmprobe done/p" | head -60'
