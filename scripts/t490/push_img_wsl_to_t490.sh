#!/usr/bin/env bash
# T490: 停会话 -> 从 WSL 推送预装 Weston 的镜像（4GB）
exec > /mnt/e/02_competition/中电杯/tmp/push_img.log 2>&1
set -x
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"

# 1. 停 T490 会话 + e2fsck
$SSH mo@10.249.63.140 'pkill -TERM -f qemu-system-aarch64; sleep 5; pgrep -f qemu-system-aarch64 >/dev/null && pkill -KILL -f qemu-system-aarch64; pkill -f run-session.py; sleep 1; cd ~/x-kernel && e2fsck -f -y disk.img 2>&1 | tail -3; echo "--- df ---"; df -h /home | tail -1'

# 2. 确认 WSL 侧镜像
ls -la "$HOME/x-kernel/images/" 2>/dev/null || echo "WSL images dir missing"

# 3. 传输（4GB）
time scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
  "$HOME/x-kernel/images/dev-chromium-preinstalled.img" \
  mo@10.249.63.140:/tmp/wsl-weston.img

# 4. 校验
$SSH mo@10.249.63.140 'ls -la /tmp/wsl-weston.img; sha256sum /tmp/wsl-weston.img'
sha256sum "$HOME/x-kernel/images/dev-chromium-preinstalled.img" 2>/dev/null
echo PUSH_IMG_DONE
