#!/usr/bin/env bash
# 读 weston drm_device_is_kms 实现 + launcher 相关（确定 libudev 需要的属性）
exec > /mnt/e/02_competition/中电杯/tmp/weston_kms_check.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'cd ~/xk6/tmp
echo "=== drm_device_is_kms ==="
LN=$(grep -n "drm_device_is_kms" drm.c | head -1 | cut -d: -f1)
echo "first ref at line $LN"
DEF=$(grep -n "^drm_device_is_kms\|static bool$" drm.c | head -3)
grep -n "drm_device_is_kms" drm.c
# 打印函数定义体
LN2=$(grep -n "bool.*drm_device_is_kms" drm.c | tail -1 | cut -d: -f1)
echo "def line: $LN2"
[ -n "$LN2" ] && sed -n "${LN2},$((LN2 + 45))p" drm.c'
