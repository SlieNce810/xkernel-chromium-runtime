#!/usr/bin/env bash
# shutdown_and_verify: SIGTERM 收掉 QEMU -> e2fsck -> 验证 chromium/weston 是否真实落盘 -> 冻结镜像
exec > /mnt/e/02_competition/中电杯/tmp/shutdown_verify.log 2>&1
set -x
cd "$HOME/x-kernel" || exit 1

# 1. 优雅终止 QEMU（SIGTERM -> QEMU flush block 层退出）
pkill -TERM -f qemu-system-aarch64
sleep 5
pgrep -f qemu-system-aarch64 && { sleep 5; pkill -KILL -f qemu-system-aarch64; sleep 2; }
pgrep -f run-session.py && pkill -f run-session.py
sleep 1

# 2. 一致性修复
e2fsck -f -y disk.img

# 3. 验证 chromium / weston 真实落盘（Size 必须远大于 0）
echo '=== /usr/bin/chromium ==='
debugfs -R "stat /usr/bin/chromium" disk.img 2>/dev/null | grep -E 'Inode|Type|Size'
echo '=== /usr/lib/chromium 主程序 ==='
debugfs -R "stat /usr/lib/chromium/chromium" disk.img 2>/dev/null | grep -E 'Inode|Type|Size'
echo '=== /usr/bin/weston ==='
debugfs -R "stat /usr/bin/weston" disk.img 2>/dev/null | grep -E 'Inode|Type|Size'
echo '=== apk world（已装包清单前 500 字节）==='
debugfs -R "cat /etc/apk/world" disk.img 2>/dev/null | head -c 500
echo
echo '=== 镜像占用 blocks ==='
debugfs -R "stats" disk.img 2>/dev/null | grep -E 'Free blocks|Block count' | head -2

# 4. 冻结镜像（含 weston + chromium 的基线）
mkdir -p images
cp disk.img images/dev-chromium-preinstalled.img
sha256sum images/dev-chromium-preinstalled.img
ls -la images/
echo SHUTDOWN_VERIFY_DONE
