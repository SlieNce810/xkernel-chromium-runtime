#!/usr/bin/env bash
# fix_disk: e2fsck 修复 journal 不一致 + 验证 init 完好 + 重注 autorun（去 CRLF）
exec > /mnt/e/02_competition/中电杯/tmp/fix_disk.log 2>&1
set -x
cd "$HOME/x-kernel" || exit 1
pgrep -f qemu-system-aarch64 && { pkill -f qemu-system-aarch64; sleep 1; }

# 1. 修复文件系统一致性（journal replay + orphan 清理）
e2fsck -f -y disk.img

# 2. 验证 init 镜像完好（ELF magic 应为 7f454c46）
echo '=== /sbin/init stat ==='
debugfs -R "stat /sbin/init" disk.img 2>/dev/null | head -12
echo '=== /sbin/init magic ==='
debugfs -R "cat /sbin/init" disk.img 2>/dev/null | head -c 4 | od -A x -t x1z | head -1
echo '=== /bin/busybox magic ==='
debugfs -R "cat /bin/busybox" disk.img 2>/dev/null | head -c 4 | od -A x -t x1z | head -1

# 3. 重注 autorun.sh（先去 CRLF，写入 /tmp 副本）
tr -d '\r' < /mnt/e/02_competition/中电杯/scripts/wsl2/autorun.sh > /tmp/autorun_lf.sh
debugfs -w -R "rm /root/autorun.sh" disk.img
debugfs -w -R "write /tmp/autorun_lf.sh /root/autorun.sh" disk.img

# 4. 再跑一次 e2fsck 确认 debugfs 写后仍干净
e2fsck -f -y disk.img
echo FIX_DONE
