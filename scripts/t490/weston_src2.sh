#!/usr/bin/env bash
# 打印 weston 14 drm.c 的三段关键逻辑
exec > /mnt/e/02_competition/中电杯/tmp/weston_src2.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'cd ~/xk6/tmp
echo "======== A: could not open DRM device 上下文（3690-3720）========"
sed -n "3690,3720p" drm.c
echo "======== B: seat 检查 / logind 提示（3990-4040）========"
sed -n "3990,4040p" drm.c
echo "======== C: open_device 函数定义位置 ========"
grep -n "^static int\|^static void\|drm_device_open\|open_device\|seat_enabled\|seat_disabled" drm.c | head -40'
