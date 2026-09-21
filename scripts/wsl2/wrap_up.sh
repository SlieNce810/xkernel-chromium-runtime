#!/usr/bin/env bash
# wrap_up: 会话 5 收尾 —— e2fsck + 检查 chromium 安装状态 + 注入 autorun v4
exec > /mnt/e/02_competition/中电杯/tmp/wrap_up.log 2>&1
set -x
cd "$HOME/x-kernel" || exit 1
pgrep -f qemu-system-aarch64 && { echo 'WARN: qemu still running, skip disk ops'; exit 1; }

echo '=== e2fsck（会话 5 优雅退出后应基本干净）==='
e2fsck -f -y disk.img

echo '=== chromium 是否已装入镜像 ==='
debugfs -R "stat /usr/bin/chromium" disk.img 2>/dev/null | head -6
debugfs -R "stat /usr/lib/chromium/chromium" disk.img 2>/dev/null | head -6
echo '=== apk 包数（world 文件）==='
debugfs -R "cat /etc/apk/world" disk.img 2>/dev/null | tr '\n' ' ' | head -c 800
echo
echo '=== apk 缓存包 ==='
debugfs -R "ls -l /var/cache/apk" disk.img 2>/dev/null | head -12 || true
echo '=== weston 是否在镜像（上次会话装过则这次会话免装）==='
debugfs -R "stat /usr/bin/weston" disk.img 2>/dev/null | head -4

echo '=== 注入 autorun v4 ==='
tr -d '\r' < /mnt/e/02_competition/中电杯/scripts/wsl2/autorun.sh > /tmp/autorun_v4.sh
debugfs -w -R "rm /root/autorun.sh" disk.img
debugfs -w -R "write /tmp/autorun_v4.sh /root/autorun.sh" disk.img
e2fsck -f -y disk.img
echo '=== 最终校验 ==='
debugfs -R "cat /bin/busybox" disk.img 2>/dev/null | head -c 4 | od -A x -t x1z | head -1
debugfs -R "ls -l /root" disk.img 2>/dev/null
echo WRAP_UP_DONE
