#!/usr/bin/env bash
# T490: 伪造 sysfs（/sys/class/drm/card0 等）-> 让 libdrm 枚举成功 -> shim+weston 打通
exec > /mnt/e/02_competition/中电杯/tmp/t490_fakesysfs.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"

# 1. 停会话
$SSH mo@10.249.63.140 'pkill -TERM -f qemu-system-aarch64; sleep 5; pgrep -f qemu-system-aarch64 >/dev/null && pkill -KILL -f qemu-system-aarch64; pkill -f run-session.py; sleep 1; cd ~/x-kernel && e2fsck -f -y disk.img 2>&1 | tail -2'

# 2. 构造伪造 sysfs 文件（libdrm 的 drmGetDevices2 / drmGetDeviceNameFromFd2 读取的文件）
$SSH mo@10.249.63.140 'set -e
W=~/xk6/tmp/fakesys
rm -rf $W && mkdir -p $W
printf "226:0\n" > $W/dev          # 关键：major:minor
printf "DRIVER=simpledrm\nDEVTYPE=drm_minor\n" > $W/uevent
printf "0x1af4\n" > $W/vendor      # virtio
printf "0x1050\n" > $W/device
printf "drm 1.1.0 simpledrm 1.0.0\n" > $W/version
printf "226:0\n" > $W/card0_dev_plain
ls -la $W'
echo T490_FAKESYSFS_PREPARED
