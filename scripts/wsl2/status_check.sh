#!/usr/bin/env bash
# 轮询会话状态：进程 + 串口日志关键行
exec > /mnt/e/02_competition/中电杯/tmp/status_check.log 2>&1
echo "=== $(date) ==="
pgrep -a -f qemu-system-aarch64 | head -2 || echo NO-QEMU
pgrep -a -f run-session.py | head -2 || echo NO-SESSION
LOGF=/mnt/e/02_competition/中电杯/evidence/2026-09-20_wsl2-run4/console.log
if [ -f "$LOGF" ]; then
  echo "--- console.log: $(wc -l < "$LOGF") lines ---"
  grep -E 'autorun\]|xk6-diag\] launch|weston|chromium|Installing \(|OK:' "$LOGF" | tail -30
else
  echo "console.log not ready"
fi
