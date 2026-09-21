#!/usr/bin/env bash
# 读 drmProcessPlatformDevice / drmParsePlatformFileInfo 确定平台总线所需文件
exec > /mnt/e/02_competition/中电杯/tmp/libdrm_src4.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'cd ~/xk6/tmp
echo "======== drmProcessPlatformDevice ========"
grep -n "drmProcessPlatformDevice\|drmParsePlatformDeviceInfo\|of_node\|compatible" xf86drm.c | head -20
LN=$(grep -n "static drmDevicePtr \*drmProcessPlatformDevice" xf86drm.c | cut -d: -f1 | head -1)
echo "LINE=$LN"
[ -n "$LN" ] && sed -n "${LN},$((LN + 90))p" xf86drm.c
echo "======== drmParseSubsystemType 的 DRM_BUS_FAUX 上下文（faux 分支文件）========"
grep -n "drmProcessFauxDevice" xf86drm.c | head -4
LN2=$(grep -n "static drmDevicePtr \*drmProcessFauxDevice" xf86drm.c | cut -d: -f1 | head -1)
[ -n "$LN2" ] && sed -n "${LN2},$((LN2 + 70))p" xf86drm.c'
