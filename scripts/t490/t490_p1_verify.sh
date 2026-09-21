#!/usr/bin/env bash
# T490 · P1 验收：注入 fdprobe 与带 fdprobe 阶段的 autorun，跑一轮 QEMU 会话
#
# 前置：已在 ~/x-kernel 应用 p1_stream_ancillary.py 且 make build 通过
# 用法：bash t490_p1_verify.sh [duration] [interval]     默认 300 60
#
# 做什么
#   1. 交叉编译 fdprobe（静态 aarch64，musl）
#   2. 从 P0 冻结镜像 images/p0-drmversion-fixed.img 起步（含 weston 全家桶 + libseat-shim，跳过装包）
#   3. 注入 guest 侧 /fdprobe 与 /root/autorun.sh（= 单路线总控 autorun_p1.sh）
#   4. debugfs 注入 + e2fsck 校验，并确认镜像内有 libseat-shim.so
#   5. 调 run_session_t490.sh 跑纯 TCG 会话（GRAPHIC=y ACCEL=n MEM=4g SMP=4 VSOCK=n + 键鼠）
#
# 产出：~/xk6/evidence/<date>_t490-p1-fdpass/{console.log,screenshots/*.ppm,cmd.txt,env.txt,manifest.txt}
#      界标：串口里 fdprobe 的 `[RESULT] T1_fd_count=`，
#            以及 weston.log 是否还出现 `create_pool` / `file descriptor expected` / `Quitting`

exec > "$HOME/xk6/tmp/t490_p1_verify.log" 2>&1
set -x

export PATH="$HOME/qemu-root/usr/bin:$HOME/.cargo/bin:$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"

DUR="${1:-300}"
IVL="${2:-60}"
TAG="p1-fdpass"

cd "$HOME/x-kernel" || exit 1

# ---------------------------------------------------------------- 0. 前置检查
if pgrep -a qemu-system-aarch64 >/dev/null 2>&1; then
    echo "!! 有残留 QEMU 进程，先退出（改镜像必须在 QEMU 关闭状态）"
    pgrep -a qemu-system-aarch64
    exit 1
fi
[ -f images/p0-drmversion-fixed.img ] || { echo "!! 冻结镜像不存在"; exit 1; }

# ---------------------------------------------------------------- 1. 编译 fdprobe
aarch64-linux-musl-gcc -static -O2 -Wall -Wextra -o /tmp/fdprobe \
    "$HOME/xk6/scripts/t490/fdprobe.c" || { echo "!! fdprobe 编译失败"; exit 1; }
ls -la /tmp/fdprobe

# ---------------------------------------------------------------- 2. 换镜像
cp -f images/p0-drmversion-fixed.img disk.img
e2fsck -f -y disk.img 2>&1 | tail -3
debugfs -R "stat /usr/bin/weston" disk.img 2>/dev/null | grep -E "Mode:|Size:"

# ---------------------------------------------------------------- 3. guest 总控
# 用专用单路线总控 autorun_p1.sh，不再 splice 多路线的 autorun_v5.sh
tr -d "\r" < "$HOME/xk6/scripts/t490/autorun_p1.sh" > /tmp/autorun_p1.sh
[ -s /tmp/autorun_p1.sh ] || { echo "!! autorun_p1.sh 生成为空"; exit 1; }
chmod +x /tmp/autorun_p1.sh
echo "--- autorun_p1.sh 关键行检查 ---"
grep -n "libseat-shim\|drm-device=card0\|fdprobe\|watcher" /tmp/autorun_p1.sh

# ---------------------------------------------------------------- 3.5 前置：shim 必须在镜像里
echo "--- 镜像内 libseat-shim.so ---"
debugfs -R "stat /usr/local/lib/libseat-shim.so" disk.img 2>/dev/null | grep -E "Mode:|Size:" \
    || { echo "!! 镜像缺 libseat-shim.so，本轮单路线无法成立"; exit 1; }

# ---------------------------------------------------------------- 4. 注入
for p in /fdprobe /root/autorun.sh; do
    debugfs -w -R "rm $p" disk.img >/dev/null 2>&1
done
debugfs -w -R "write /tmp/fdprobe /fdprobe" disk.img
debugfs -w -R "set_inode_field /fdprobe mode 0100755" disk.img
debugfs -w -R "write /tmp/autorun_p1.sh /root/autorun.sh" disk.img
debugfs -w -R "set_inode_field /root/autorun.sh mode 0100755" disk.img

# ---------------------------------------------------------------- 5. 校验
e2fsck -f -y disk.img 2>&1 | tail -2
echo "--- /fdprobe ---"
debugfs -R "stat /fdprobe" disk.img 2>/dev/null | grep -E "Mode:|Size:"
echo "--- /root/autorun.sh ---"
debugfs -R "stat /root/autorun.sh" disk.img 2>/dev/null | grep -E "Mode:|Size:"
echo "--- autorun 里的 fdprobe 行数（应 >=2）---"
debugfs -R "cat /root/autorun.sh" disk.img 2>/dev/null | grep -c "fdprobe"
echo "--- 99-autostart 是否仍指向 /root/autorun.sh ---"
debugfs -R "cat /etc/profile.d/99-autostart.sh" disk.img 2>/dev/null | tail -12

# ---------------------------------------------------------------- 6. 会话
echo "=== 启动会话 tag=$TAG duration=$DUR interval=$IVL ==="
bash "$HOME/xk6/scripts/t490/run_session_t490.sh" "$TAG" "$DUR" "$IVL"
echo "SESSION_RC=$?"
echo P1_VERIFY_DONE
