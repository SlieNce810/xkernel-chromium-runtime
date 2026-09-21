#!/usr/bin/env bash
# inject5: 重注 autorun v4.1（带 sync 阶段）
exec > /mnt/e/02_competition/中电杯/tmp/inject5.log 2>&1
set -x
cd "$HOME/x-kernel" || exit 1
pgrep -f qemu-system-aarch64 && { echo 'WARN: qemu running'; exit 1; }
tr -d '\r' < /mnt/e/02_competition/中电杯/scripts/wsl2/autorun.sh > /tmp/autorun_v41.sh
debugfs -w -R "rm /root/autorun.sh" disk.img
debugfs -w -R "write /tmp/autorun_v41.sh /root/autorun.sh" disk.img
e2fsck -f -y disk.img
debugfs -R "cat /bin/busybox" disk.img 2>/dev/null | head -c 4 | od -A x -t x1z | head -1
echo INJECT5_DONE
