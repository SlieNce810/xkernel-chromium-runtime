#!/usr/bin/env bash
# 修正 tag：libdrm-2.4.131
exec > /mnt/e/02_competition/中电杯/tmp/libdrm_src2.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'set -e
cd ~/xk6/tmp
curl -fsSL --max-time 40 -o xf86drm.c "https://gitlab.freedesktop.org/mesa/drm/-/raw/libdrm-2.4.131/xf86drm.c"
ls -la xf86drm.c
echo "=== drmGetDevices2 / sysfs 读取点 ==="
grep -n "sys/class/drm\|sys/dev/char\|subsystem\|opendir(\|readdir(" xf86drm.c | head -40
echo "=== drmGetDeviceFromDevId / drmProcessDevice ==="
grep -n "drmGetDeviceFromDevId\|drmProcessDevice\|drm_device_has_rdev\|subsystem " xf86drm.c | head -25'
