#!/usr/bin/env bash
# 读 T490 会话 console.log 关键行
exec > /mnt/e/02_competition/中电杯/tmp/t490_s1_progress.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'LOGF=$(ls -t ~/xk6/evidence/*/console.log 2>/dev/null | head -1); echo "LOG=$LOGF"; echo "lines=$(wc -l < "$LOGF")"; echo "=== 关键行 ==="; grep -aE "autorun\]|VERDICT|weston|builtin|seatd|Installing \(|OK: [0-9.]+ MiB" "$LOGF" | tail -45; echo "=== 截图 ==="; ls -la $(dirname "$LOGF")/screenshots/ 2>/dev/null | tail -6'
