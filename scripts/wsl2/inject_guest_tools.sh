#!/usr/bin/env bash
# 构建完成后把 autorun.sh 注入 disk.img 的 /root/ 下
exec > /mnt/e/02_competition/中电杯/tmp/inject.log 2>&1
set -x
cd "$HOME/x-kernel" || exit 1
[ -f disk.img ] || { echo "FATAL: disk.img missing"; exit 1; }
debugfs -w -R "write /mnt/e/02_competition/中电杯/scripts/wsl2/autorun.sh /root/autorun.sh" disk.img
debugfs -R "ls -l /root" disk.img
echo INJECT_DONE
