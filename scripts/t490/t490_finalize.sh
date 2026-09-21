#!/usr/bin/env bash
# T490 收尾：停会话 + e2fsck + 冻结调试镜像 + 汇总产物
exec > /mnt/e/02_competition/中电杯/tmp/t490_finalize.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'set -e
pkill -TERM -f qemu-system-aarch64 2>/dev/null || true
sleep 5
pgrep -f qemu-system-aarch64 >/dev/null && pkill -KILL -f qemu-system-aarch64 || true
pkill -f run-session.py 2>/dev/null || true
sleep 1
cd ~/x-kernel

# 1. 一致性修复
echo "=== e2fsck ==="
e2fsck -f -y disk.img 2>&1 | tail -3

# 2. 冻结调试镜像（含全部工具：drmprobe/shim/strace/伪造 sysfs/weston）
mkdir -p images
cp -f disk.img images/dev-t490-debug-baseline.img
sha256sum images/dev-t490-debug-baseline.img
ls -la images/

# 3. 汇总产物清单
echo "=== 内核构建产物 ==="
ls -la xkernel_aarch64-qemu.bin 2>/dev/null
echo "=== 镜像内调试工具 ==="
for f in /drmprobe /usr/local/lib/libseat-shim.so /usr/bin/strace /root/autorun.sh; do
  printf "%-36s " "$f"; debugfs -R "stat $f" disk.img 2>/dev/null | grep -E "^Inode" | head -1 || echo "MISSING"
done
echo "=== 伪造 sysfs（镜像内预置的部分）==="
debugfs -R "ls -l /sys/class/drm/card0" disk.img 2>/dev/null | head -6
echo "=== 证据目录 ==="
ls -d ~/xk6/evidence/*/ | tail -8
echo "=== 证据汇总 ==="
du -sh ~/xk6/evidence 2>/dev/null
find ~/xk6/evidence -name "*.ppm" | wc -l
echo "T490_FINALIZE_OK"'
echo T490_DONE
