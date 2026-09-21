#!/usr/bin/env bash
# T490 · 通用单轮会话编排（注入任意 probe + 任意 autorun，然后跑一轮会话）
#
# 用法：
#   bash t490_round.sh <tag> <duration> <interval> <autorun文件名> [probe.c ...]
#
# 例：
#   bash t490_round.sh fetch 2400 120 autorun_fetch.sh evprobe.c
#   bash t490_round.sh p1fdpass 300 60 autorun_p1.sh fdprobe.c
#
# 约定：
#   - 源文件都在 guest 侧脚本目录 ~/xk6/scripts/t490/ 下
#   - <autorun文件名> 注入为 /root/autorun.sh（guest 的 99-autostart 会调它）
#   - 每个 probe.c 交叉编译为静态 aarch64，注入到 /<basename 无扩展>，mode 0755
#   - 基础镜像由环境变量 BASE_IMG 指定，默认 images/p0-drmversion-fixed.img
#   - 环境变量 PKG_TARBALL：宿主侧打好的 tar.gz（由 t490_build_pkgs.sh 产出）
#     → 注入为 /pkgs.tar.gz，guest 内 tar -x 解开
#   - 环境变量 PAGE_HTML：测试页源文件 → 注入为 /usr/share/html-test/index.html
#
# 例：
#   PKG_TARBALL=~/xk6/tmp/pkgs-fetch.tar.gz PAGE_HTML=~/xk6/scripts/testpage/local-check.html \
#     bash t490_round.sh install 1200 120 autorun_install.sh
#
# 为什么要有它：v2 §8 要求"一套编排、一套证据格式"。此前每轮都手写注入脚本
# （t490_v7..v16 + t490_pull_v*），既重复又容易让 guest 侧脚本与本地副本失同步
# ——上一轮就因此误判过一次。
#
# 产出：~/xk6/evidence/<date>_t490-<tag>/{console.log,cmd.txt,env.txt,manifest.txt,timestamps.csv,screenshots/}

exec > "$HOME/xk6/tmp/t490_round_$1.log" 2>&1
set -x

export PATH="$HOME/qemu-root/usr/bin:$HOME/.cargo/bin:$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"

TAG="${1:?tag required}"
DUR="${2:-300}"
IVL="${3:-60}"
AUTORUN="${4:?autorun filename required}"
shift 4
PROBES="$*"

SRC_DIR="$HOME/xk6/scripts/t490"
BASE_IMG="${BASE_IMG:-$HOME/x-kernel/images/p0-drmversion-fixed.img}"
PKG_TARBALL="${PKG_TARBALL:-}"
PAGE_HTML="${PAGE_HTML:-}"

cd "$HOME/x-kernel" || exit 1

# ---------------------------------------------------------------- 0. 前置
if pgrep -a qemu-system-aarch64 >/dev/null 2>&1; then
    echo "!! 有残留 QEMU 进程，改镜像前必须先停"
    pgrep -a qemu-system-aarch64
    exit 1
fi
[ -f "$BASE_IMG" ] || { echo "!! 基础镜像不存在: $BASE_IMG"; exit 1; }
[ -f "$SRC_DIR/$AUTORUN" ] || { echo "!! autorun 不存在: $SRC_DIR/$AUTORUN"; exit 1; }

echo "=== 基础镜像: $BASE_IMG ==="
sha256sum "$BASE_IMG"

# ---------------------------------------------------------------- 1. 换镜像
cp -f "$BASE_IMG" disk.img
e2fsck -f -y disk.img 2>&1 | tail -3

# ---------------------------------------------------------------- 2. 编译 probe
COMPILED=""
for p in $PROBES; do
    name="${p%.c}"
    aarch64-linux-musl-gcc -static -O2 -Wall -Wextra -pthread -o "/tmp/$name" "$SRC_DIR/$p" \
        || { echo "!! 编译失败: $p"; exit 1; }
    ls -la "/tmp/$name"
    COMPILED="$COMPILED $name"
done

# ---------------------------------------------------------------- 3. autorun
tr -d "\r" < "$SRC_DIR/$AUTORUN" > /tmp/autorun_inj.sh
[ -s /tmp/autorun_inj.sh ] || { echo "!! autorun 生成为空"; exit 1; }
chmod +x /tmp/autorun_inj.sh
echo "--- autorun 行数 ---"
wc -l /tmp/autorun_inj.sh

# ---------------------------------------------------------------- 4. 注入
for n in $COMPILED; do
    debugfs -w -R "rm /$n" disk.img >/dev/null 2>&1
    debugfs -w -R "write /tmp/$n /$n" disk.img
    debugfs -w -R "set_inode_field /$n mode 0100755" disk.img
done
debugfs -w -R "rm /root/autorun.sh" disk.img >/dev/null 2>&1
debugfs -w -R "write /tmp/autorun_inj.sh /root/autorun.sh" disk.img
debugfs -w -R "set_inode_field /root/autorun.sh mode 0100755" disk.img

# 包 tarball（单个文件注入，guest 内解包 —— 见 t490_build_pkgs.sh 的说明）
if [ -n "$PKG_TARBALL" ]; then
    [ -s "$PKG_TARBALL" ] || { echo "!! PKG_TARBALL 不存在或为空: $PKG_TARBALL"; exit 1; }
    echo "=== 注入 tarball: $PKG_TARBALL ==="
    ls -la "$PKG_TARBALL"
    debugfs -w -R "rm /pkgs.tar.gz" disk.img >/dev/null 2>&1
    debugfs -w -R "write $PKG_TARBALL /pkgs.tar.gz" disk.img
    debugfs -w -R "set_inode_field /pkgs.tar.gz mode 0100644" disk.img
fi

# 测试页
if [ -n "$PAGE_HTML" ]; then
    [ -s "$PAGE_HTML" ] || { echo "!! PAGE_HTML 不存在或为空: $PAGE_HTML"; exit 1; }
    echo "=== 注入测试页: $PAGE_HTML ==="
    tr -d "\r" < "$PAGE_HTML" > /tmp/index.html
    debugfs -w -R "mkdir /usr/share/html-test" disk.img >/dev/null 2>&1
    debugfs -w -R "rm /usr/share/html-test/index.html" disk.img >/dev/null 2>&1
    debugfs -w -R "write /tmp/index.html /usr/share/html-test/index.html" disk.img
    debugfs -w -R "set_inode_field /usr/share/html-test/index.html mode 0100644" disk.img
fi

# ---------------------------------------------------------------- 5. 校验
e2fsck -f -y disk.img 2>&1 | tail -2
echo "--- 注入结果 ---"
for n in $COMPILED; do
    printf "%-14s " "/$n"
    debugfs -R "stat /$n" disk.img 2>/dev/null | grep -E "Mode:|Size:" | tr '\n' ' '; echo
done
printf "%-14s " "/root/autorun.sh"
debugfs -R "stat /root/autorun.sh" disk.img 2>/dev/null | grep -E "Mode:|Size:" | tr '\n' ' '; echo
if [ -n "$PKG_TARBALL" ]; then
    printf "%-14s " "/pkgs.tar.gz"
    debugfs -R "stat /pkgs.tar.gz" disk.img 2>/dev/null | grep -E "Mode:|Size:" | tr '\n' ' '; echo
fi
if [ -n "$PAGE_HTML" ]; then
    printf "%-14s " "/usr/share/html-test/index.html"
    debugfs -R "stat /usr/share/html-test/index.html" disk.img 2>/dev/null | grep -E "Mode:|Size:" | tr '\n' ' '; echo
fi

# ---------------------------------------------------------------- 6. 会话
echo "=== 会话 tag=$TAG duration=$DUR interval=$IVL ==="
bash "$HOME/xk6/scripts/t490/run_session_t490.sh" "$TAG" "$DUR" "$IVL"
echo "SESSION_RC=$?"
echo "ROUND_DONE tag=$TAG"
echo "EVIDENCE=$HOME/xk6/evidence/$(date +%Y-%m-%d)_t490-$TAG"
