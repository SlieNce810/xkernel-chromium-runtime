#!/usr/bin/env bash
# inject4: 停 QEMU 后重注 autorun.sh v3（串口可见版）
exec > /mnt/e/02_competition/中电杯/tmp/inject4.log 2>&1
set -x
cd "$HOME/x-kernel" || exit 1
pgrep -f qemu-system-aarch64 && { pkill -f qemu-system-aarch64; sleep 1; }
debugfs -w -R "rm /root/autorun.sh" disk.img
debugfs -w -R "write /mnt/e/02_competition/中电杯/scripts/wsl2/autorun.sh /root/autorun.sh" disk.img
debugfs -R "ls -l /root" disk.img 2>/dev/null
echo INJECT4_DONE
