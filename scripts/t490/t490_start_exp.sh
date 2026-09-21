#!/usr/bin/env bash
# T490: 重注 autorun v6.2（跳过 apk solver）并启动关键实验会话
exec > /mnt/e/02_competition/中电杯/tmp/t490_start_exp.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"

# 1. 重注 autorun（v6.2）
$SSH mo@10.249.63.140 'cd ~/x-kernel && cp ~/xk6/scripts/t490/autorun_v5.sh /tmp/a62.sh && sed -i "s/\r$//" /tmp/a62.sh && debugfs -w -R "rm /root/autorun.sh" disk.img && debugfs -w -R "write /tmp/a62.sh /root/autorun.sh" disk.img && debugfs -w -R "set_inode_field /root/autorun.sh mode 0100755" disk.img && e2fsck -f -y disk.img 2>&1 | tail -2 && echo "--- 关键段确认 ---" && debugfs -R "cat /root/autorun.sh" disk.img | grep -nE "跳过 bootstrap|install-chromium|LIBSEAT_BACKEND|weston try" | head -8'

# 2. 起会话（30 分钟，每 60s 截图）
$SSH mo@10.249.63.140 'setsid -f ~/xk6/scripts/t490/run_session_t490.sh exp-builtin 1800 60; echo LAUNCHED'
echo T490_START_EXP_DONE
