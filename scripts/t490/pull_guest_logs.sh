#!/usr/bin/env bash

# Standalone T490 delivery workspace; defaults preserve the native Linux layout.
XK6_ROOT="${XK6_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
KERNEL_REPO="${KERNEL_REPO:-${KERNEL_DIR:-$HOME/x-kernel}}"
# 两套命名并存：KERNEL_DIR 是决赛线 13 个脚本沿用的旧名，KERNEL_REPO 是初赛提交包口径。
# 外部传任一个都映射到同一目录，避免"传了 KERNEL_DIR 却静默回退到 ~/x-kernel"跑错内核。
KERNEL_DIR="$KERNEL_REPO"
export XK6_ROOT KERNEL_REPO KERNEL_DIR
mkdir -p "$XK6_ROOT/tmp"
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

IMG="${KERNEL_REPO}/disk.img"
OUT="${XK6_ROOT}/evidence/$(date +%Y-%m-%d)_t490-$TAG/guest"
mkdir -p "$OUT"

image_qemu_running() {
    for proc in /proc/[0-9]*; do
        [ -r "$proc/cmdline" ] || continue
        exe=$(readlink -f "$proc/exe" 2>/dev/null || true)
        case "${exe##*/}" in qemu-system-*) ;; *) continue ;; esac
        cmdline=$(tr '\0' ' ' < "$proc/cmdline" 2>/dev/null || true)
        case "$cmdline" in *"$IMG"*) return 0 ;; esac
    done
    return 1
}

for _ in $(seq 1 60); do
    image_qemu_running || break
    sleep 1
done
if image_qemu_running; then
    echo "!! QEMU 仍在运行 —— debugfs 不能在挂载中改/读镜像，请先停"
    exit 1
fi
[ -f "$IMG" ] || { echo "!! 镜像不存在: $IMG"; exit 1; }

# 常用文件 + 调用方指定的额外文件
# ★ 2026-09-22：把 autorun_v3.sh 实际写的那几个日志补进默认清单。
#   历史清单只覆盖 chromium.log/nnp.log/install.log 等，而 autorun_full/v3 写的是
#   full.log / chrome-full.log / chrome-snap.log（外加 A0 探针的 a0.log）——
#   漏了它们会 dump 出 0 字节，然后被误判成"guest 根本没写日志"。
FILES="/root/full.log /root/chrome-full.log /root/chrome-snap.log /root/a0.log \
/root/chromium.log /root/nnp.log /root/nnp-watch.log /root/install.log /root/install-watch.log /tmp/weston.log $EXTRA"
# Default multi-process diagnostics use a separate prefix so that the complete
# Chromium and process snapshots survive the round and can be parsed after the
# QEMU image is stopped.
FILES="$FILES /root/mp-diag.log /root/mp-chromium.log /root/mp-weston.log \
/root/mp-weston-stdout.log /root/mp-seatd.log /root/mp-udevd.log /root/mp-trace.*"
FILES="$FILES /root/autostart.log /root/single-initial.log /root/single-initial.csv /root/single-chromium.log \
/root/single-weston.log /root/single-weston-stdout.log /root/single-seatd.log /root/single-udevd.log \
/root/submission-gaps.log /root/submission-gap-submission_gap_probe.out \
/root/submission-gap-compatprobe.out /root/submission-gap-sandboxipcprobe.out \
/root/submission-gap-fdprobe.out /root/submission-gap-seqpacketprobe.out /root/submission-gap-evprobe.out"

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
