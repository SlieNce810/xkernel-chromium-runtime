#!/usr/bin/env bash
# rebuild_disk: 重建 disk.img（rootfs 母本 -> 扩容 -> uapps -> 全部注入 -> e2fsck 收尾）
# 教训：强杀 QEMU 会丢 guest 侧 writeback 数据；以后停机必须优雅，注入后必跑 e2fsck
exec > /mnt/e/02_competition/中电杯/tmp/rebuild_disk.log 2>&1
set -x
set -o pipefail
export PATH="$HOME/musl/aarch64-linux-musl-cross/bin:$HOME/qemu-8.2.3/bin:$PATH"
cd "$HOME/x-kernel" || exit 1
pgrep -f qemu-system-aarch64 && { pkill -f qemu-system-aarch64; sleep 1; }

rustup target add aarch64-unknown-none-softfloat aarch64-unknown-linux-musl

# ---- 1. 新 disk.img（母本 x-kernel-alpine-busybox-aarch64.img 未被 QEMU 写过，复用）----
rm -f disk.img
make rootfs ROOTFS_VARIANT=alpine-busybox || { echo "FATAL: rootfs"; exit 1; }
truncate -s 4G disk.img
e2fsck -f -y disk.img
resize2fs disk.img

# ---- 2. uapps（官方注入 hello/mini-oci/weston-start + autostart 钩子）----
make uapps || { echo "FATAL: uapps"; exit 1; }

# ---- 3. 注入 guest 工具（全部去 CRLF 后经 /tmp 中转）----
debugfs -w -R "mkdir /root" disk.img 2>/dev/null
for f in guest-bootstrap.sh:testpage/local-check.html; do :; done
tr -d '\r' < /mnt/e/02_competition/中电杯/scripts/guest-bootstrap.sh > /tmp/bootstrap_lf.sh
tr -d '\r' < /mnt/e/02_competition/中电杯/scripts/testpage/local-check.html > /tmp/index_lf.html
tr -d '\r' < /mnt/e/02_competition/中电杯/scripts/wsl2/autorun.sh > /tmp/autorun_lf.sh
debugfs -w -R "write /tmp/bootstrap_lf.sh /root/bootstrap.sh" disk.img
debugfs -w -R "write /tmp/index_lf.html /root/index.html" disk.img
debugfs -w -R "write /tmp/autorun_lf.sh /root/autorun.sh" disk.img

# ---- 4. 修改版 99-autostart.sh：前插 diag+autorun，移除 weston-start 行 ----
cp /mnt/e/02_competition/中电杯/tmp/xk-dump/99-autostart.orig.sh /tmp/cur_autostart.sh
grep -v "start_foreground 'weston-start'" /tmp/cur_autostart.sh \
  | grep -v '^# uapp: weston-start' > /tmp/base_autostart.sh
cat > /tmp/diag_block.sh <<'EOF'

# === xk6-diag: 设备节点诊断 + autorun（2026-09-20 WSL2 调试注入，位于最前避免被 return 短路）===
echo "[xk6-diag] ===== /dev listing ====="
ls -l /dev/ 2>&1 | head -50
echo "[xk6-diag] ===== /dev/dri ====="
ls -l /dev/dri/ 2>&1
echo "[xk6-diag] ===== /dev/input ====="
ls -l /dev/input/ 2>&1
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
tr -d '\r' < /tmp/new_autostart.sh > /tmp/new_autostart_lf.sh
debugfs -w -R "rm /etc/profile.d/99-autostart.sh" disk.img
debugfs -w -R "write /tmp/new_autostart_lf.sh /etc/profile.d/99-autostart.sh" disk.img

# ---- 5. 收尾：一致性校验 + 关键文件验证 ----
e2fsck -f -y disk.img
echo '=== busybox magic（应为 7f 45 4c 46）==='
debugfs -R "cat /bin/busybox" disk.img 2>/dev/null | head -c 4 | od -A x -t x1z | head -1
echo '=== /root ==='
debugfs -R "ls -l /root" disk.img 2>/dev/null
echo '=== autostart 头部 ==='
debugfs -R "cat /etc/profile.d/99-autostart.sh" disk.img 2>/dev/null | head -12
echo REBUILD_DONE
