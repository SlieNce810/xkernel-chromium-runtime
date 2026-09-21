#!/usr/bin/env bash
# T490: 查构建状态 + 重注 autorun v6（含 builtin 实验）
exec > /mnt/e/02_competition/中电杯/tmp/t490_reinject.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
echo "=== 构建状态 ==="
$SSH mo@10.249.63.140 'echo "DONE=$(grep -c BUILD_T490_DONE ~/xk6/tmp/build_xk.log)  FATAL=$(grep -c FATAL ~/xk6/tmp/build_xk.log)"; tail -6 ~/xk6/tmp/build_xk.log'
echo "=== 重注 autorun v6 ==="
$SSH mo@10.249.63.140 'cd ~/x-kernel && cp ~/xk6/scripts/t490/autorun_v5.sh /tmp/a6.sh && sed -i "s/\r$//" /tmp/a6.sh && debugfs -w -R "rm /root/autorun.sh" disk.img && debugfs -w -R "write /tmp/a6.sh /root/autorun.sh" disk.img && e2fsck -f -y disk.img && echo "--- /root ---" && debugfs -R "ls -l /root" disk.img && echo "--- autorun 关键段落 ---" && debugfs -R "cat /root/autorun.sh" disk.img | grep -n "builtin\|LIBSEAT\|drmprobe\|sync" | head -12'
echo REINJECT_DONE
