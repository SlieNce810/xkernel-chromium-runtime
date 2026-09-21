#!/usr/bin/env bash
# 会话 6 状态检查
exec > /mnt/e/02_competition/中电杯/tmp/status6.log 2>&1
echo "=== $(date) ==="
pgrep -a -f qemu-system-aarch64 | head -1 | cut -c1-60 || echo NO-QEMU
LOGF="/mnt/e/02_competition/中电杯/evidence/2026-09-20_wsl2-run6/console.log"
echo "--- console.log: $(wc -l < "$LOGF") lines ---"
grep -aE 'autorun\]|Installing \(|OK: [0-9.]+ MiB|weston|chromium|failed|FAILED|UP |sync' "$LOGF" | tail -30
