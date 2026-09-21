#!/usr/bin/env bash
# 窥视 guest 内 /root/autorun.log（只读 debugfs，不写镜像）+ QEMU CPU 占用
exec > /mnt/e/02_competition/中电杯/tmp/t490_peek.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
echo "=== QEMU/会话进程 ==="
$SSH mo@10.249.63.140 'ps -eo pid,pcpu,etime,cmd --sort=-pcpu | grep -E "qemu-system|run-session" | grep -v grep | head -5'
echo "=== guest 内 /root/autorun.log（只读窥视，尾部 40 行）==="
$SSH mo@10.249.63.140 'cd ~/x-kernel && debugfs -R "cat /root/autorun.log" disk.img 2>/dev/null | tail -40'
echo "=== guest 内已装包迹象：/usr/bin/weston ==="
$SSH mo@10.249.63.140 'cd ~/x-kernel && debugfs -R "stat /usr/bin/weston" disk.img 2>/dev/null | grep -E "Inode|Size"'
