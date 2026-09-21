#!/usr/bin/env bash
# T490: shim v4（延迟回调）+ autorun v12（运行时伪造 sysfs）-> 重启会话
exec > /mnt/e/02_competition/中电杯/tmp/t490_v12.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'pkill -TERM -f qemu-system-aarch64; sleep 5; pgrep -f qemu-system-aarch64 >/dev/null && pkill -KILL -f qemu-system-aarch64; pkill -f run-session.py; sleep 1; cd ~/x-kernel && e2fsck -f -y disk.img 2>&1 | tail -2'
scp -o BatchMode=yes /mnt/e/02_competition/中电杯/scripts/t490/libseat_shim.c mo@10.249.63.140:/home/mo/xk6/scripts/t490/libseat_shim.c
scp -o BatchMode=yes /mnt/e/02_competition/中电杯/scripts/t490/autorun_v5.sh mo@10.249.63.140:/tmp/a12.sh
$SSH mo@10.249.63.140 'set -e
export PATH="$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"
cd ~/x-kernel
aarch64-linux-musl-gcc -shared -fPIC -O2 -o /tmp/libseat-shim.so ~/xk6/scripts/t490/libseat_shim.c
debugfs -w -R "rm /usr/local/lib/libseat-shim.so" disk.img >/dev/null 2>&1 || true
debugfs -w -R "write /tmp/libseat-shim.so /usr/local/lib/libseat-shim.so" disk.img
sed -i "s/\r$//" /tmp/a12.sh
debugfs -w -R "rm /root/autorun.sh" disk.img >/dev/null 2>&1
debugfs -w -R "write /tmp/a12.sh /root/autorun.sh" disk.img
debugfs -w -R "set_inode_field /root/autorun.sh mode 0100755" disk.img
e2fsck -f -y disk.img 2>&1 | tail -2
debugfs -R "stat /usr/local/lib/libseat-shim.so" disk.img 2>/dev/null | grep Size:
debugfs -R "cat /root/autorun.sh" disk.img 2>/dev/null | grep -c "fake_sysfs"'
$SSH mo@10.249.63.140 'setsid -f ~/xk6/scripts/t490/run_session_t490.sh v12-shim4 900 40; echo RELAUNCHED'
echo T490_V12_DONE
