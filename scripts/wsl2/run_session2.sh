#!/usr/bin/env bash
# WSL2 会话 2：autostart 诊断 + weston 重试 + chromium
exec > /mnt/e/02_competition/中电杯/tmp/run_session2.log 2>&1
set -x
export PATH="$HOME/qemu-8.2.3/bin:$PATH"
cd /mnt/e/02_competition/中电杯
python3 scripts/run-session.py \
  --cwd "$HOME/x-kernel" \
  --make-args 'GRAPHIC=y ACCEL=n MEM=4g SMP=4 VSOCK=n' \
  --with-input \
  --duration 2400 --interval 180 --first-shot 90 \
  --out /mnt/e/02_competition/中电杯/evidence/2026-09-20_wsl2-run2
echo "SESSION2_RC=$?"
