#!/usr/bin/env bash
# 决赛页签项：默认多进程 Chromium + 两个真实 URL + QMP Ctrl+Tab。
#
# 这个入口和历史的 run_tabs_round.sh 有意分开。历史入口使用
# autorun_single_initial.sh，只能做单进程对照；本入口才允许进入决赛页签证据。
set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TAG="${1:-tabs-mp}"
DUR="${2:-1100}"
IVL="${3:-60}"
QMP_SOCKET="${QMP_SOCKET:-/tmp/xk6-qmp-${TAG}.sock}"
WORK="$HOME/xk6/tmp/tabs-mp-$TAG"
ROUND_LOG="$WORK/round.log"
INPUT_LOG="$WORK/tabs-input.log"
EVENTS_LOG="$WORK/tabs-events.jsonl"
SHOT_DIR="$WORK/shots"
BASE_IMG="${BASE_IMG:-$HOME/x-kernel/images/pkg-installed.img}"
PKG_TARBALL="${PKG_TARBALL:-$HOME/xk6/tmp/pkgs-fetch.tar.gz}"

die() { echo "TABS_MP_ABORT: $*" >&2; exit 2; }
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    echo "Usage: $0 [tag] [duration] [interval]"
    echo "Run two real Chromium URLs and switch with QMP Ctrl+Tab in default multiprocess mode."
    exit 0
fi

[ "$(uname -s)" = Linux ] || die "只能在 T490/Linux 主机运行"
[ -f "$BASE_IMG" ] || die "基础镜像不存在: $BASE_IMG"
if [ -n "$PKG_TARBALL" ] && [ ! -f "$PKG_TARBALL" ]; then
    die "运行时 overlay 不存在: $PKG_TARBALL"
fi
bash "$HERE/verify_chromium_image.sh" "$BASE_IMG" "${EXPECTED_CHROMIUM_MAJOR:-149}" \
    || die "基础镜像 Chromium 版本不匹配"
[ ! -e "$QMP_SOCKET" ] || die "QMP socket 已存在: $QMP_SOCKET"
mkdir -p "$WORK" "$SHOT_DIR"
rm -f "$ROUND_LOG" "$INPUT_LOG" "$EVENTS_LOG"

echo "TABS_MP_START=$(date -Is) TAG=$TAG DUR=$DUR IVL=$IVL"
echo "OUT_EXPECTED=$HOME/xk6/evidence/$(date +%Y-%m-%d)_t490-$TAG"

PAGE_URL="file:///usr/share/html-test/index.html" \
SECOND_URL="file:///usr/share/html-test/layout.html" \
QMP_SOCKET="$QMP_SOCKET" \
BASE_IMG="$BASE_IMG" \
PKG_TARBALL="$PKG_TARBALL" \
INJECT_AUTOSTART=1 \
OZ_PLATFORM=wayland \
MP_TRACE_VALUE=0 \
MP_LEDGER_VALUE=1 \
MP_MAX_SECONDS="${MP_MAX_SECONDS:-1000}" \
MP_WESTON_CONTINUE=0 \
STRICT_GATE=0 \
FIRST_SHOT="${FIRST_SHOT:-285}" \
bash "$HERE/t490_round.sh" "$TAG" "$DUR" "$IVL" \
    "${TABS_AUTORUN:-autorun_mp_diag.sh}" > "$ROUND_LOG" 2>&1 &
ROUND_PID=$!

i=0
while [ "$i" -lt 360 ] && [ ! -S "$QMP_SOCKET" ]; do
    kill -0 "$ROUND_PID" 2>/dev/null || break
    sleep 1
    i=$((i + 1))
done

INPUT_RC=1
if [ -S "$QMP_SOCKET" ]; then
    if [ "${TABS_WINDOWS:-0}" = "1" ]; then
        python3 "$HERE/tabs_windows_input.py" \
            --socket "$QMP_SOCKET" \
            --output "$EVENTS_LOG" \
            --shot-dir "$SHOT_DIR" \
            --ready-wait "${TABS_READY_WAIT:-900}" \
            --settle "${TABS_SETTLE:-12}" \
            > "$INPUT_LOG" 2>&1
    elif [ "${TABS_REAL_NAV:-0}" = "1" ]; then
        python3 "$HERE/tabs_real_navigation.py" \
            --socket "$QMP_SOCKET" \
            --output "$EVENTS_LOG" \
            --shot-dir "$SHOT_DIR" \
            --wait "${TABS_NAV_WAIT:-600}" \
            --ready-wait "${TABS_READY_WAIT:-1000}" \
            --profile-poll "${TABS_PROFILE_POLL:-20}" \
            > "$INPUT_LOG" 2>&1
    else
        python3 "$HERE/tabs_input.py" \
            --socket "$QMP_SOCKET" \
            --output "$EVENTS_LOG" \
            --shot-dir "$SHOT_DIR" \
            --ready-wait "${TABS_READY_WAIT:-90}" \
            --settle "${TABS_SETTLE:-8}" \
            --ready-profile "${TABS_READY_PROFILE:-official-index}" \
            --switch-profile "${TABS_SWITCH_PROFILE:-official-layout}" \
            --switch-timeout "${TABS_SWITCH_TIMEOUT:-300}" \
            --profile-poll "${TABS_PROFILE_POLL:-20}" \
            > "$INPUT_LOG" 2>&1
    fi
    INPUT_RC=$?
else
    echo "QMP_SOCKET_TIMEOUT after ${i}s" | tee "$INPUT_LOG"
fi

wait "$ROUND_PID"
ROUND_RC=$?

EVID="$HOME/xk6/evidence/$(date +%Y-%m-%d)_t490-$TAG"
if [ -d "$EVID" ]; then
    cp -f "$ROUND_LOG" "$EVID/tabs-round-orchestrator.log" 2>/dev/null || true
    cp -f "$INPUT_LOG" "$EVID/tabs-input.log" 2>/dev/null || true
    cp -f "$EVENTS_LOG" "$EVID/tabs-events.jsonl" 2>/dev/null || true
    mkdir -p "$EVID/tabs-shots"
    cp -f "$SHOT_DIR"/*.ppm "$EVID/tabs-shots/" 2>/dev/null || true
fi

GATE_RC=1
if [ -d "$EVID" ]; then
    python3 - "$EVID" "$ROOT" "$INPUT_RC" "$ROUND_RC" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

evid = Path(sys.argv[1])
root = Path(sys.argv[2])
input_rc = int(sys.argv[3])
round_rc = int(sys.argv[4])
shots = evid / "tabs-shots"
checks = {
    "tab_a_before": shots / "tab-a-before.ppm",
    "tab_b_after_ctrl_tab": shots / "tab-b-after-ctrl-tab.ppm",
    "tab_a_after_return": shots / "tab-a-after-return.ppm",
}
profiles = {
    "tab_a_before": "official-index",
    "tab_b_after_ctrl_tab": "official-layout",
    "tab_a_after_return": "official-index",
}
rows = {}
for name, image in checks.items():
    if not image.exists():
        rows[name] = {"path": str(image), "exists": False, "rc": 99}
        continue
    proc = subprocess.run(
        [sys.executable, str(root / "scripts/t490/ppm_assert.py"), str(image),
         "--profile", profiles[name], "--strict", "--quiet"],
        text=True, capture_output=True,
    )
    rows[name] = {"path": str(image), "exists": True, "rc": proc.returncode}
gate = input_rc == 0 and round_rc == 0 and all(row["rc"] == 0 for row in rows.values())
payload = {
    "mode": "default-multiprocess",
    "sandbox_mode": "diagnostic-no-sandbox",
    "input_transport": "qmp-real-keyboard",
    "action": "ctrl-tab,ctrl-tab",
    "input_rc": input_rc,
    "round_rc": round_rc,
    "checks": rows,
    "pass": bool(gate),
}
(evid / "tabs-gate.json").write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(payload, ensure_ascii=False))
raise SystemExit(0 if gate else 1)
PY
    GATE_RC=$?
else
    echo "TABS_MP_NO_EVIDENCE=$EVID"
fi

echo "TABS_MP_DONE=$(date -Is) INPUT_RC=$INPUT_RC ROUND_RC=$ROUND_RC GATE_RC=$GATE_RC"
exit "$GATE_RC"
