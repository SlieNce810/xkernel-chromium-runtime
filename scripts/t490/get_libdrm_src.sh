#!/usr/bin/env bash
# 下载 libdrm 源码（xf86drm.c），分析 drmGetDevices2/drmGetDeviceFromDevId 读取的 sysfs 文件
exec > /mnt/e/02_competition/中电杯/tmp/libdrm_src.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'set -e
cd ~/xk6/tmp
# 查 alpine v3.23 的 libdrm 版本
V=$(curl -s --max-time 20 "https://dl-cdn.alpinelinux.org/alpine/v3.23/main/aarch64/" | grep -oE "libdrm-2\.[0-9]+\.[0-9]+" | sort -uV | tail -1)
echo "libdrm version in alpine v3.23: $V"
TAG="libdrm-$V"
for URL in \
  "https://gitlab.freedesktop.org/mesa/drm/-/raw/$TAG/xf86drm.c" \
  "https://raw.githubusercontent.com/freedesktop/mesa-drm/$TAG/xf86drm.c" ; do
  echo "== try $URL"
  if curl -fsSL --max-time 40 -o xf86drm.c "$URL" && [ -s xf86drm.c ]; then echo "OK: $URL"; break; fi
done
ls -la xf86drm.c
echo "=== drmGetDevices2 关键读取点 ==="
grep -n "sys/class/drm\|sys/dev/char\|subsystem\|opendir\|readdir" xf86drm.c | head -30'
