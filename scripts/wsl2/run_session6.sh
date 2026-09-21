#!/usr/bin/env bash
# WSL2 会话 6（过夜）：autorun v4.1（weston→sync→chromium→sync），6 小时长跑
exec > /mnt/e/02_competition/中电杯/tmp/run_session6.log 2>&1
set -x
export PATH="$HOME/qemu-8.2.3/bin:$PATH"
cd /mnt/e/02_competition/中电杯
python3 scripts/run-session.py \
  --cwd "$HOME/x-kernel" \
  --make-args 'GRAPHIC=y ACCEL=n MEM=4g SMP=4 VSOCK=n' \
  --with-input \
  --duration 21600 --interval 600 --first-shot 60 \
  --out /mnt/e/02_competition/中电杯/evidence/2026-09-20_wsl2-run6
echo "SESSION6_RC=$?"
