#!/usr/bin/env bash
# Run one non-input scoring page through the default multiprocess browser.
#
# Supported items are html (index.html) and css (layout.html).  JavaScript is
# deliberately a separate runner because its score requires a real user action
# on interaction.html; use run_javascript_round_mp.sh for that item.
set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
ITEM="${1:-}"
TAG="${2:-score-${ITEM}-mp}"
# Pure TCG Chromium 149 needs a long bootstrap window before the first
# renderer frame.  Keep the default long enough for the real page gate;
# callers may still pass a shorter diagnostic duration explicitly.
DUR="${3:-1100}"
IVL="${4:-60}"
BASE_IMG="${BASE_IMG:-$HOME/x-kernel/images/pkg-installed.img}"
PKG_TARBALL="${PKG_TARBALL:-}"
WORK="$HOME/xk6/tmp/score-page-$TAG"
ROUND_LOG="$WORK/round.log"

die() { echo "SCORE_PAGE_MP_ABORT: $*" >&2; exit 2; }
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    echo "Usage: $0 <html|css> [tag] [duration] [interval]"
    exit 0
fi
case "$ITEM" in
    html) PAGE="index.html"; PROFILE="official-index" ;;
    css) PAGE="layout.html"; PROFILE="official-layout" ;;
    *) die "用法: $0 <html|css> [tag] [duration] [interval]" ;;
esac
[ "$(uname -s)" = Linux ] || die "只能在 T490/Linux 主机运行"
[ -f "$BASE_IMG" ] || die "基础镜像不存在: $BASE_IMG"
if [ -n "$PKG_TARBALL" ] && [ ! -f "$PKG_TARBALL" ]; then
    die "运行时 overlay 不存在: $PKG_TARBALL"
fi
bash "$HERE/verify_chromium_image.sh" "$BASE_IMG" "${EXPECTED_CHROMIUM_MAJOR:-149}" \
    || die "基础镜像 Chromium 版本不匹配"
mkdir -p "$WORK"
rm -f "$ROUND_LOG"

echo "SCORE_PAGE_MP_START=$(date -Is) item=$ITEM page=$PAGE tag=$TAG"
PAGE_URL="file:///usr/share/html-test/$PAGE" \
BASE_IMG="$BASE_IMG" \
PKG_TARBALL="$PKG_TARBALL" \
INJECT_AUTOSTART=1 \
OZ_PLATFORM=wayland \
MP_TRACE_VALUE=0 \
MP_LEDGER_VALUE=0 \
MP_WESTON_CONTINUE=0 \
ASSERT_PROFILE="$PROFILE" \
STRICT_GATE=0 \
FIRST_SHOT="${FIRST_SHOT:-240}" \
bash "$HERE/t490_round.sh" "$TAG" "$DUR" "$IVL" \
    autorun_mp_diag.sh > "$ROUND_LOG" 2>&1 &
ROUND_PID=$!
wait "$ROUND_PID"
ROUND_RC=$?

EVID="$HOME/xk6/evidence/$(date +%Y-%m-%d)_t490-$TAG"
if [ ! -d "$EVID" ]; then
    echo "SCORE_PAGE_MP_NO_EVIDENCE=$EVID"
    exit 1
fi
cp -f "$ROUND_LOG" "$EVID/score-page-round.log" 2>/dev/null || true

# Normalize the guest console into a recomputable event ledger.  The raw log
# remains authoritative; JSONL is a derived artifact for gates and reports.
if [ -f "$EVID/console.log" ] && [ -f "$HERE/console_to_jsonl.py" ]; then
    python3 "$HERE/console_to_jsonl.py" "$EVID/console.log" "$EVID/events.jsonl" \
        >"$EVID/events-converter.log" 2>&1 || {
        echo "SCORE_PAGE_MP_EVENTS_JSONL=FAIL" >&2
        exit 1
    }
    sha256sum "$EVID/events.jsonl" >"$EVID/events.jsonl.sha256" 2>/dev/null || {
        echo "SCORE_PAGE_MP_EVENTS_SHA256=FAIL" >&2
        exit 1
    }
fi

python3 - "$EVID" "$ROOT" "$PROFILE" "$ITEM" "$ROUND_RC" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

evid = Path(sys.argv[1])
root = Path(sys.argv[2])
profile = sys.argv[3]
item = sys.argv[4]
round_rc = int(sys.argv[5])
shots = sorted((evid / "screenshots").glob("*.ppm"))
rows = []
for image in shots:
    proc = subprocess.run(
        [sys.executable, str(root / "scripts/t490/ppm_assert.py"), str(image),
         "--profile", profile, "--strict", "--quiet"],
        text=True, capture_output=True,
    )
    rows.append({"path": str(image), "rc": proc.returncode})
passed = [row for row in rows if row["rc"] == 0]
gate = round_rc == 0 and bool(passed)
payload = {
    "item": item,
    "mode": "default-multiprocess",
    "sandbox_mode": "diagnostic-no-sandbox",
    "page_profile": profile,
    "round_rc": round_rc,
    "screenshots": rows,
    "passing_screenshots": len(passed),
    "pass": gate,
}
(evid / "score-page-gate.json").write_text(
    json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
print(json.dumps(payload, ensure_ascii=False))
raise SystemExit(0 if gate else 1)
PY
