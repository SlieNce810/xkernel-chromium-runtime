#!/usr/bin/env bash
# WSL2 会话 4：autorun v3（串口可见 + fbdev 兜底）+ chromium
exec > /mnt/e/02_competition/中电杯/tmp/run_session4.log 2>&1
set -x
export PATH="$HOME/qemu-8.2.3/bin:$PATH"
cd /mnt/e/02_competition/中电杯
python3 scripts/run-session.py \
  --cwd "$HOME/x-kernel" \
  --make-args 'GRAPHIC=y ACCEL=n MEM=4g SMP=4 VSOCK=n' \
  --with-input \
  --duration 2400 --interval 120 --first-shot 60 \
  --out /mnt/e/02_competition/中电杯/evidence/2026-09-20_wsl2-run4
echo "SESSION4_RC=$?"
