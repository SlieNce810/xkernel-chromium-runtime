#!/usr/bin/env bash
# P0-S4: 起验证会话（drmprobe 验证 drmGetVersion 修复）
exec > /mnt/e/02_competition/中电杯/tmp/p0_verify.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'setsid -f ~/xk6/scripts/t490/run_session_t490.sh p0-fix 600 45; echo LAUNCHED'
echo P0_SESSION_STARTED
