#!/usr/bin/env bash
# 会话 5 专用状态检查（路径硬编码，避免 sed 中文/替换坑）
exec > /mnt/e/02_competition/中电杯/tmp/status5.log 2>&1
echo "=== $(date) ==="
pgrep -a -f qemu-system-aarch64 | head -1 || echo NO-QEMU
LOGF="/mnt/e/02_competition/中电杯/evidence/2026-09-20_wsl2-run5/console.log"
echo "--- console.log: $(wc -l < "$LOGF") lines ---"
grep -E 'autorun\]|Installing \(|OK: [0-9]+ MiB|weston|chromium|failed|FAILED|UP ' "$LOGF" | tail -25
echo '--- screenshots ---'
ls /mnt/e/02_competition/中电杯/evidence/2026-09-20_wsl2-run5/screenshots/ | tail -5
