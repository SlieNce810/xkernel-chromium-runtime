#!/usr/bin/env bash
# x-kernel 完整构建链（WSL2 / T490 通用）：
# defconfig -> 下载 alpine-busybox rootfs -> 扩容 4G -> 注入 uapps + guest 工具 -> 构建内核
# 输出落盘: E:\02_competition\中电杯\tmp\build_xk.log
exec > /mnt/e/02_competition/中电杯/tmp/build_xk.log 2>&1
set -x
set -o pipefail

export PATH="$HOME/musl/aarch64-linux-musl-cross/bin:$HOME/qemu-8.2.3/bin:$PATH"
cd "$HOME/x-kernel" || exit 1

# ---- 0. rust targets：内核用 no-softfloat，uapps 用 linux-musl（带 std）----
rustup target add aarch64-unknown-none-softfloat aarch64-unknown-linux-musl \
  || { echo "FATAL: rustup targets"; exit 1; }

# ---- 1. 基线配置（组委会 kplat-aarch64 qemu_defconfig）----
cp -f platforms/kplat-aarch64/qemu_defconfig .config
make defconfig || { echo "FATAL: defconfig"; exit 1; }

# ---- 2. rootfs：预构建 alpine-busybox 镜像（gitee release，国内快）----
make rootfs ROOTFS_VARIANT=alpine-busybox || { echo "FATAL: rootfs"; exit 1; }

# ---- 3. 扩容到 4G（必须关机状态；装 chromium(~101MiB)+依赖需要 ~900MB+）----
truncate -s 4G disk.img || { echo "FATAL: truncate"; exit 1; }
e2fsck -f -y disk.img || { echo "FATAL: e2fsck"; exit 1; }
resize2fs disk.img || { echo "FATAL: resize2fs"; exit 1; }

# ---- 4. 注入 uapps（官方 weston-start 脚本等，debugfs 写入）----
make uapps || { echo "FATAL: uapps"; exit 1; }

# ---- 5. 追加注入 guest 侧工具（bootstrap 脚本 + 测试页）----
# debugfs 的 mkdir 已存在时会报错，容忍
debugfs -w -R "mkdir /root" disk.img 2>/dev/null
debugfs -w -R "write /mnt/e/02_competition/中电杯/scripts/guest-bootstrap.sh /root/bootstrap.sh" disk.img \
  || { echo "FATAL: inject bootstrap.sh"; exit 1; }
debugfs -w -R "write /mnt/e/02_competition/中电杯/scripts/testpage/local-check.html /root/index.html" disk.img \
  || { echo "FATAL: inject index.html"; exit 1; }
debugfs -R "ls -l /root" disk.img

# ---- 6. 构建内核（首次 cargo 全量编译，预计 5-20 分钟）----
make build || { echo "FATAL: build"; exit 1; }
ls -la xkernel_*.bin xkernel_*.elf 2>/dev/null

echo "BUILD_XK_DONE"
