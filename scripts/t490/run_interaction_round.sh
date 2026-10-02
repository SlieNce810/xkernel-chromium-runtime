#!/usr/bin/env bash
# Run the single-process interaction page and drive it through QEMU QMP.
#
# The script is intended for the T490 Linux host.  It starts the existing
# t490_round image/session workflow, waits for its QMP endpoint, sends real
# keyboard/mouse events, and leaves the event transcript beside the normal
# evidence files.

set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TAG="${1:-interaction-single}"
DUR="${2:-300}"
IVL="${3:-30}"
QMP_SOCKET="${QMP_SOCKET:-/tmp/xk6-qmp-${TAG}.sock}"
OUT="$HOME/xk6/evidence/$(date +%Y-%m-%d)_t490-$TAG"
TMP_PREFIX="/tmp/xk6-interaction-${TAG}"
ROUND_LOG="${TMP_PREFIX}-round.log"
DRIVER_LOG="${TMP_PREFIX}-driver.log"
EVENTS_LOG="${TMP_PREFIX}-events.jsonl"
MANIFEST_TMP="${TMP_PREFIX}-manifest.txt"

# Reuse the same known-good image and p31 runtime overlay as the validated
# single-process baseline.  The generic t490_round defaults point at an older
# diagnostic image that has no Weston/eudev runtime and would fail before QMP
# could ever reach Chromium.
BASE_IMG="${BASE_IMG:-$HOME/x-kernel/images/agentos-weston.img}"
PKG_TARBALL="${PKG_TARBALL:-$HOME/xk6/tmp/eudev-seatprobe-libinput-swiftshader-p31.tar.gz}"
GL_VARIANT="${GL_VARIANT:-angle-swiftshader}"
GPU_MODEL="${GPU_MODEL:-in-process}"
INJECT_AUTOSTART="${INJECT_AUTOSTART:-1}"
QMP_INPUT_MODE="${QMP_INPUT_MODE:-qmp}"
QMP_KEY_MODE="${QMP_KEY_MODE:-send-key}"
QMP_INPUT_TABLET="${QMP_INPUT_TABLET:-1}"
QMP_INPUT_ARGS=()
case "$QMP_INPUT_MODE" in
    hmp) QMP_INPUT_ARGS=(--force-hmp) ;;
    qmp) ;;
    *) echo "!! 非法 QMP_INPUT_MODE=$QMP_INPUT_MODE（允许 hmp|qmp）"; exit 1 ;;
esac
case "$QMP_KEY_MODE" in
    hmp) ;;
    send-key) QMP_INPUT_ARGS+=(--qmp-send-key) ;;
    *) echo "!! 非法 QMP_KEY_MODE=$QMP_KEY_MODE（允许 hmp|send-key）"; exit 1 ;;
esac
case "$QMP_INPUT_TABLET" in
    0) ;;
    1)
        QMP_INPUT_ARGS+=(--absolute-pointer)
        QMP_EXTRA_ARGS="${QMP_EXTRA_ARGS:--device virtio-keyboard-pci -device virtio-mouse-pci -device virtio-tablet-pci}"
        export QMP_EXTRA_ARGS
        ;;
    *) echo "!! 非法 QMP_INPUT_TABLET=$QMP_INPUT_TABLET（允许 0|1）"; exit 1 ;;
esac

rm -f "$QMP_SOCKET" "$ROUND_LOG" "$DRIVER_LOG" "$EVENTS_LOG" "$MANIFEST_TMP"

echo "TAG=$TAG DUR=$DUR IVL=$IVL QMP_SOCKET=$QMP_SOCKET OUT=$OUT" \
    | tee "$MANIFEST_TMP"

PAGE_URL="file:///usr/share/html-test/interaction.html" \
QMP_SOCKET="$QMP_SOCKET" \
BASE_IMG="$BASE_IMG" \
PKG_TARBALL="$PKG_TARBALL" \
GL_VARIANT="$GL_VARIANT" \
GPU_MODEL="$GPU_MODEL" \
INJECT_AUTOSTART="$INJECT_AUTOSTART" \
ASSERT_PROFILE=legacy \
FIRST_SHOT=120 \
SINGLE_HOLD_VALUE="$((DUR - 20))" \
SINGLE_SAMPLE_VALUE=15 \
bash "$ROOT/scripts/t490/t490_round.sh" "$TAG" "$DUR" "$IVL" \
    autorun_single_initial.sh > "$ROUND_LOG" 2>&1 &
ROUND_PID=$!

python3 "$HERE/qmp_input.py" \
    --socket "$QMP_SOCKET" \
    --output "$EVENTS_LOG" \
    "${QMP_INPUT_ARGS[@]}" \
    >> "$DRIVER_LOG" 2>&1
INPUT_RC=$?

wait "$ROUND_PID"
ROUND_RC=$?

# t490_round creates OUT only after all validation has passed.  Copy temporary
# control-plane files after the round, so its immutable-directory guard is not
# defeated by the orchestrator itself.
if [ -d "$OUT" ]; then
    cp -f "$MANIFEST_TMP" "$OUT/interaction-manifest.txt"
    cp -f "$ROUND_LOG" "$OUT/round-orchestrator.log"
    cp -f "$DRIVER_LOG" "$OUT/input-driver.log"
    [ -f "$EVENTS_LOG" ] && cp -f "$EVENTS_LOG" "$OUT/input-events.jsonl"
fi

{
    echo "INPUT_RC=$INPUT_RC"
    echo "ROUND_RC=$ROUND_RC"
    echo "FINISHED_AT=$(date -Is)"
} | tee -a "$MANIFEST_TMP"
if [ -d "$OUT" ]; then
    cp -f "$MANIFEST_TMP" "$OUT/interaction-manifest.txt"
fi

rm -f "$QMP_SOCKET"
rm -f "$ROUND_LOG" "$DRIVER_LOG" "$EVENTS_LOG" "$MANIFEST_TMP"
[ "$INPUT_RC" -eq 0 ] && [ "$ROUND_RC" -eq 0 ]
