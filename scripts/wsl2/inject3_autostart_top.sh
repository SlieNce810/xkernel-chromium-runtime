#!/usr/bin/env bash
# inject3: 诊断+autorun 段前移到 99-autostart.sh 开头；原 weston-start 行移除（由 autorun 接管）
exec > /mnt/e/02_competition/中电杯/tmp/inject3.log 2>&1
set -x
cd "$HOME/x-kernel" || exit 1

# 0. 确保 QEMU 已停（debugfs 改镜像时不能有 QEMU 在用）
pgrep -f qemu-system-aarch64 && { pkill -f qemu-system-aarch64; sleep 1; }

# 1. 取原始内容（未注入版）
debugfs -R "cat /etc/profile.d/99-autostart.sh" disk.img 2>/dev/null > /tmp/cur_autostart.sh
# 若当前镜像里已含注入段，回到 git 基线：从 xk-dump 的原始导出恢复
if grep -q 'xk6-diag' /tmp/cur_autostart.sh; then
  cp /mnt/e/02_competition/中电杯/tmp/xk-dump/99-autostart.orig.sh /tmp/cur_autostart.sh
fi

# 2. 生成基础版（去掉 weston-start 行，autorun.sh 全权接管图形启动）
grep -v "start_foreground 'weston-start'" /tmp/cur_autostart.sh \
  | grep -v '^# uapp: weston-start' > /tmp/base_autostart.sh

# 3. diag 块（插入到 export XKKERNEL_AUTOSTART_DONE 之后）
cat > /tmp/diag_block.sh <<'EOF'

# === xk6-diag: 设备节点诊断 + autorun（2026-09-20 WSL2 调试注入，位于最前避免被 return 短路）===
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

awk '
  { print }
  /export XKERNEL_AUTOSTART_DONE=1/ {
    while ((getline line < "/tmp/diag_block.sh") > 0) print line
    close("/tmp/diag_block.sh")
  }
' /tmp/base_autostart.sh > /tmp/new_autostart.sh

# 4. 写回镜像
debugfs -w -R "rm /etc/profile.d/99-autostart.sh" disk.img
debugfs -w -R "write /tmp/new_autostart.sh /etc/profile.d/99-autostart.sh" disk.img
# autorun.sh 重注（前面已 rm+write 流程）
debugfs -w -R "rm /root/autorun.sh" disk.img
debugfs -w -R "write /mnt/e/02_competition/中电杯/scripts/wsl2/autorun.sh /root/autorun.sh" disk.img

# 5. 校验头部
echo '=== 新 99-autostart.sh 头部 35 行 ==='
debugfs -R "cat /etc/profile.d/99-autostart.sh" disk.img 2>/dev/null | head -35
echo '=== weston-start 行是否已移除 ==='
debugfs -R "cat /etc/profile.d/99-autostart.sh" disk.img 2>/dev/null | grep -c 'weston-start' || true
echo INJECT3_DONE
