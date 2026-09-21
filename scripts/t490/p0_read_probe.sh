#!/usr/bin/env bash
# P0 验证：读 drmprobe v2 输出（drmGetVersion 修复验证）
exec > /mnt/e/02_competition/中电杯/tmp/p0_drmprobe_result.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'LOGDIR=$(ls -td ~/xk6/evidence/*/ | head -1); echo "LOGDIR=$LOGDIR"
echo "=== drmprobe v2 全文 ==="
sed -n "/drmprobe v2/,/drmprobe done/p" "$LOGDIR/console.log"
echo "=== A5 检查：内核 panic ==="
grep -c "panicked\|Backtrace" "$LOGDIR/console.log" || true'
