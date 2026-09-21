#!/usr/bin/env bash
# T490 宿主机：apk.static 3.0.8 --usermode 跨架构装 v3.17 weston10 + fbdev
exec > /mnt/e/02_competition/中电杯/tmp/t490_weston10b.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'set -e
cd ~/xk6/tmp
MIR17=https://dl-cdn.alpinelinux.org/alpine/v3.17
APK=~/xk6/tmp/apkstatic/sbin/apk.static
rm -rf rootfs-w10 && mkdir -p rootfs-w10
$APK --usermode --arch aarch64 --root ~/xk6/tmp/rootfs-w10 \
     --repository "$MIR17/main" --repository "$MIR17/community" \
     --allow-untrusted --no-scripts --initdb \
     add weston weston-backend-fbdev 2>&1 | tail -30
echo "=== 结果 ==="
file ~/xk6/tmp/rootfs-w10/usr/bin/weston 2>/dev/null | head -1
ls -la ~/xk6/tmp/rootfs-w10/usr/lib/libweston-*/ 2>/dev/null | head -25
du -sh ~/xk6/tmp/rootfs-w10 2>/dev/null
echo "=== weston 版本 ==="
grep -a "weston" ~/xk6/tmp/rootfs-w10/lib/apk/db/installed 2>/dev/null | grep -a "^P:" | head -10 || true'
echo T490_WESTON10B_DONE
