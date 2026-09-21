#!/usr/bin/env bash
# T490: 编译并注入 libseat-shim + 新版 autorun(v7: tty0 修复 + shim 路线) -> 重启会话
exec > /mnt/e/02_competition/中电杯/tmp/t490_v7.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"

# 1. 停会话
$SSH mo@10.249.63.140 'pkill -TERM -f qemu-system-aarch64; sleep 5; pgrep -f qemu-system-aarch64 >/dev/null && pkill -KILL -f qemu-system-aarch64; pkill -f run-session.py; sleep 1; cd ~/x-kernel && e2fsck -f -y disk.img 2>&1 | tail -2'

# 2. 推 shim 源码 + 新 autorun
scp -o BatchMode=yes /mnt/e/02_competition/中电杯/scripts/t490/libseat_shim.c mo@10.249.63.140:/home/mo/xk6/scripts/t490/libseat_shim.c
scp -o BatchMode=yes /mnt/e/02_competition/中电杯/scripts/t490/autorun_v5.sh mo@10.249.63.140:/tmp/a7.sh

# 3. 编译 shim + 注入镜像
$SSH mo@10.249.63.140 'set -e
export PATH="$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"
sed -i "s/\r$//" /tmp/a7.sh
cd ~/x-kernel
# 编译 shim
aarch64-linux-musl-gcc -shared -fPIC -O2 -o /tmp/libseat-shim.so ~/xk6/scripts/t490/libseat_shim.c
file /tmp/libseat-shim.so
# 注入 shim
debugfs -w -R "rm /usr/local/lib/libseat-shim.so" disk.img >/dev/null 2>&1 || true
debugfs -w -R "mkdir /usr/local/lib" disk.img >/dev/null 2>&1 || true
debugfs -w -R "write /tmp/libseat-shim.so /usr/local/lib/libseat-shim.so" disk.img
# 注入 autorun v7
debugfs -w -R "rm /root/autorun.sh" disk.img >/dev/null 2>&1
debugfs -w -R "write /tmp/a7.sh /root/autorun.sh" disk.img
debugfs -w -R "set_inode_field /root/autorun.sh mode 0100755" disk.img
e2fsck -f -y disk.img 2>&1 | tail -2
echo "--- 校验 ---"
debugfs -R "stat /usr/local/lib/libseat-shim.so" disk.img 2>/dev/null | grep -E "Inode:|Size:"
debugfs -R "cat /root/autorun.sh" disk.img 2>/dev/null | grep -cE "tty0|libseat-shim"'

# 4. 重启会话（30 分钟）
$SSH mo@10.249.63.140 'setsid -f ~/xk6/scripts/t490/run_session_t490.sh v7-tty0-shim 1800 60; echo RELAUNCHED'
echo T490_V7_DONE
