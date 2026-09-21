#!/usr/bin/env bash
# T490: shim v3（有效 get_fd + 详细日志）注入 -> 重启会话
exec > /mnt/e/02_competition/中电杯/tmp/t490_v9.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'pkill -TERM -f qemu-system-aarch64; sleep 5; pgrep -f qemu-system-aarch64 >/dev/null && pkill -KILL -f qemu-system-aarch64; pkill -f run-session.py; sleep 1; cd ~/x-kernel && e2fsck -f -y disk.img 2>&1 | tail -2'
scp -o BatchMode=yes /mnt/e/02_competition/中电杯/scripts/t490/libseat_shim.c mo@10.249.63.140:/home/mo/xk6/scripts/t490/libseat_shim.c
$SSH mo@10.249.63.140 'set -e
export PATH="$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"
cd ~/x-kernel
aarch64-linux-musl-gcc -shared -fPIC -O2 -o /tmp/libseat-shim.so ~/xk6/scripts/t490/libseat_shim.c
debugfs -w -R "rm /usr/local/lib/libseat-shim.so" disk.img >/dev/null 2>&1 || true
debugfs -w -R "write /tmp/libseat-shim.so /usr/local/lib/libseat-shim.so" disk.img
e2fsck -f -y disk.img 2>&1 | tail -2
debugfs -R "stat /usr/local/lib/libseat-shim.so" disk.img 2>/dev/null | grep -E "Size:"'
$SSH mo@10.249.63.140 'setsid -f ~/xk6/scripts/t490/run_session_t490.sh v9-shim3 900 45; echo RELAUNCHED'
echo T490_V9_DONE
