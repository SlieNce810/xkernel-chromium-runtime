#!/usr/bin/env bash
# 读 drmGetDeviceFromDevId 主体（4642-4700）
exec > /mnt/e/02_competition/中电杯/tmp/libdrm_src6.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'cd ~/xk6/tmp && sed -n "4640,4700p" xf86drm.c
echo "=== drmGetNodeType 实现 ==="
LN=$(grep -n "int drmGetNodeType(const char\|drmGetNodeType(const char \*name)" xf86drm.c | head -1 | cut -d: -f1)
[ -n "$LN" ] && sed -n "${LN},$((LN + 25))p" xf86drm.c
echo "=== drmGetMaxNodeName ==="
grep -n -A3 "drmGetMaxNodeName" xf86drm.c | head -8'
