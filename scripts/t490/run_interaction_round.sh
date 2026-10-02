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

mkdir -p "$OUT"
rm -f "$QMP_SOCKET"

echo "TAG=$TAG DUR=$DUR IVL=$IVL QMP_SOCKET=$QMP_SOCKET OUT=$OUT" \
    | tee "$OUT/interaction-manifest.txt"

PAGE_URL="file:///usr/share/html-test/interaction.html" \
QMP_SOCKET="$QMP_SOCKET" \
ASSERT_PROFILE=legacy \
FIRST_SHOT=120 \
SINGLE_HOLD_VALUE="$((DUR - 20))" \
SINGLE_SAMPLE_VALUE=15 \
bash "$ROOT/scripts/t490/t490_round.sh" "$TAG" "$DUR" "$IVL" \
    autorun_single_initial.sh > "$OUT/round-orchestrator.log" 2>&1 &
ROUND_PID=$!

python3 "$HERE/qmp_input.py" \
    --socket "$QMP_SOCKET" \
    --output "$OUT/input-events.jsonl" \
    >> "$OUT/input-driver.log" 2>&1
INPUT_RC=$?

wait "$ROUND_PID"
ROUND_RC=$?

{
    echo "INPUT_RC=$INPUT_RC"
    echo "ROUND_RC=$ROUND_RC"
    echo "FINISHED_AT=$(date -Is)"
} | tee -a "$OUT/interaction-manifest.txt"

rm -f "$QMP_SOCKET"
[ "$INPUT_RC" -eq 0 ] && [ "$ROUND_RC" -eq 0 ]
