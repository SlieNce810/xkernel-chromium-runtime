#!/usr/bin/env bash
# 重整 autostart：导出现有 99-autostart.sh -> 追加诊断+autorun -> 写回镜像；同步重注 autorun.sh
exec > /mnt/e/02_competition/中电杯/tmp/inject2.log 2>&1
set -x
cd "$HOME/x-kernel" || exit 1

# 1. 导出现有 autostart 脚本（分析用，同时落盘到工作区）
debugfs -R "cat /etc/profile.d/99-autostart.sh" disk.img 2>/dev/null > /tmp/old_autostart.sh
cp /tmp/old_autostart.sh /mnt/e/02_competition/中电杯/tmp/xk-dump/99-autostart.orig.sh
echo '=== 原始 99-autostart.sh ==='
cat /tmp/old_autostart.sh

# 2. 构造新版：原内容 + 诊断 + autorun（幂等：防止追加段重复）
if grep -q 'xk6-diag' /tmp/old_autostart.sh; then
  echo 'already injected, keep original'
  cp /tmp/old_autostart.sh /tmp/new_autostart.sh
else
  cp /tmp/old_autostart.sh /tmp/new_autostart.sh
  cat >> /tmp/new_autostart.sh <<'EOF'

# === xk6-diag: 设备节点诊断 + autorun（2026-09-20 WSL2 调试注入）===
echo "[xk6-diag] ===== /dev listing ====="
ls -l /dev/ 2>&1 | head -50
echo "[xk6-diag] ===== /dev/dri ====="
ls -l /dev/dri/ 2>&1
echo "[xk6-diag] ===== /dev/input ====="
ls -l /dev/input/ 2>&1
echo "[xk6-diag] ===== /proc/devices (前 40 行) ====="
head -40 /proc/devices 2>&1
echo "[xk6-diag] launching autorun in background"
sh /root/autorun.sh >/tmp/autorun.log 2>&1 &
EOF
fi

# 3. 写回镜像（debugfs write 不能覆盖已存在文件，先 rm 再 write）+ 重注 autorun.sh
debugfs -w -R "rm /etc/profile.d/99-autostart.sh" disk.img
debugfs -w -R "write /tmp/new_autostart.sh /etc/profile.d/99-autostart.sh" disk.img
debugfs -w -R "rm /root/autorun.sh" disk.img
debugfs -w -R "write /mnt/e/02_competition/中电杯/scripts/wsl2/autorun.sh /root/autorun.sh" disk.img

# 4. 校验
echo '=== 校验 99-autostart.sh 尾部 ==='
debugfs -R "cat /etc/profile.d/99-autostart.sh" disk.img 2>/dev/null | tail -20
echo '=== 校验 /root ==='
debugfs -R "ls -l /root" disk.img 2>/dev/null
echo INJECT2_DONE
