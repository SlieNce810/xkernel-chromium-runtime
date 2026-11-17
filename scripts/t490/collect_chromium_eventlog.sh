#!/usr/bin/env bash
# Extract Chromium MP_EVENT records from a guest console log and validate the
# complete browser -> zygote -> renderer -> compositor -> Wayland chain.
set -u
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONSOLE="${1:-}"
OUT_DIR="${2:-}"
CRITERION="${3:-full-render}"

if [[ -z "$CONSOLE" || -z "$OUT_DIR" ]]; then
    echo "usage: $0 CONSOLE_LOG EVIDENCE_DIR [full-render|process-structure]" >&2
    exit 64
fi
case "$CRITERION" in
    full-render|process-structure) ;;
    *) echo "unsupported event criterion: $CRITERION" >&2; exit 64 ;;
esac
if [[ ! -f "$CONSOLE" ]]; then
    echo "[FAIL] console log missing: $CONSOLE" >&2
    exit 2
fi
mkdir -p "$OUT_DIR"

validation="$OUT_DIR/events-validation.log"
summary="$OUT_DIR/events-summary.json"
# Keep the original console immutable; extraction is a separate derived file.
grep -F 'MP_EVENT ' "$CONSOLE" > "$OUT_DIR/events.raw.log" || true
python3 "$ROOT/scripts/multiprocess_eventlog.py" "$OUT_DIR/events.raw.log" \
    --criterion "$CRITERION" --summary "$summary" --strict > "$validation"
rc=$?
if [[ "$rc" -ne 0 ]]; then
    echo "[FAIL] Chromium event chain did not pass; see $summary" >&2
    exit "$rc"
fi
echo "[PASS] event criterion $CRITERION validated: $summary"
