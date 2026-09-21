#!/usr/bin/env bash
# 读 4385-4520：drmProcessPlatformDevice + drmProcessFauxDevice 完整实现
exec > /mnt/e/02_competition/中电杯/tmp/libdrm_src5.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'cd ~/xk6/tmp && sed -n "4385,4520p" xf86drm.c'
