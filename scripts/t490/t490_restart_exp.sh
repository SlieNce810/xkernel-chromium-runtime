#!/usr/bin/env bash
# T490: 修正 autorun 路径 + 重启实验会话
exec > /mnt/e/02_competition/中电杯/tmp/t490_restart_exp.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"

# 1. 停当前会话（刚启动，写盘少）
$SSH mo@10.249.63.140 'pkill -TERM -f qemu-system-aarch64; sleep 5; pgrep -f qemu-system-aarch64 >/dev/null && pkill -KILL -f qemu-system-aarch64; pkill -f run-session.py; sleep 1; cd ~/x-kernel && e2fsck -f -y disk.img 2>&1 | tail -2'

# 2. 推最新 autorun 到正确路径（绝对路径，避免 ~ 不被 debugfs 展开）
scp -o BatchMode=yes /mnt/e/02_competition/中电杯/scripts/t490/autorun_v5.sh mo@10.249.63.140:/tmp/a62.sh
$SSH mo@10.249.63.140 'sed -i "s/\r$//" /tmp/a62.sh; cp /tmp/a62.sh /home/mo/xk6/scripts/t490/autorun_v5.sh; echo "checks: $(grep -c "跳过 bootstrap" /tmp/a62.sh) / $(grep -c "install-chromium" /tmp/a62.sh)"'

# 3. 重注镜像
$SSH mo@10.249.63.140 'cd ~/x-kernel && debugfs -w -R "rm /root/autorun.sh" disk.img; debugfs -w -R "write /tmp/a62.sh /root/autorun.sh" disk.img; debugfs -w -R "set_inode_field /root/autorun.sh mode 0100755" disk.img; e2fsck -f -y disk.img 2>&1 | tail -2; echo "注入确认(跳过bootstrap计数): $(debugfs -R "cat /root/autorun.sh" disk.img 2>/dev/null | grep -c "跳过 bootstrap")"'

# 4. 重起会话
$SSH mo@10.249.63.140 'setsid -f ~/xk6/scripts/t490/run_session_t490.sh exp-builtin 1800 60; echo RELAUNCHED'
echo T490_RESTART_DONE
