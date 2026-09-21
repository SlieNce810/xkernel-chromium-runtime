#!/usr/bin/env bash
# 会话收尾状态 + guest 内日志窥视
exec > /mnt/e/02_competition/中电杯/tmp/t490_state.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
echo "=== 进程 ==="
$SSH mo@10.249.63.140 'ps -eo pid,pcpu,etime,cmd | grep -E "qemu-system|run-session" | grep -v grep | head -3 || echo NO-PROC'
echo "=== console.log 尾部（bootstrap 是否完成）==="
$SSH mo@10.249.63.140 'LOGF=$(ls -t ~/xk6/evidence/*/console.log | head -1); grep -aE "bootstrap rc|weston|VERDICT|drmprobe|sync done" "$LOGF" | tail -20; echo "--- tail 8 ---"; tail -8 "$LOGF"'
echo "=== guest 内 /root/autorun.log（只读窥视）==="
$SSH mo@10.249.63.140 'cd ~/x-kernel && debugfs -R "cat /root/autorun.log" disk.img 2>/dev/null | tail -25'
echo "=== guest 内包状态 ==="
$SSH mo@10.249.63.140 'cd ~/x-kernel && for f in /usr/bin/weston /usr/lib/libweston-14/drm-backend.so /usr/bin/seatd; do echo "-- $f"; debugfs -R "stat $f" disk.img 2>/dev/null | grep -E "Inode:|Size:"; done'
