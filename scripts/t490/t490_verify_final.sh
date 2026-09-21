#!/usr/bin/env bash
# 验证收尾结果
exec > /mnt/e/02_competition/中电杯/tmp/t490_verify_final.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'cd ~/x-kernel
echo "--- 进程 ---"; pgrep -a -f "qemu-system|run-session" | head -3 || echo "无残留进程"
echo "--- 冻结镜像 ---"; ls -la images/ 2>/dev/null; sha256sum images/*.img 2>/dev/null | head -2
echo "--- 内核产物 ---"; ls -la xkernel_aarch64-qemu.bin
echo "--- 镜像内工具 ---"
for f in /drmprobe /usr/local/lib/libseat-shim.so /usr/bin/strace /root/autorun.sh; do
  printf "%-38s" "$f"
  debugfs -R "stat $f" disk.img 2>/dev/null | grep -c "^Inode" | tr -d "\n"; echo " (1=存在)"
done
echo "--- 证据目录 ---"; ls -d ~/xk6/evidence/*/ 2>/dev/null | tail -6
echo "--- 截图总数 ---"; find ~/xk6/evidence -name "*.ppm" 2>/dev/null | wc -l
echo "--- 证据体积 ---"; du -sh ~/xk6/evidence 2>/dev/null
echo "--- T490 磁盘 ---"; df -h /home | tail -1'
