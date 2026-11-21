#!/usr/bin/env bash
# T4-P: real QMP keyboard/mouse validation on an explicitly selected renderer mode.
#
# The historical default remains the known-good single-process comparison. Set
# MULTIPROCESS=1 for the decision round; that selects autorun_mp_diag.sh and
# therefore keeps the browser's zygote/renderer process boundary in the test.
#
# Run on T490 only.  A second QEMU is rejected by t490_round's disk lock.

set -u
set -o pipefail

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
    shift
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=platform.env
. "$HERE/platform.env"
TAG="${1:-input-final}"
DUR="${2:-900}"
IVL="${3:-60}"
KERNEL_DIR="${KERNEL_DIR:-$HOME/x-kernel}"
export KERNEL_DIR
KERNEL_BIN="$KERNEL_DIR/target/xkmake/kplat-aarch64/release/kernel.bin"
if [ ! -f "$KERNEL_BIN" ]; then
    KERNEL_BIN="$KERNEL_DIR/xkernel_aarch64-qemu.bin"
fi
EXPECTED_KERNEL_SHA256_VALUE="${STABILITY_EXPECTED_KERNEL_SHA256:-${EXPECTED_KERNEL_SHA256:-}}"
INPUT_MODE="${INPUT_MODE:-pointer}"   # calibrated score path | kbd
MULTIPROCESS="${MULTIPROCESS:-0}"
EVDEV_PROBE="${EVDEV_PROBE:-1}"
# The competition platform exposes virtio-mouse-pci, a relative device. QMP
# input-send-event abs is unsupported there. Pointer mode uses the calibrated
# HMP step4 score driver; keyboard-only mode uses QMP send-key for JS checks.
# Set FORCE_HMP=0 and ABS_POINTER=1 only with an attached absolute tablet.
FORCE_HMP="${FORCE_HMP:-1}"
ABS_POINTER="${ABS_POINTER:-0}"
NO_CLAMP_DEFAULT=1
[ "$ABS_POINTER" = "1" ] && NO_CLAMP_DEFAULT=0
NO_CLAMP="${NO_CLAMP:-$NO_CLAMP_DEFAULT}"
QMP_SOCKET="${QMP_SOCKET:-/tmp/xk6-qmp-${TAG}.sock}"
CDP_PORT="${CDP_PORT:-61006}"
EVID_TAG="$TAG"
[ "$DRY_RUN" = "0" ] || EVID_TAG="${TAG}-preflight"
OUT="$HOME/xk6/evidence/$(date +%Y-%m-%d)_t490-$EVID_TAG"
WORK="$HOME/xk6/tmp/input-$TAG"
ROUND_LOG="$WORK/round.log"
QMP_LOG="$WORK/qmp-events.jsonl"
CDP_LOG="$WORK/cdp-events.jsonl"
READY_DIR="$WORK/readiness"
BEFORE="$WORK/before.ppm"
AFTER="$WORK/after.ppm"
AFTER_JSON="$WORK/after-assert.json"
STATE_JSON="$WORK/final-state.json"
GATE_JSON="$WORK/input-gate.json"

die() { echo "INPUT_FINAL_ABORT: $*" >&2; exit 2; }

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<'EOF'
Usage: run_input_final.sh [--dry-run] [tag] [duration] [interval]
  INPUT_MODE=pointer|kbd MULTIPROCESS=1 selects the decision-round path.
  EVDEV_PROBE=0 skips the optional evdev observer for a clean A/B run.
  INTERACTION_POINTER_MODE=step1|step3 selects a slower relative-pointer calibration.
  INTERACTION_COUNTER_TARGET=x,y and INTERACTION_NAV_TARGET=x,y override relative movement requests.
  INTERACTION_COUNTER_RETRY_TARGETS='x,y;x,y' tries ordered real-click targets until the counter ROI changes.
  These are HMP move inputs after the off-screen reset, not absolute screen coordinates.
  Pointer mode defaults to historical HMP step4 and verifies JS, keyboard echo, mouse count, and navigation.
  Kbd mode performs the keyboard-only JavaScript self-test.
  An absolute tablet must be selected explicitly with FORCE_HMP=0 ABS_POINTER=1 EXTRA_QEMU_ARGS='-device virtio-tablet-pci'.
  --dry-run validates input-mode options and prints the resolved 2 GiB QEMU command without starting QEMU.
  KERNEL_DIR selects an isolated kernel; STABILITY_EXPECTED_KERNEL_SHA256 can pin its binary hash.
  PKG_TARBALL is optional when BASE_IMG already contains the installed runtime.
EOF
    exit 0
fi

case "$FORCE_HMP" in
    0|1) ;;
    *) die "FORCE_HMP must be 0 or 1" ;;
esac
case "$ABS_POINTER" in
    0|1) ;;
    *) die "ABS_POINTER must be 0 or 1" ;;
esac
case "$NO_CLAMP" in
    0|1) ;;
    *) die "NO_CLAMP must be 0 or 1" ;;
esac
case "$INPUT_MODE" in
    pointer|kbd) ;;
    *) die "INPUT_MODE must be pointer or kbd" ;;
esac
case "$EVDEV_PROBE" in
    0|1) ;;
    *) die "EVDEV_PROBE must be 0 or 1" ;;
esac
[ "$FORCE_HMP" != 1 ] || [ "$ABS_POINTER" != 1 ] \
    || die "FORCE_HMP=1 conflicts with ABS_POINTER=1; relative virtio-mouse and absolute tablet modes are separate"
if [ "$ABS_POINTER" = "1" ]; then
    [ "$FORCE_HMP" = "0" ] || die "ABS_POINTER=1 requires FORCE_HMP=0"
    [ "${EXTRA_QEMU_ARGS:-}" = "-device virtio-tablet-pci" ] \
        || die "ABS_POINTER=1 requires EXTRA_QEMU_ARGS='-device virtio-tablet-pci'"
fi

if [ -n "$EXPECTED_KERNEL_SHA256_VALUE" ]; then
    case "$EXPECTED_KERNEL_SHA256_VALUE" in
        *[!0-9a-fA-F]*) die "STABILITY_EXPECTED_KERNEL_SHA256 must be 64 hexadecimal characters" ;;
    esac
    [ "${#EXPECTED_KERNEL_SHA256_VALUE}" -eq 64 ] \
        || die "STABILITY_EXPECTED_KERNEL_SHA256 must be 64 hexadecimal characters"
    [ -f "$KERNEL_BIN" ] || die "kernel binary missing: $KERNEL_BIN"
    ACTUAL_KERNEL_SHA256="$(sha256sum "$KERNEL_BIN" | awk '{print $1}')"
    NORMALIZED_EXPECTED_KERNEL_SHA256="$(printf '%s' "$EXPECTED_KERNEL_SHA256_VALUE" | tr 'A-F' 'a-f')"
    [ "$ACTUAL_KERNEL_SHA256" = "$NORMALIZED_EXPECTED_KERNEL_SHA256" ] \
        || die "kernel SHA-256 mismatch: expected $NORMALIZED_EXPECTED_KERNEL_SHA256 got $ACTUAL_KERNEL_SHA256"
fi

case "$MULTIPROCESS" in
    0) AUTORUN_SCRIPT="autorun_single_initial.sh" ;;
    1) AUTORUN_SCRIPT="autorun_mp_diag.sh" ;;
    *) die "MULTIPROCESS 必须是 0 或 1" ;;
esac

# On the aarch64 TCG guest, the interaction page's renderer can spend the
# entire IPC window in V8 JIT code generation and be recycled before its first
# frame.  Jitless keeps JavaScript execution real while avoiding that cold-start
# path.  Callers can still override EXTRA_FLAGS_VALUE for an explicit A/B.
if [ "$MULTIPROCESS" = "1" ] && [ -z "${EXTRA_FLAGS_VALUE:-}" ]; then
    EXTRA_FLAGS_VALUE="--js-flags=--jitless"
fi

[ "$(uname -s)" = "Linux" ] || die "run_input_final.sh 只能在 T490 Linux 主机运行"
[ -d "$OUT" ] && die "证据目录已存在，拒绝覆盖: $OUT"
[ -e "$QMP_SOCKET" ] && die "QMP socket 已存在，拒绝复用: $QMP_SOCKET"

# 显示后端预检：GTK 的窗口内容区尺寸由窗口管理器决定，guest 只能拿到 640×480
# （report/67 §一 实测），跑满 900 秒才发现画幅不对的代价太高，这里直接拒绝。
PLAT_DISPLAY=""
if [ -f "$HERE/platform.env" ]; then
    PLAT_DISPLAY=$( . "$HERE/platform.env" >/dev/null 2>&1; printf '%s' "${PLAT_QEMU_DISPLAY:-}" )
fi
case "$PLAT_DISPLAY" in
    *gtk*) die "PLAT_QEMU_DISPLAY=${PLAT_DISPLAY} 含 gtk：只能产出 640×480，不得作为判据轮" ;;
esac

# Match the executable name rather than an arbitrary command-line substring.
# A pgrep -f check can see its own shell/SSH command while a previous QEMU is
# already gone, which falsely aborts the long renderer round.
ps -eo comm= 2>/dev/null | grep -qx 'qemu-system-aarch64' \
    && die "已有 QEMU 在运行，拒绝并行"
if lslocks 2>/dev/null | grep -q 'xk6/tmp/disk.img.lock'; then
    die "disk.img.lock 仍被占用，拒绝并行"
fi
if ss -ltn 2>/dev/null | grep -q ':5901 '; then
    die "VNC 5901 已被占用，拒绝启动"
fi
if ss -ltn 2>/dev/null | grep -q ":${CDP_PORT} "; then
    die "CDP 端口 ${CDP_PORT} 已被占用，拒绝启动"
fi
mkdir -p "$WORK" "$READY_DIR"

BASE_IMG="${BASE_IMG:-$HOME/x-kernel/images/pkg-installed.img}"
PKG_TARBALL="${PKG_TARBALL:-}"
[ -f "$BASE_IMG" ] || die "基础镜像不存在: $BASE_IMG"
if [ -n "$PKG_TARBALL" ] && [ ! -f "$PKG_TARBALL" ]; then
    die "overlay 不存在: $PKG_TARBALL"
fi
bash "$HERE/verify_chromium_image.sh" "$BASE_IMG" "${EXPECTED_CHROMIUM_MAJOR:-149}" \
    || die "基础镜像 Chromium 版本不匹配"

if [ "$DRY_RUN" = "1" ]; then
    QEMU_ARGS_VALUE="$PLAT_QEMU_ARGS"
    [ -z "${EXTRA_QEMU_ARGS:-}" ] || QEMU_ARGS_VALUE="$QEMU_ARGS_VALUE $EXTRA_QEMU_ARGS"
    [ -z "$QMP_SOCKET" ] || QEMU_ARGS_VALUE="$QEMU_ARGS_VALUE -qmp unix:$QMP_SOCKET,server=on,wait=off ${QMP_EXTRA_ARGS:-}"
    python3 "$HOME/xk6/scripts/run-session.py" \
        --dry-run --cwd "$KERNEL_DIR" --make-args "$PLAT_MAKE_ARGS" \
        --with-input --input-devices "$PLAT_INPUT_DEVICES" \
        --require-platform-compliance --duration "$DUR" --interval "$IVL" \
        --first-shot 450 --qemu-args "$QEMU_ARGS_VALUE" --out "$OUT"
    exit $?
fi

echo "T4P_START=$(date -Is) TAG=$TAG DUR=$DUR IVL=$IVL"
echo "OUT=$OUT"
echo "QMP=$QMP_SOCKET CDP_PORT=$CDP_PORT"
echo "KERNEL_DIR=$KERNEL_DIR KERNEL_BIN=$KERNEL_BIN KERNEL_SHA256=$(sha256sum "$KERNEL_BIN" | awk '{print $1}')"
echo "RENDERER_MODE=$([ "$MULTIPROCESS" = 1 ] && echo default-multiprocess || echo single-process-comparison) AUTORUN=$AUTORUN_SCRIPT"
echo "INPUT_KEYBOARD_TRANSPORT=QMP-send-key MOUSE_TRANSPORT=$([ "$FORCE_HMP" = 1 ] && echo HMP-relative-virtio-mouse || echo QMP-input-event) FORCE_HMP=$FORCE_HMP ABS_POINTER=$ABS_POINTER NO_CLAMP=$NO_CLAMP"

# Input rounds intentionally scroll and navigate away. The strict
# official-interaction ready gate runs before input; per-action gates below
# verify JS, keyboard echo, counter click, and layout navigation.
PAGE_URL="file:///usr/share/html-test/interaction.html" \
QMP_SOCKET="$QMP_SOCKET" \
QMP_EXTRA_ARGS="${QMP_EXTRA_ARGS:-}" \
EXTRA_QEMU_ARGS="${EXTRA_QEMU_ARGS:-}" \
KERNEL_DIR="$KERNEL_DIR" \
BASE_IMG="$BASE_IMG" \
PKG_TARBALL="$PKG_TARBALL" \
INJECT_AUTOSTART=1 \
ASSERT_PROFILE=official-interaction \
STRICT_GATE=0 \
FIRST_SHOT=450 \
SINGLE_HOLD_VALUE=760 \
SINGLE_SAMPLE_VALUE=15 \
MP_TRACE_VALUE=0 \
MP_LEDGER_VALUE=0 \
MP_WESTON_CONTINUE=0 \
bash "$HERE/t490_round.sh" "$TAG" "$DUR" "$IVL" \
    "$AUTORUN_SCRIPT" $([ "$EVDEV_PROBE" = "1" ] && printf '%s' evdev_sniff.c) \
    > "$ROUND_LOG" 2>&1 &
ROUND_PID=$!

# Wait for QMP without touching the disk lock or the guest.
i=0
while [ "$i" -lt 300 ]; do
    [ -S "$QMP_SOCKET" ] && break
    kill -0 "$ROUND_PID" 2>/dev/null || die "轮次提前退出，见 $ROUND_LOG"
    sleep 1
    i=$((i + 1))
done
[ -S "$QMP_SOCKET" ] || die "QMP socket 超时: $QMP_SOCKET"

# Expose guest Chromium 9222 for read-only DOM state, then gate on pixels.
python3 "$HERE/qmp_input.py" \
    --socket "$QMP_SOCKET" --output "$WORK/qmp-setup.jsonl" \
    --setup-only --cdp-forward-port "$CDP_PORT" \
    > "$WORK/qmp-setup.log" 2>&1
SETUP_RC=$?
[ "$SETUP_RC" -eq 0 ] || die "QMP setup 失败，见 $WORK/qmp-setup.log"

READY_RC=124
python3 "$HERE/wait_page_ready.py" \
    --socket "$QMP_SOCKET" \
    --out-dir "$READY_DIR" \
    --assert-script "$HERE/ppm_assert.py" \
    --profile official-interaction \
    --timeout "${READY_TIMEOUT:-1400}" --poll 10 \
    > "$WORK/ready.log" 2>&1 &
READY_PID=$!
# A normal round can finish while the QMP socket remains as a stale filesystem
# entry.  Do not leave the readiness checker blocked until its long timeout;
# classify the run immediately when the guest session has ended.
while kill -0 "$READY_PID" 2>/dev/null; do
    if ! kill -0 "$ROUND_PID" 2>/dev/null; then
        echo "READY_ABORT=round-ended-before-strict-page" >> "$WORK/ready.log"
        kill "$READY_PID" 2>/dev/null || true
        wait "$READY_PID" 2>/dev/null || true
        READY_RC=125
        break
    fi
    sleep 1
done
if [ "$READY_RC" -eq 124 ]; then
    wait "$READY_PID"
    READY_RC=$?
fi
if [ "$READY_RC" -ne 0 ]; then
    # Stop the guest after the readiness failure is captured. Waiting for the
    # normal session duration wastes many minutes without adding new evidence.
    TIMEOUT_QUIT_RC=77
    if [ -S "$QMP_SOCKET" ]; then
        PYTHONPATH="$HERE" python3 - "$QMP_SOCKET" "$WORK/qmp-timeout-quit.jsonl" \
            > "$WORK/qmp-timeout-quit.log" 2>&1 <<'PY'
import sys
from pathlib import Path
from qmp_input import QmpClient

client = QmpClient(sys.argv[1], Path(sys.argv[2]), force_hmp=True,
                   qmp_send_key=True, no_clamp=True)
client.connect(10.0)
try:
    print(client.command("quit"))
finally:
    client.close()
PY
        TIMEOUT_QUIT_RC=$?
    fi
    printf 'QMP_TIMEOUT_QUIT_RC=%s\n' "$TIMEOUT_QUIT_RC" >> "$WORK/round.log"
    wait "$ROUND_PID" || true
    die "页面未在输入前达到 official-interaction 严格集，见 $WORK/ready.log"
fi

# Preserve the exact pre-input pixel state, then send real QMP input only.
python3 "$HERE/qmp_input.py" \
    --socket "$QMP_SOCKET" --output "$WORK/qmp-before.jsonl" \
    --screenshot-only "$BEFORE" \
    > "$WORK/qmp-before.log" 2>&1
BEFORE_RC=$?

# 绝对指针：QEMU 侧带 virtio-tablet-pci 时用绝对坐标。相对鼠标的 REL 会被
# libinput 加速放大——2026-11-03 实测 `rel(+271)` 把指针从 0 推到 1279.99，
# `rel(+194)` 推到 799.99，点击全落在右下角，页面零变化。
ABS_ARGS=""
[ "$ABS_POINTER" = "1" ] && ABS_ARGS="--absolute-pointer"
FORCE_HMP_ARGS=""
[ "$FORCE_HMP" = "1" ] && FORCE_HMP_ARGS="--force-hmp"
NO_CLAMP_ARGS=""
[ "$NO_CLAMP" = "1" ] && NO_CLAMP_ARGS="--no-clamp"
SELFTEST_ARGS=""
[ "${SELFTEST_ONLY:-0}" = "1" ] && SELFTEST_ARGS="--self-test-only"
ECHO_ARGS=""
[ "${ECHO:-0}" = "1" ] && ECHO_ARGS="--echo-after-selftest"
ECHO_SHOTS=""
[ "${ECHO:-0}" = "1" ] && ECHO_SHOTS="--shot-dir $WORK/echo"
KBD_ECHO_ARGS=""
[ "${KBD_ECHO:-0}" = "1" ] && KBD_ECHO_ARGS="--kbd-echo"

if [ "$INPUT_MODE" = "kbd" ]; then
    # 键盘优先：先在页面空白处点一下把窗口激活（desktop-shell 下第一次点击常常
    # 只送到 shell、不投给客户端），再 Tab 聚焦第一个可聚焦控件（interaction 页
    # DOM 里第一个是「运行自检」按钮），Enter 触发它的 click。
    # 这条路径完全不依赖按钮坐标，用来把"Weston 有没有把输入转给 Chromium"和
    # "鼠标坐标点没点准"两件事分开。
    mkdir -p "$WORK/kbd"
    python3 "$HERE/qmp_input.py" \
        --socket "$QMP_SOCKET" --output "$QMP_LOG" \
        --qmp-send-key $FORCE_HMP_ARGS $NO_CLAMP_ARGS --kbd-probe --shot-dir "$WORK/kbd" \
        --ready-wait 0 --kbd-settle 3 \
        --pre-click-x "${KBD_PRECLICK_X:-640}" --pre-click-y "${KBD_PRECLICK_Y:-400}" \
        > "$WORK/qmp-input.log" 2>&1
    INPUT_RC=$?
    AFTER="$WORK/kbd/after-enter.ppm"
else
    # Raw one-shot relative coordinates are accelerated by libinput and can
    # miss controls. Use the selected real-input step mode for keyboard echo,
    # the counter click, and CSS navigation.
    mkdir -p "$WORK/interaction-shots"
    INTERACTION_FORCE_HMP="$FORCE_HMP" \
    INTERACTION_ABSOLUTE="$ABS_POINTER" \
    INTERACTION_POINTER_MODE="${INTERACTION_POINTER_MODE:-step4}" \
        python3 "$HERE/interaction_score_driver.py" \
        --socket "$QMP_SOCKET" --output "$QMP_LOG" \
        --shot-dir "$WORK/interaction-shots" \
        --navigation-wait "${INPUT_NAVIGATION_WAIT:-180}" \
        > "$WORK/qmp-input.log" 2>&1
    INPUT_RC=$?
    AFTER="$WORK/interaction-shots/after-selftest.ppm"
fi

# CDP 只作辅助：赛题只认 screendump，且当前 platform.env 没有 hostfwd，
# guest 的 9222 从宿主不可达（r1–r5 的 cdp_rc 恒 1）。把它从 PASS 里摘出来，
# 避免"像素对了但 DOM 读不到"被误判成整轮失败（report/68 §八）。
CDP_RC=77
if [ "${CDP_AUX:-1}" = "1" ]; then
    python3 "$HERE/cdp_probe.py" \
        --host 127.0.0.1 --port "$CDP_PORT" \
        --output "$CDP_LOG" --connect-timeout 5 \
        > "$STATE_JSON" 2> "$WORK/cdp-probe.log"
    CDP_RC=$?
fi

QMP_QUIT_RC=77
if [ "$INPUT_MODE" = "pointer" ]; then
    # A score-page input round ends as soon as all real interactions are captured.
    PYTHONPATH="$HERE" python3 - "$QMP_SOCKET" "$QMP_LOG" > "$WORK/qmp-quit.log" 2>&1 <<'PY'
import sys
from pathlib import Path
from qmp_input import QmpClient
client = QmpClient(sys.argv[1], Path(sys.argv[2]), force_hmp=True,
                   qmp_send_key=True, no_clamp=True)
client.connect(10.0)
try:
    print(client.command("quit"))
finally:
    client.close()
PY
    QMP_QUIT_RC=$?
    echo "QMP_QUIT_RC=$QMP_QUIT_RC" >> "$WORK/round.log"
fi

PPM_RC=99
if [ -f "$AFTER" ]; then
    python3 "$HERE/ppm_assert.py" "$AFTER" \
        --profile official-interaction --expect-input --strict \
        --json "$AFTER_JSON" > "$WORK/after-assert.log" 2>&1
    PPM_RC=$?
fi

PIXEL_RC=0
if [ -f "$BEFORE" ] && [ -f "$AFTER" ]; then
    : > "$WORK/pixel-policy.log"
    for ppm in "$BEFORE" "$AFTER"; do
        python3 "$HERE/../verify_pixel_policy.py" "$ppm" \
            >> "$WORK/pixel-policy.log" 2>&1 || PIXEL_RC=$?
    done
else
    PIXEL_RC=99
fi

# 输入是否真的改变了画面：这是与"输入是否到达设备"完全不同的一个问题。
# r1–r5 的教训是 QMP 全返回成功、evdev 收齐 41 条事件，而画面逐字节相同。
DIFF_JSON="$WORK/input-diff.json"
DIFF_CHANGED=0
if [ -f "$BEFORE" ] && [ -f "$AFTER" ]; then
    python3 "$HERE/ppm_assert.py" "$BEFORE" --diff "$AFTER" --json "$DIFF_JSON" \
        > "$WORK/input-diff.log" 2>&1 && DIFF_CHANGED=1
fi

# CDP 状态只作辅助记录：读到就写进证据，读不到不影响门禁。
STATE_OK=77
if [ "$CDP_RC" -eq 0 ]; then
    python3 - "$STATE_JSON" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
clicks = str(state.get("clicks", "0")).strip()
raise SystemExit(0 if state.get("kb") == "hello x-kernel"
                 and clicks.isdigit() and int(clicks) >= 1
                 and "interaction.html" in str(state.get("url", "")) else 1)
PY
    STATE_OK=$?
fi

wait "$ROUND_PID"
ROUND_RC=$?

SCORE_GATE_RC=77
if [ "$INPUT_MODE" = "pointer" ]; then
    cp -f "$QMP_LOG" "$WORK/interaction-events.jsonl"
    python3 "$HERE/interaction_score_gate.py" "$WORK" \
        --out "$OUT/interaction-score-gate.json" \
        --ready-rc "$READY_RC" --driver-rc "$INPUT_RC" \
        --round-rc "$ROUND_RC" --strict \
        > "$WORK/interaction-score-gate.log" 2>&1
    SCORE_GATE_RC=$?
fi

# Copy evidence after the round; never delete the source trail.
if [ -d "$OUT" ]; then
    cp -f "$ROUND_LOG" "$OUT/round-orchestrator.log" 2>/dev/null || true
    cp -f "$QMP_LOG" "$OUT/qmp-events.jsonl" 2>/dev/null || true
    cp -f "$CDP_LOG" "$OUT/cdp-events.jsonl" 2>/dev/null || true
    cp -f "$STATE_JSON" "$OUT/final-state.json" 2>/dev/null || true
    cp -f "$AFTER_JSON" "$OUT/after-assert.json" 2>/dev/null || true
    cp -f "$READY_DIR"/ready-*.ppm "$OUT/" 2>/dev/null || true
    cp -f "$WORK"/kbd/*.ppm "$OUT/" 2>/dev/null || true
    if [ -d "$WORK/interaction-shots" ]; then cp -a "$WORK/interaction-shots" "$OUT/"; fi
    if [ -f "$WORK/interaction-events.jsonl" ]; then cp -f "$WORK/interaction-events.jsonl" "$OUT/"; fi
    if [ -f "$WORK/interaction-score-gate.log" ]; then cp -f "$WORK/interaction-score-gate.log" "$OUT/"; fi
    if [ -f "$WORK/qmp-quit.log" ]; then cp -f "$WORK/qmp-quit.log" "$OUT/"; fi
    cp -f "$DIFF_JSON" "$OUT/input-diff.json" 2>/dev/null || true
    cp -f "$AFTER" "$OUT/input-after.ppm" 2>/dev/null || true
    cp -f "$BEFORE" "$OUT/input-before.ppm" 2>/dev/null || true
fi

PASS=0
if [ "$INPUT_MODE" = "pointer" ]; then
    [ "$BEFORE_RC" -eq 0 ] && [ "$INPUT_RC" -eq 0 ] && \
        [ "$PPM_RC" -eq 0 ] && [ "$PIXEL_RC" -eq 0 ] && \
        [ "$DIFF_CHANGED" -eq 1 ] && [ "$SCORE_GATE_RC" -eq 0 ] && \
        [ "$QMP_QUIT_RC" -eq 0 ] && [ "$ROUND_RC" -eq 0 ] && PASS=1
else
    [ "$BEFORE_RC" -eq 0 ] && [ "$INPUT_RC" -eq 0 ] && \
        [ "$PPM_RC" -eq 0 ] && [ "$PIXEL_RC" -eq 0 ] && \
        [ "$DIFF_CHANGED" -eq 1 ] && [ "$ROUND_RC" -eq 0 ] && PASS=1
fi

cat > "$GATE_JSON" <<EOF
{
  "tag": "$TAG",
  "renderer_mode": "$([ "$MULTIPROCESS" = 1 ] && echo default-multiprocess || echo single-process-comparison)",
  "sandbox_mode": "$([ "$MULTIPROCESS" = 1 ] && echo diagnostic-no-sandbox || echo single-process-comparison)",
  "input_mode": "$INPUT_MODE",
  "keyboard_transport": "QMP-send-key",
  "mouse_transport": "$([ "$FORCE_HMP" = 1 ] && echo HMP-relative-virtio-mouse || echo QMP-input-event)",
  "absolute_pointer": $ABS_POINTER,
  "no_clamp": $NO_CLAMP,
  "ready_rc": $READY_RC,
  "before_rc": $BEFORE_RC,
  "input_rc": $INPUT_RC,
  "cdp_rc": $CDP_RC,
  "cdp_role": "auxiliary",
  "ppm_assert_rc": $PPM_RC,
  "pixel_policy_rc": $PIXEL_RC,
  "input_changed_pixels": $DIFF_CHANGED,
  "dom_state_ok": $STATE_OK,
  "round_rc": $ROUND_RC,
  "qmp_quit_rc": $QMP_QUIT_RC,
  "interaction_score_gate_rc": $SCORE_GATE_RC,
  "pass": $PASS
}
EOF
[ -d "$OUT" ] && cp -f "$GATE_JSON" "$OUT/input-gate.json" 2>/dev/null || true

echo "T4P_DONE=$(date -Is) PASS=$PASS"
echo "GATE=$GATE_JSON"
echo "OUT=$OUT"
[ "$PASS" -eq 1 ]
