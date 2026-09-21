#!/usr/bin/env bash
# T490: shim v2 + autorun v8 注入 -> 重启会话
exec > /mnt/e/02_competition/中电杯/tmp/t490_v8.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"

# 1. 停会话
$SSH mo@10.249.63.140 'pkill -TERM -f qemu-system-aarch64; sleep 5; pgrep -f qemu-system-aarch64 >/dev/null && pkill -KILL -f qemu-system-aarch64; pkill -f run-session.py; sleep 1; cd ~/x-kernel && e2fsck -f -y disk.img 2>&1 | tail -2'

# 2. 推 shim v2 + autorun v8
scp -o BatchMode=yes /mnt/e/02_competition/中电杯/scripts/t490/libseat_shim.c mo@10.249.63.140:/home/mo/xk6/scripts/t490/libseat_shim.c
scp -o BatchMode=yes /mnt/e/02_competition/中电杯/scripts/t490/autorun_v5.sh mo@10.249.63.140:/tmp/a8.sh

# 3. 编译 + 注入
$SSH mo@10.249.63.140 'set -e
export PATH="$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"
sed -i "s/\r$//" /tmp/a8.sh
cd ~/x-kernel
aarch64-linux-musl-gcc -shared -fPIC -O2 -o /tmp/libseat-shim.so ~/xk6/scripts/t490/libseat_shim.c
echo "--- shim 导出符号 ---"
aarch64-linux-musl-nm -D /tmp/libseat-shim.so 2>/dev/null | grep -E " T " | head -12 || readelf -sW /tmp/libseat-shim.so | grep -E "FUNC.*GLOBAL" | head -12
debugfs -w -R "rm /usr/local/lib/libseat-shim.so" disk.img >/dev/null 2>&1 || true
debugfs -w -R "write /tmp/libseat-shim.so /usr/local/lib/libseat-shim.so" disk.img
debugfs -w -R "rm /root/autorun.sh" disk.img >/dev/null 2>&1
debugfs -w -R "write /tmp/a8.sh /root/autorun.sh" disk.img
debugfs -w -R "set_inode_field /root/autorun.sh mode 0100755" disk.img
e2fsck -f -y disk.img 2>&1 | tail -2
debugfs -R "stat /usr/local/lib/libseat-shim.so" disk.img 2>/dev/null | grep -E "Size:"'

# 4. 重启会话（30 分钟，60s 截图）
$SSH mo@10.249.63.140 'setsid -f ~/xk6/scripts/t490/run_session_t490.sh v8-shim2 1800 45; echo RELAUNCHED'
echo T490_V8_DONE
