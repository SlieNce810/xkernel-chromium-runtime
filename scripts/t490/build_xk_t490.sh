#!/usr/bin/env bash
# T490 版完整构建链：defconfig -> rootfs -> 扩容 -> uapps -> 注入(drmprobe+autorun v5+autostart 改写) -> build
# 与 WSL 版的差异：路径改 $HOME/xk6；额外编译并注入 drmprobe 探针
exec > "$HOME/xk6/tmp/build_xk.log" 2>&1
set -x
set -o pipefail

export PATH="$HOME/.cargo/bin:$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"
XK6="$HOME/xk6"
mkdir -p "$XK6/tmp"
cd "$HOME/x-kernel" || exit 1

# ---- 0. rust targets（x-kernel 的 rust-toolchain.toml 指定 1.95.0）----
rustup target add --toolchain 1.95.0 aarch64-unknown-none-softfloat aarch64-unknown-linux-musl \
  || { echo "FATAL: rustup target"; exit 1; }

# ---- 1. 基线配置（赛题第七节(一)1：组委会 qemu_defconfig）----
# ★ 不要用上游 README 写的 platforms/<arch>-qemu-virt/defconfig —— 该路径已失效(404)
cp -f platforms/kplat-aarch64/qemu_defconfig .config || { echo "FATAL: cp 基线 defconfig 失败"; exit 1; }
make defconfig || exit 1

# ---- 1b. 架构断言 ----
# 为什么必须断言：`.config` 被 .gitignore:46 忽略 → **架构错误在 git 层面完全不可见**；
# 且 `make defconfig` 只检查 `.config` 是否存在（Makefile:216-218），cp 一旦失败就会
# 静默沿用上一次残留的 .config —— 可能构建出 riscv64/x86_64 的内核而毫无提示。
grep -q '^ARCH="aarch64"'               .config || { echo "FATAL: ARCH 不是 aarch64";        exit 1; }
grep -q '^MACHINE_AARCH64_QEMU=y'       .config || { echo "FATAL: 不是 AArch64 QEMU 机型";    exit 1; }
grep -q '^KFEAT_DRIVER_VIRTIO_GPU=y'    .config || { echo "FATAL: virtio GPU 驱动未启用";     exit 1; }
grep -q '^KFEAT_DRIVER_VIRTIO_INPUT=y'  .config || { echo "FATAL: virtio INPUT 驱动未启用";   exit 1; }
grep -q '^KFEAT_VIRTIO_BUS_PCI=y'       .config || { echo "FATAL: virtio PCI 总线未启用";     exit 1; }
if grep -q '^ARCH_\(RISCV64\|X86_64\|LOONGARCH64\)=y' .config; then
    echo "FATAL: .config 混入其他架构"; exit 1
fi
echo "OK: .config 为 kplat-aarch64 组委会基线"
sha256sum .config

# ---- 2. rootfs（gitee release 预构建 alpine-busybox）----
make rootfs ROOTFS_VARIANT=alpine-busybox || exit 1

# ---- 3. 扩容 4G ----
truncate -s 4G disk.img || exit 1
e2fsck -f -y disk.img
resize2fs disk.img

# ---- 4. uapps（官方注入 + autostart 钩子）----
make uapps || exit 1

# ---- 5. 编译 drmprobe（musl 静态）并注入 ----
aarch64-linux-musl-gcc -static -Os -o "$XK6/tmp/drmprobe" "$XK6/scripts/t490/drmprobe.c" \
  || { echo "FATAL: drmprobe compile"; exit 1; }
file "$XK6/tmp/drmprobe"

debugfs -w -R "mkdir /root" disk.img 2>/dev/null
tr -d '\r' < "$XK6/scripts/guest-bootstrap.sh" > /tmp/bootstrap_lf.sh
tr -d '\r' < "$XK6/scripts/testpage/local-check.html" > /tmp/index_lf.html
tr -d '\r' < "$XK6/scripts/t490/autorun_v5.sh" > /tmp/autorun_v5_lf.sh

debugfs -w -R "write /tmp/bootstrap_lf.sh /root/bootstrap.sh" disk.img || exit 1
debugfs -w -R "write /tmp/index_lf.html /root/index.html" disk.img || exit 1
debugfs -w -R "write /tmp/autorun_v5_lf.sh /root/autorun.sh" disk.img || exit 1
debugfs -w -R "write $XK6/tmp/drmprobe /drmprobe" disk.img || exit 1
debugfs -w -R "set_inode_field /drmprobe mode 0100755" disk.img

# ---- 6. 99-autostart.sh 改写：顶部注入 autorun 启动，移除原 weston-start 行 ----
debugfs -R "cat /etc/profile.d/99-autostart.sh" disk.img 2>/dev/null > /tmp/cur_autostart.sh
cp /tmp/cur_autostart.sh "$XK6/tmp/99-autostart.orig.sh"
grep -v "start_foreground 'weston-start'" /tmp/cur_autostart.sh \
  | grep -v '^# uapp: weston-start' > /tmp/base_autostart.sh

cat > /tmp/diag_block.sh <<'EOF'

# === xk6-diag: autorun v5 启动（顶部注入，避免被后续 return 短路）===
echo "[xk6-diag] $(date 2>/dev/null) launching autorun v5"
sh /root/autorun.sh >/root/autorun-stdout.log 2>&1 &
EOF

awk '
  { print }
  /export XKERNEL_AUTOSTART_DONE=1/ {
    while ((getline l < "/tmp/diag_block.sh") > 0) print l
    close("/tmp/diag_block.sh")
  }
' /tmp/base_autostart.sh > /tmp/new_autostart.sh

debugfs -w -R "rm /etc/profile.d/99-autostart.sh" disk.img
debugfs -w -R "write /tmp/new_autostart.sh /etc/profile.d/99-autostart.sh" disk.img

# ---- 7. 一致性收尾 + 验证 ----
e2fsck -f -y disk.img
echo '=== /root ==='
debugfs -R "ls -l /root" disk.img 2>/dev/null
echo '=== /drmprobe ==='
debugfs -R "stat /drmprobe" disk.img 2>/dev/null | grep -E 'Inode|Mode|Size'
echo '=== busybox magic ==='
debugfs -R "cat /bin/busybox" disk.img 2>/dev/null | head -c 4 | od -A n -t x1
echo '=== autostart 头部 ==='
debugfs -R "cat /etc/profile.d/99-autostart.sh" disk.img 2>/dev/null | head -12

# ---- 8. 内核构建 ----
make build || { echo "FATAL: build"; exit 1; }
ls -la xkernel_*.bin
echo BUILD_T490_DONE
