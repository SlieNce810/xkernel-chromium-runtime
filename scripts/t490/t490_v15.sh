#!/usr/bin/env bash
# v15: drmprobe v3（含 libudev 探针）注入 -> 验证会话
exec > /mnt/e/02_competition/中电杯/tmp/t490_v15.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'pkill -TERM -f qemu-system-aarch64 2>/dev/null; sleep 5; pgrep -f qemu-system-aarch64 >/dev/null && pkill -KILL -f qemu-system-aarch64 || true; pkill -f run-session.py 2>/dev/null; sleep 1; cd ~/x-kernel && e2fsck -f -y disk.img 2>&1 | tail -2'
scp -o BatchMode=yes /mnt/e/02_competition/中电杯/scripts/t490/drmprobe.c mo@10.249.63.140:/home/mo/xk6/scripts/t490/drmprobe.c
$SSH mo@10.249.63.140 'set -e
export PATH="$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"
cd ~/x-kernel
aarch64-linux-musl-gcc -Os -o /tmp/drmprobe3 ~/xk6/scripts/t490/drmprobe.c
file /tmp/drmprobe3 | head -1
debugfs -w -R "rm /drmprobe" disk.img >/dev/null 2>&1 || true
debugfs -w -R "write /tmp/drmprobe3 /drmprobe" disk.img
debugfs -w -R "set_inode_field /drmprobe mode 0100755" disk.img
e2fsck -f -y disk.img 2>&1 | tail -2'
$SSH mo@10.249.63.140 'setsid -f ~/xk6/scripts/t490/run_session_t490.sh v15-libudev 900 40; echo RELAUNCHED'
echo T490_V15_DONE
