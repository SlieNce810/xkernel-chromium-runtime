#!/usr/bin/env bash
# 拉 v15 完整日志并打印 drmprobe v3 段
exec > /mnt/e/02_competition/中电杯/tmp/t490_pull_v15.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
DST=/mnt/e/02_competition/中电杯/tmp/t490-evidence
mkdir -p "$DST"
LOGDIR=$($SSH mo@10.249.63.140 'ls -td ~/xk6/evidence/*/ | head -1' | tr -d '\r')
scp -o BatchMode=yes "mo@10.249.63.140:${LOGDIR}console.log" "$DST/v15-console.log"
echo "pulled $(wc -l < "$DST/v15-console.log") lines"
echo "======== drmprobe v3 全文 ========"
sed -n "/drmprobe v3/,/drmprobe done/p" "$DST/v15-console.log"
