#!/usr/bin/env bash
# T490 宿主机：用 apk-tools-static 跨架构预装 Alpine v3.17 的 weston10 + fbdev backend 到目录
# （v3.17 = weston 10.x，仍保留 fbdev backend；v3.23 = weston 14，已移除）
exec > /mnt/e/02_competition/中电杯/tmp/t490_weston10.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'set -e
cd ~/xk6/tmp
MIR23=https://dl-cdn.alpinelinux.org/alpine/v3.23/main/x86_64
MIR17=https://dl-cdn.alpinelinux.org/alpine/v3.17
# 1. apk-tools-static（宿主机 x86_64 版，用于跨架构装包）
APKT=$(curl -s --max-time 20 "$MIR23/" | grep -oE "apk-tools-static-[0-9][^\"]*\\.apk" | sort -u | head -1)
echo "APKT=$APKT"
curl -fL --max-time 60 -o apk-tools-static.apk "$MIR23/$APKT"
mkdir -p apkstatic && tar -xzf apk-tools-static.apk -C apkstatic
APK=~/xk6/tmp/apkstatic/sbin/apk.static
$APK --version

# 2. 跨架构预装 weston10 + fbdev 到独立 rootfs 目录
rm -rf rootfs-w10
mkdir -p rootfs-w10
$APK --arch aarch64 --root ~/xk6/tmp/rootfs-w10 \
     --repository "$MIR17/main" --repository "$MIR17/community" \
     --allow-untrusted --no-scripts --initdb \
     add weston weston-backend-fbdev 2>&1 | tail -25

# 3. 结果检查
echo "=== weston10 二进制 ==="
file ~/xk6/tmp/rootfs-w10/usr/bin/weston 2>/dev/null | head -1
echo "=== fbdev backend 模块 ==="
ls -la ~/xk6/tmp/rootfs-w10/usr/lib/libweston-*/ 2>/dev/null | head -20
echo "=== 版本 ==="
ls ~/xk6/tmp/rootfs-w10/usr/lib/ | grep -i weston
echo "=== 体积 ==="
du -sh ~/xk6/tmp/rootfs-w10'
echo T490_WESTON10_STAGE1_DONE
