#!/usr/bin/env bash
# 拉 v14 完整日志到本地
exec > /mnt/e/02_competition/中电杯/tmp/t490_pull_v14.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
DST=/mnt/e/02_competition/中电杯/tmp/t490-evidence
mkdir -p "$DST"
LOGDIR=$($SSH mo@10.249.63.140 'ls -td ~/xk6/evidence/*/ | head -1' | tr -d '\r')
scp -o BatchMode=yes "mo@10.249.63.140:${LOGDIR}console.log" "$DST/v14-console.log"
echo "pulled $(wc -l < "$DST/v14-console.log") lines"
