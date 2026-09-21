#!/usr/bin/env bash
# WSL2 会话 1：内核启动 → autorun（bootstrap weston → chromium）→ 周期 screendump
exec > /mnt/e/02_competition/中电杯/tmp/run_session1.log 2>&1
set -x
export PATH="$HOME/qemu-8.2.3/bin:$PATH"
qemu-system-aarch64 --version | head -1
cd /mnt/e/02_competition/中电杯
python3 scripts/run-session.py \
  --cwd "$HOME/x-kernel" \
  --make-args 'GRAPHIC=y ACCEL=n MEM=4g SMP=4 VSOCK=n' \
  --with-input \
  --duration 3600 --interval 180 --first-shot 120 \
  --send '240:sh /root/autorun.sh >/tmp/autorun.log 2>&1 &' \
  --out /mnt/e/02_competition/中电杯/evidence/2026-09-20_wsl2-run1
echo "SESSION1_RC=$?"
