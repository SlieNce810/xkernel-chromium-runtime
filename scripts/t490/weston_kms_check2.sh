#!/usr/bin/env bash
# 打印 3557 起的 drm_device_is_kms 函数体
exec > /mnt/e/02_competition/中电杯/tmp/weston_kms_check2.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'cd ~/xk6/tmp && sed -n "3557,3620p" drm.c'
