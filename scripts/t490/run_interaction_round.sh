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

rm -f "$QMP_SOCKET" "$ROUND_LOG" "$DRIVER_LOG" "$EVENTS_LOG" "$MANIFEST_TMP"

echo "TAG=$TAG DUR=$DUR IVL=$IVL QMP_SOCKET=$QMP_SOCKET OUT=$OUT" \
    | tee "$MANIFEST_TMP"

PAGE_URL="file:///usr/share/html-test/interaction.html" \
QMP_SOCKET="$QMP_SOCKET" \
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
