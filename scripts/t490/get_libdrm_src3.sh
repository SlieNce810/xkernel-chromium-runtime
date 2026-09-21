#!/usr/bin/env bash
# 读 libdrm 关键函数实现：get_subsystem_type / drmParseSubsystemType / process_device 的各总线分支
exec > /mnt/e/02_competition/中电杯/tmp/libdrm_src3.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'cd ~/xk6/tmp
echo "======== A: get_subsystem_type（3581-3615）========"
sed -n "3581,3615p" xf86drm.c
echo "======== B: drmParseSubsystemType（3617-3645）========"
sed -n "3617,3645p" xf86drm.c
echo "======== C: process_device（4520-4620）========"
sed -n "4520,4620p" xf86drm.c
echo "======== D: drmGetDevices2 开头（4700-4760）========"
sed -n "4700,4760p" xf86drm.c'
