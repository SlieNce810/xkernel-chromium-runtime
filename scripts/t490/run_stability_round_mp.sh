#!/usr/bin/env bash
# One default-multiprocess stability round: strict page gate, ten real QMP
# reloads at two-minute intervals, then a 30-minute host-monotonic hold.
set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TAG="${1:-stability-mp-2g}"
DUR="${2:-4200}"
IVL="${3:-30}"
QMP_SOCKET="${QMP_SOCKET:-/tmp/xk6-qmp-stability-${TAG}.sock}"
BASE_IMG="${BASE_IMG:-$HOME/x-kernel/images/pkg-installed.img}"
PKG_TARBALL="${PKG_TARBALL-}"
unset PLAT_MEM_OVERRIDE
RUN_DATE="$(date +%Y-%m-%d)"
EVID="$HOME/xk6/evidence/${RUN_DATE}_t490-$TAG"
WORK="$HOME/xk6/tmp/stability-$TAG"
ROUND_LOG="$WORK/round.log"
DRIVER_DIR="$WORK/driver"

die() { echo "STABILITY_ROUND_ABORT: $*" >&2; exit 2; }
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<'EOF'
Usage: run_stability_round_mp.sh [tag] [max-session-seconds] [screendump-interval]
Default: 4200 seconds max; strict official-index page gate; 10 real Ctrl+R
reloads every 120 seconds; 1800 seconds measured after first strict page PASS.
Formal memory comes from platform.env (2 GiB); unset PLAT_MEM_OVERRIDE.
EOF
    exit 0
fi
[ "$(uname -s)" = Linux ] || die "只能在 T490/Linux 主机运行"
[ -f "$BASE_IMG" ] || die "基础镜像不存在: $BASE_IMG"
[ -d "$HERE" ] || die "T490 scripts directory missing"
[ ! -e "$EVID" ] || die "证据目录已存在，拒绝覆盖: $EVID"
[ ! -e "$QMP_SOCKET" ] || die "QMP socket 已存在，拒绝覆盖: $QMP_SOCKET"
ps -eo comm= 2>/dev/null | grep -qx 'qemu-system-aarch64' && die "已有 QEMU 在运行，拒绝并行"
bash "$HERE/verify_chromium_image.sh" "$BASE_IMG" "${EXPECTED_CHROMIUM_MAJOR:-149}" \
    || die "基础镜像 Chromium 版本不匹配"

mkdir -p "$WORK" "$DRIVER_DIR"
rm -f "$ROUND_LOG"

echo "STABILITY_START=$(date -Is) TAG=$TAG DUR=$DUR IVL=$IVL"
echo "EVIDENCE=$EVID"

PAGE_URL="file:///usr/share/html-test/index.html" \
QMP_SOCKET="$QMP_SOCKET" \
BASE_IMG="$BASE_IMG" \
PKG_TARBALL="$PKG_TARBALL" \
INJECT_AUTOSTART=1 \
OZ_PLATFORM=wayland \
MP_TRACE_VALUE=0 \
MP_LEDGER_VALUE=1 \
MP_SAMPLE_SECONDS=5 \
MP_MAX_SECONDS="${MP_MAX_SECONDS:-$((DUR - 200))}" \
MP_HOLD_SECONDS=40 \
MP_WESTON_CONTINUE=0 \
EXTRA_FLAGS_VALUE="${EXTRA_FLAGS_VALUE:---js-flags=--jitless}" \
ASSERT_PROFILE=official-index \
STRICT_GATE=0 \
FIRST_SHOT=240 \
bash "$HERE/t490_round.sh" "$TAG" "$DUR" "$IVL" autorun_mp_diag.sh > "$ROUND_LOG" 2>&1 &
ROUND_PID=$!

i=0
while [ "$i" -lt 360 ] && [ ! -S "$QMP_SOCKET" ]; do
    kill -0 "$ROUND_PID" 2>/dev/null || die "QEMU 会话提前退出，见 $ROUND_LOG"
    sleep 1
    i=$((i + 1))
done
[ -S "$QMP_SOCKET" ] || die "QMP socket 超时: $QMP_SOCKET"
[ -f "$EVID/console.log" ] || die "console.log 尚未创建: $EVID"

python3 "$HERE/stability_driver.py" \
    --socket "$QMP_SOCKET" \
    --run-id "$TAG" \
    --out-dir "$DRIVER_DIR" \
    --events "$DRIVER_DIR/stability-events.jsonl" \
    --console-log "$EVID/console.log" \
    --duration-seconds 1800 \
    --reload-count 10 \
    --reload-interval-seconds 120 \
    --reload-window-seconds "${STABILITY_RELOAD_WINDOW:-90}" \
    --ready-timeout-seconds "${STABILITY_READY_TIMEOUT:-2400}" \
    --poll-seconds 5 \
    --heartbeat-seconds 30 \
    --schedule-tolerance-seconds "${STABILITY_SCHEDULE_TOLERANCE:-10}" \
    --profile official-index \
    > "$WORK/stability-driver.log" 2>&1
DRIVER_RC=$?

# The QMP driver sends a normal QEMU quit at the end of the measured hold.
wait "$ROUND_PID"
ROUND_RC=$?

if [ -d "$EVID" ]; then
    cp -f "$ROUND_LOG" "$EVID/stability-round.log" 2>/dev/null || true
    cp -f "$WORK/stability-driver.log" "$EVID/stability-driver.log" 2>/dev/null || true
    mkdir -p "$EVID/stability"
    cp -f "$DRIVER_DIR"/*.jsonl "$EVID/stability/" 2>/dev/null || true
    cp -f "$DRIVER_DIR"/*.ppm "$EVID/stability/" 2>/dev/null || true
    cp -f "$DRIVER_DIR/qmp-transcript.jsonl" "$EVID/stability/" 2>/dev/null || true
    if compgen -G "$EVID/stability/*.ppm" >/dev/null; then
        sha256sum "$EVID/stability"/*.ppm > "$EVID/stability-ppm-sha256.txt"
    else
        : > "$EVID/stability-ppm-sha256.txt"
    fi
fi

GATE_RC=1
if [ -d "$EVID" ] && [ -f "$EVID/stability/stability-events.jsonl" ]; then
    python3 "$HERE/stability_gate.py" "$EVID" \
        --events "$EVID/stability/stability-events.jsonl" \
        --console-log "$EVID/console.log" \
        --run-id "$TAG" \
        --out "$EVID/stability-gate.json" \
        --profile official-index \
        > "$EVID/stability-gate.log" 2>&1
    GATE_RC=$?
fi

printf 'STABILITY_DRIVER_RC=%s\nSTABILITY_ROUND_RC=%s\nSTABILITY_GATE_RC=%s\n' \
    "$DRIVER_RC" "$ROUND_RC" "$GATE_RC" | tee "$WORK/result.env"
cp -f "$WORK/result.env" "$EVID/stability-result.env" 2>/dev/null || true
cat "$WORK/stability-driver.log" 2>/dev/null || true
(
    cd "$EVID" || exit 1
    find . -type f ! -name stability-bundle-sha256.txt -print0 | sort -z | xargs -0 sha256sum
) > "$EVID/stability-bundle-sha256.txt"
[ "$DRIVER_RC" -eq 0 ] && [ "$ROUND_RC" -eq 0 ] && [ "$GATE_RC" -eq 0 ]
