#!/usr/bin/env bash
# pull_guest_logs.sh —— 从 disk.img 回收 guest 内持久日志（QEMU 停机后执行）
#
# 为什么需要它
#   guest 的 /tmp 是 tmpfs，但 /root 是真实磁盘。autorun 把日志写在 /root/ 下，
#   因此只要 QEMU 停了，就能用 debugfs 把**完整日志**dump 出来 —— 比 console 里
#   tee 出来的片段完整得多（console 只 echo 了 head/tail 各 60 行）。
#
# 用法：bash pull_guest_logs.sh <tag> [额外文件...]
set -u

TAG="${1:?usage: pull_guest_logs.sh <tag> [extra files...]}"
shift
EXTRA="$*"

IMG="$HOME/x-kernel/disk.img"
OUT="$HOME/xk6/evidence/$(date +%Y-%m-%d)_t490-$TAG/guest"
mkdir -p "$OUT"

if pgrep -f "qemu-system-aarch6[4]" >/dev/null 2>&1; then
    echo "!! QEMU 仍在运行 —— debugfs 不能在挂载中改/读镜像，请先停"
    exit 1
fi
[ -f "$IMG" ] || { echo "!! 镜像不存在: $IMG"; exit 1; }

# 常用文件 + 调用方指定的额外文件
FILES="/root/chromium.log /root/nnp.log /root/nnp-watch.log /root/install.log /root/install-watch.log /tmp/weston.log $EXTRA"

for f in $FILES; do
    base=$(echo "$f" | tr '/' '_')
    debugfs -R "dump $f $OUT/$base" "$IMG" >/dev/null 2>&1
    if [ -s "$OUT/$base" ]; then
        printf '%-40s %8s bytes  %5s lines\n' "$f" "$(stat -c %s "$OUT/$base")" "$(wc -l < "$OUT/$base")"
    else
        rm -f "$OUT/$base"
        printf '%-40s (缺失/空)\n' "$f"
    fi
done

# 顺手把目录也列一下，便于确认还有哪些有用文件
echo "--- /root 目录 ---"
debugfs -R "ls -l /root" "$IMG" 2>/dev/null

echo "OUT=$OUT"
