#!/usr/bin/env bash
# 决赛 JavaScript 2 分：interaction.html 的真实键盘路径。
#
# run_input_final.sh 已经实现 QMP → virtio-input → evdev → libinput/Weston
# 的输入链和官方 interaction 像素门禁；这里仅把它固定到默认多进程
# autorun，并使用 Tab/Enter 触发页面自检。它不通过 CDP 注入 click 或 JS。
set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TAG="${1:-javascript-mp}"
# The interaction page is also renderer-backed.  A 600 s round ends while
# the first multiprocess frame is still warming up on pure TCG.
DUR="${2:-1600}"
IVL="${3:-60}"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    echo "Usage: $0 [tag] [duration] [interval]"
    echo "Run interaction.html JavaScript self-test through default multiprocess QMP input."
    exit 0
fi

MULTIPROCESS=1 \
INPUT_MODE=kbd \
FORCE_HMP=1 \
ABS_POINTER=0 \
NO_CLAMP=1 \
SELFTEST_ONLY=1 \
KBD_ECHO=0 \
BASE_IMG="${BASE_IMG:-$HOME/x-kernel/images/pkg-installed.img}" \
PKG_TARBALL="${PKG_TARBALL:-$HOME/xk6/tmp/eudev-seatprobe-libinput-swiftshader-p31.tar.gz}" \
bash "$HERE/run_input_final.sh" "$TAG" "$DUR" "$IVL"
RC=$?

EVID="$HOME/xk6/evidence/$(date +%Y-%m-%d)_t490-$TAG"
if [ -d "$EVID" ] && [ -f "$EVID/input-gate.json" ]; then
    cp -f "$EVID/input-gate.json" "$EVID/javascript-gate.json"
fi
exit "$RC"
