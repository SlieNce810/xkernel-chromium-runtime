#!/usr/bin/env bash
# T490: 用 WSL 预装镜像替换 disk.img，并补注入 drmprobe + autorun v6
exec > /mnt/e/02_competition/中电杯/tmp/t490_swap_img.log 2>&1
SSH="ssh -o BatchMode=yes -o ConnectTimeout=10"
$SSH mo@10.249.63.140 'set -x
export PATH="$HOME/musl/aarch64-linux-musl-cross/bin:$HOME/.cargo/bin:$PATH"
cd "$HOME/x-kernel" || exit 1

# 0. 落定当前 disk.img（新构建版，留档）
[ -f disk.img ] && cp -f disk.img /tmp/disk-t490-built.img
ls -la /tmp/wsl-weston.img

# 1. 换镜像
cp -f /tmp/wsl-weston.img disk.img
e2fsck -f -y disk.img 2>&1 | tail -3

# 2. 校验 weston 完好（WSL 镜像里应为 67240 字节）
echo "=== weston ==="
debugfs -R "stat /usr/bin/weston" disk.img 2>/dev/null | grep -E "Inode:|Size:"
echo "=== 99-autostart 是否已含 diag 段 ==="
debugfs -R "cat /etc/profile.d/99-autostart.sh" disk.img 2>/dev/null | grep -c "xk6-diag"
echo "=== weston-start 行是否已移除（应为 0）==="
debugfs -R "cat /etc/profile.d/99-autostart.sh" disk.img 2>/dev/null | grep -c "weston-start"

# 3. 补注入：drmprobe（重编）+ autorun v6
aarch64-linux-musl-gcc -static -Os -o /tmp/drmprobe "$HOME/xk6/scripts/t490/drmprobe.c" && file /tmp/drmprobe
cp "$HOME/xk6/scripts/t490/autorun_v5.sh" /tmp/a6.sh && sed -i "s/\r$//" /tmp/a6.sh
for p in /drmprobe /root/autorun.sh /root/bootstrap.sh /root/index.html; do
  debugfs -w -R "rm $p" disk.img >/dev/null 2>&1
done
debugfs -w -R "write /tmp/drmprobe /drmprobe" disk.img
debugfs -w -R "set_inode_field /drmprobe mode 0100755" disk.img
debugfs -w -R "write /tmp/a6.sh /root/autorun.sh" disk.img
debugfs -w -R "set_inode_field /root/autorun.sh mode 0100755" disk.img
tr -d "\r" < "$HOME/xk6/scripts/guest-bootstrap.sh" > /tmp/boot.sh
tr -d "\r" < "$HOME/xk6/scripts/testpage/local-check.html" > /tmp/idx.html
debugfs -w -R "write /tmp/boot.sh /root/bootstrap.sh" disk.img
debugfs -w -R "write /tmp/idx.html /root/index.html" disk.img

# 4. 收尾校验
e2fsck -f -y disk.img 2>&1 | tail -2
debugfs -R "ls -l /root" disk.img 2>/dev/null
debugfs -R "stat /drmprobe" disk.img 2>/dev/null | grep -E "Mode:|Size:"
debugfs -R "cat /bin/busybox" disk.img 2>/dev/null | head -c 4 | od -A n -t x1'
echo SWAP_DONE
