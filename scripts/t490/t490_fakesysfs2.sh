#!/usr/bin/env bash
# T490: 注入伪造 sysfs + 新 autorun（shim+sysfs 主攻）-> 重启会话
exec > /mnt/e/02_competition/中电杯/tmp/t490_fakesysfs2.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"

scp -o BatchMode=yes /mnt/e/02_competition/中电杯/scripts/t490/autorun_v5.sh mo@10.249.63.140:/tmp/a11.sh

$SSH mo@10.249.63.140 'set -e
cd ~/x-kernel
W=~/xk6/tmp/fakesys
# --- 创建 sysfs 目录树 ---
for d in /sys /sys/class /sys/class/drm /sys/class/drm/card0 /sys/class/drm/card0/device; do
  debugfs -w -R "mkdir $d" disk.img >/dev/null 2>&1 || true
done
# --- 写入伪造文件 ---
inject() {
  debugfs -w -R "rm $2" disk.img >/dev/null 2>&1 || true
  debugfs -w -R "write $1 $2" disk.img >/dev/null 2>&1
}
inject "$W/dev"     /sys/class/drm/card0/dev
inject "$W/uevent"  /sys/class/drm/card0/device/uevent
inject "$W/vendor"  /sys/class/drm/card0/device/vendor
inject "$W/device"  /sys/class/drm/card0/device/device
inject "$W/version" /sys/class/drm/version
# --- autorun v11 ---
sed -i "s/\r$//" /tmp/a11.sh
debugfs -w -R "rm /root/autorun.sh" disk.img >/dev/null 2>&1
debugfs -w -R "write /tmp/a11.sh /root/autorun.sh" disk.img
debugfs -w -R "set_inode_field /root/autorun.sh mode 0100755" disk.img
e2fsck -f -y disk.img 2>&1 | tail -2
echo "=== 伪造 sysfs 校验 ==="
debugfs -R "ls -l /sys/class/drm" disk.img 2>/dev/null
debugfs -R "cat /sys/class/drm/card0/dev" disk.img 2>/dev/null
echo "=== ls -lR /sys/class/drm/card0 ==="
debugfs -R "ls -l /sys/class/drm/card0" disk.img 2>/dev/null
debugfs -R "ls -l /sys/class/drm/card0/device" disk.img 2>/dev/null'
$SSH mo@10.249.63.140 'setsid -f ~/xk6/scripts/t490/run_session_t490.sh v11-sysfs 900 45; echo RELAUNCHED'
echo T490_FAKESYSFS2_DONE
