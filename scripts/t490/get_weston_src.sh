#!/usr/bin/env bash
# 下载 weston 14 的 drm backend 源码，定位 seat 打开与设备打开逻辑
exec > /mnt/e/02_competition/中电杯/tmp/weston_src.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'set -e
cd ~/xk6/tmp
for URL in \
  "https://gitlab.freedesktop.org/wayland/weston/-/raw/14.0.2/libweston/backend-drm/drm.c" \
  "https://raw.githubusercontent.com/wayland-project/weston/14.0.2/libweston/backend-drm/drm.c" ; do
  echo "== try $URL"
  if curl -fsSL --max-time 40 -o drm.c "$URL" && [ -s drm.c ]; then echo "OK from $URL"; break; fi
done
ls -la drm.c 2>/dev/null || echo "download FAILED"
echo "=== seat 相关逻辑 ==="
grep -n "libseat_open_seat\|libseat_open_device\|seat_initialized\|enable_seat\|could not open DRM device\|no drm device found\|logind D-Bus" drm.c 2>/dev/null | head -40'
