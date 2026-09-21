#!/usr/bin/env bash
# v14: realpath 诊断 + 完整伪造树 -> 验证会话
exec > /mnt/e/02_competition/中电杯/tmp/t490_v14.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'pkill -TERM -f qemu-system-aarch64 2>/dev/null; sleep 5; pgrep -f qemu-system-aarch64 >/dev/null && pkill -KILL -f qemu-system-aarch64 || true; pkill -f run-session.py 2>/dev/null; sleep 1; cd ~/x-kernel && e2fsck -f -y disk.img 2>&1 | tail -2'
scp -o BatchMode=yes /mnt/e/02_competition/中电杯/scripts/t490/autorun_v5.sh mo@10.249.63.140:/tmp/a14.sh
$SSH mo@10.249.63.140 'set -e
cd ~/x-kernel
sed -i "s/\r$//" /tmp/a14.sh
debugfs -w -R "rm /root/autorun.sh" disk.img >/dev/null 2>&1 || true
debugfs -w -R "write /tmp/a14.sh /root/autorun.sh" disk.img
debugfs -w -R "set_inode_field /root/autorun.sh mode 0100755" disk.img
e2fsck -f -y disk.img 2>&1 | tail -2'
$SSH mo@10.249.63.140 'setsid -f ~/xk6/scripts/t490/run_session_t490.sh v14-realpath 900 40; echo RELAUNCHED'
echo T490_V14_DONE
