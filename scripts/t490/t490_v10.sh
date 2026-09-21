#!/usr/bin/env bash
# T490: 注入 drmprobe v2（动态链接，测 libdrm）+ Alpine aarch64 strace，跑一轮诊断会话
exec > /mnt/e/02_competition/中电杯/tmp/t490_v10.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"

# 1. 停会话
$SSH mo@10.249.63.140 'pkill -TERM -f qemu-system-aarch64; sleep 5; pgrep -f qemu-system-aarch64 >/dev/null && pkill -KILL -f qemu-system-aarch64; pkill -f run-session.py; sleep 1; cd ~/x-kernel && e2fsck -f -y disk.img 2>&1 | tail -2'

# 2. 提取 Alpine aarch64 strace（不走 apk solver）
$SSH mo@10.249.63.140 'set -e
mkdir -p ~/xk6/tmp/apk && cd ~/xk6/tmp/apk
MIRROR=https://dl-cdn.alpinelinux.org/alpine
echo "--- 查 strace 包名 ---"
curl -s --max-time 20 "$MIRROR/v3.23/main/aarch64/" | grep -oE "strace-[0-9][^\"]*\\.apk" | sort -u | head -5
PKG=$(curl -s --max-time 20 "$MIRROR/v3.23/main/aarch64/" | grep -oE "strace-[0-9][^\"]*\\.apk" | sort -u | head -1)
echo "PKG=$PKG"
[ -n "$PKG" ] && curl -fL --max-time 60 -o strace.apk "$MIRROR/v3.23/main/aarch64/$PKG"
ls -la strace.apk 2>/dev/null || echo "strace download FAILED"
mkdir -p unpack && tar -xzf strace.apk -C unpack 2>/dev/null || true
find unpack -name "strace" -type f -exec file {} \; | head -3'

# 3. 编译 drmprobe v2（动态链接，支持 dlopen）
scp -o BatchMode=yes /mnt/e/02_competition/中电杯/scripts/t490/drmprobe.c mo@10.249.63.140:/home/mo/xk6/scripts/t490/drmprobe.c
$SSH mo@10.249.63.140 'set -e
export PATH="$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"
cd ~/x-kernel
aarch64-linux-musl-gcc -Os -o /tmp/drmprobe2 ~/xk6/scripts/t490/drmprobe.c
file /tmp/drmprobe2 | head -1
debugfs -w -R "rm /drmprobe" disk.img >/dev/null 2>&1 || true
debugfs -w -R "write /tmp/drmprobe2 /drmprobe" disk.img
debugfs -w -R "set_inode_field /drmprobe mode 0100755" disk.img
# strace 注入（若下载成功）
if [ -f ~/xk6/tmp/apk/unpack/usr/bin/strace ]; then
  debugfs -w -R "rm /usr/bin/strace" disk.img >/dev/null 2>&1 || true
  debugfs -w -R "write /home/mo/xk6/tmp/apk/unpack/usr/bin/strace /usr/bin/strace" disk.img
  debugfs -w -R "set_inode_field /usr/bin/strace mode 0100755" disk.img
  echo "strace injected"
else
  echo "strace NOT available"
fi
e2fsck -f -y disk.img 2>&1 | tail -2'
echo T490_V10_STAGE1_DONE
