#!/usr/bin/env bash
# One default-multiprocess stability round: strict page gate, ten real QMP
# reloads at two-minute intervals, then a 30-minute host-monotonic hold.
set -u
set -o pipefail

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
    shift
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
TAG="${1:-stability-mp-2g}"
DUR="${2:-4200}"
IVL="${3:-30}"
RELOAD_COUNT="${4:-${STABILITY_RELOAD_COUNT:-10}}"
RELOAD_INTERVAL="${5:-${STABILITY_RELOAD_INTERVAL:-120}}"
HOLD_SECONDS="${6:-${STABILITY_HOLD_SECONDS:-1805}}"
RELOAD_WINDOW="${STABILITY_RELOAD_WINDOW:-90}"
RELOAD_SETTLE_SECONDS="${STABILITY_RELOAD_SETTLE_SECONDS:-30}"
CAPTURE_GUEST_CLOCK_SYNC="${STABILITY_CAPTURE_GUEST_CLOCK_SYNC:-0}"
MEMORY_SAMPLER_ENABLED="${STABILITY_MEMORY_SAMPLER:-0}"
MEMORY_SAMPLE_SECONDS="${STABILITY_MEMORY_SAMPLE_SECONDS:-900}"
LIFECYCLE_PRELOAD_ENABLED="${STABILITY_LIFECYCLE_PRELOAD:-0}"
PROCESS_SAMPLE_SECONDS="${STABILITY_PROCESS_SAMPLE_SECONDS:-5}"
DIAGNOSTIC_ONLY="${STABILITY_DIAGNOSTIC_ONLY:-0}"
TRACE_MODE="${STABILITY_TRACE_MODE:-0}"
FAMILY_WATCHDOG_INTERVAL="${MP_FAMILY_WATCHDOG_INTERVAL:-4}"
QMP_SOCKET="${QMP_SOCKET:-/tmp/xk6-qmp-stability-${TAG}.sock}"
BASE_IMG="${BASE_IMG:-$HOME/x-kernel/images/pkg-installed.img}"
PKG_TARBALL="${PKG_TARBALL-}"
CHROMIUM_BIN_VALUE="${CHROMIUM_BIN_VALUE:-/usr/lib/chromium/chromium}"
KERNEL_DIR="${KERNEL_DIR:-$HOME/x-kernel}"
export KERNEL_DIR
KERNEL_BIN="$KERNEL_DIR/target/xkmake/kplat-aarch64/release/kernel.bin"
if [ ! -f "$KERNEL_BIN" ]; then
    KERNEL_BIN="$KERNEL_DIR/xkernel_aarch64-qemu.bin"
fi
EXPECTED_KERNEL_SHA256="${STABILITY_EXPECTED_KERNEL_SHA256:-}"
unset PLAT_MEM_OVERRIDE
RUN_DATE="$(date +%Y-%m-%d)"
EVID="$HOME/xk6/evidence/${RUN_DATE}_t490-$TAG"
WORK="$HOME/xk6/tmp/stability-$TAG"
ROUND_LOG="$WORK/round.log"
DRIVER_DIR="$WORK/driver"
STABILITY_AUTORUN=autorun_mp_score_observe6.sh

die() { echo "STABILITY_ROUND_ABORT: $*" >&2; exit 2; }
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<'EOF'
Usage: run_stability_round_mp.sh [--dry-run] [tag] [max-session-seconds] [screendump-interval] [reload-count] [reload-interval-seconds] [hold-seconds]
Default: 4200 seconds max; strict official-index page gate; 10 real Ctrl+R
reloads every 120 seconds; 1805 seconds held after first strict page PASS to clear the 1800-second gate.
The last three values are diagnostic controls; keep their defaults for formal acceptance.
Non-formal values require STABILITY_DIAGNOSTIC_ONLY=1; diagnostic-only runs skip the formal gate.
--dry-run validates and prints the resolved run settings without starting QEMU.
Set KERNEL_DIR to select an isolated kernel worktree; the resolved kernel path
and SHA-256 are printed and archived. STABILITY_EXPECTED_KERNEL_SHA256 makes
the run abort before QEMU if the selected kernel does not match that hash.
The default initial-page timeout is 2400 seconds; when it would outlast a diagnostic session, it is bounded to max-session-seconds minus 200.
Set STABILITY_TRACE_MODE=1 only with STABILITY_DIAGNOSTIC_ONLY=1 to capture bounded Chromium log windows and clone/exec/exit/wait4 traces when strace is available.
Formal memory comes from platform.env (2 GiB); unset PLAT_MEM_OVERRIDE.
The default observer uses lightweight process events at 5-second samples and an independent 4-second guest family watchdog.
Override MP_FAMILY_WATCHDOG_INTERVAL with a positive guest-second interval for controlled sampling experiments.
Set MP_FAMILY_DIAGNOSTICS=1 to log why candidate process PIDs are omitted from a family snapshot.
Set STABILITY_PROCESS_SAMPLE_SECONDS to control the autorun process-tree scan cadence (1-60 seconds, default 5).
Initial-page QMP polling uses 30 seconds to limit bootstrap observation overhead; reload checks use 5 seconds.
EOF
    exit 0
fi
case "$DUR" in
    ''|*[!0-9]*|0) die "max session duration must be a positive integer number of seconds" ;;
esac
GUEST_MAX_SECONDS="${MP_MAX_SECONDS:-$((DUR - 200))}"
case "$GUEST_MAX_SECONDS" in
    ''|*[!0-9]*|0) die "MP_MAX_SECONDS must be a positive integer number of guest seconds" ;;
esac
[ "$GUEST_MAX_SECONDS" -lt "$DUR" ] || die "MP_MAX_SECONDS must be shorter than max session duration"
case "$IVL" in
    ''|*[!0-9]*|0) die "screendump interval must be a positive integer number of seconds" ;;
esac
case "$FAMILY_WATCHDOG_INTERVAL" in
    ''|*[!0-9]*|0) die "MP_FAMILY_WATCHDOG_INTERVAL must be a positive integer number of guest seconds" ;;
esac
case "$PROCESS_SAMPLE_SECONDS" in
    ''|*[!0-9]*|0) die "STABILITY_PROCESS_SAMPLE_SECONDS must be a positive integer number of guest seconds" ;;
esac
[ "$PROCESS_SAMPLE_SECONDS" -le 60 ] || die "STABILITY_PROCESS_SAMPLE_SECONDS must not exceed 60 seconds"
case "$RELOAD_COUNT" in
    ''|*[!0-9]*|0) die "reload count must be a positive integer" ;;
esac
case "$RELOAD_INTERVAL" in
    ''|*[!0-9]*|0) die "reload interval must be a positive integer number of seconds" ;;
esac
case "$HOLD_SECONDS" in
    ''|*[!0-9]*) die "hold duration must be a non-negative integer number of seconds" ;;
esac
case "$DIAGNOSTIC_ONLY" in
    0|1) ;;
    *) die "STABILITY_DIAGNOSTIC_ONLY must be 0 or 1" ;;
esac
case "$TRACE_MODE" in
    0|1) ;;
    *) die "STABILITY_TRACE_MODE must be 0 or 1" ;;
esac
[ "$TRACE_MODE" = "0" ] || [ "$DIAGNOSTIC_ONLY" = "1" ] \
    || die "STABILITY_TRACE_MODE=1 is diagnostic-only"
case "$RELOAD_WINDOW" in
    ''|*[!0-9]*|0) die "STABILITY_RELOAD_WINDOW must be a positive integer number of seconds" ;;
esac
case "$RELOAD_SETTLE_SECONDS" in
    ''|*[!0-9]*) die "STABILITY_RELOAD_SETTLE_SECONDS must be a non-negative integer number of seconds" ;;
esac
case "$CAPTURE_GUEST_CLOCK_SYNC" in
    0|1) ;;
    *) die "STABILITY_CAPTURE_GUEST_CLOCK_SYNC must be 0 or 1" ;;
esac
case "$MEMORY_SAMPLER_ENABLED" in
    0|1) ;;
    *) die "STABILITY_MEMORY_SAMPLER must be 0 or 1" ;;
esac
case "$MEMORY_SAMPLE_SECONDS" in
    ''|*[!0-9]*|0) die "STABILITY_MEMORY_SAMPLE_SECONDS must be a positive integer number of seconds" ;;
esac
case "$LIFECYCLE_PRELOAD_ENABLED" in
    0|1) ;;
    *) die "STABILITY_LIFECYCLE_PRELOAD must be 0 or 1" ;;
esac
[ "$LIFECYCLE_PRELOAD_ENABLED" = "0" ] || [ "$MEMORY_SAMPLER_ENABLED" = "1" ] \
    || die "STABILITY_LIFECYCLE_PRELOAD=1 requires STABILITY_MEMORY_SAMPLER=1 for evidence export"
[ "$RELOAD_SETTLE_SECONDS" -lt "$RELOAD_WINDOW" ] \
    || die "reload settle delay must be shorter than STABILITY_RELOAD_WINDOW"
if [ "${STABILITY_READY_TIMEOUT+x}" = "x" ]; then
    READY_TIMEOUT="$STABILITY_READY_TIMEOUT"
    READY_TIMEOUT_SOURCE=environment
else
    READY_TIMEOUT=2400
    READY_TIMEOUT_SOURCE=default
fi
case "$READY_TIMEOUT" in
    ''|*[!0-9]*|0) die "STABILITY_READY_TIMEOUT must be a positive integer number of seconds" ;;
esac
if [ "$READY_TIMEOUT" -ge "$DUR" ]; then
    [ "$READY_TIMEOUT_SOURCE" = default ] || die "STABILITY_READY_TIMEOUT must be shorter than max session duration"
    [ "$DUR" -gt 200 ] || die "max session duration must exceed 200 seconds to bound the default page timeout"
    READY_TIMEOUT=$((DUR - 200))
    READY_TIMEOUT_SOURCE=default_bounded_to_session
fi
if [ "$DIAGNOSTIC_ONLY" = "0" ]; then
    [ "$RELOAD_COUNT" -eq 10 ] || die "formal stability requires exactly ten reloads"
    [ "$RELOAD_INTERVAL" -eq 120 ] || die "formal stability requires a 120-second reload interval"
    [ "$HOLD_SECONDS" -ge 1800 ] || die "formal stability requires at least 1800 hold seconds"
    [ "$RELOAD_WINDOW" -lt "$RELOAD_INTERVAL" ] || die "formal reload window must be shorter than the reload interval"
    [ "$RELOAD_SETTLE_SECONDS" -ge 30 ] || die "formal stability requires at least 30 seconds after navigation before screenshots"
else
    [ "$HOLD_SECONDS" -ge 0 ] || die "diagnostic hold duration must be non-negative"
fi
KERNEL_SHA256="UNAVAILABLE"
if [ -f "$KERNEL_BIN" ]; then
    KERNEL_SHA256="$(sha256sum "$KERNEL_BIN" | awk '{print $1}')"
fi
if [ -n "$EXPECTED_KERNEL_SHA256" ]; then
    case "$EXPECTED_KERNEL_SHA256" in
        *[!0-9a-fA-F]*) die "STABILITY_EXPECTED_KERNEL_SHA256 must be 64 hexadecimal characters" ;;
    esac
    [ "${#EXPECTED_KERNEL_SHA256}" -eq 64 ] \
        || die "STABILITY_EXPECTED_KERNEL_SHA256 must be 64 hexadecimal characters"
    [ -f "$KERNEL_BIN" ] || die "kernel binary missing: $KERNEL_BIN"
    NORMALIZED_EXPECTED_KERNEL_SHA256="$(printf '%s' "$EXPECTED_KERNEL_SHA256" | tr 'A-F' 'a-f')"
    [ "$KERNEL_SHA256" = "$NORMALIZED_EXPECTED_KERNEL_SHA256" ] \
        || die "kernel SHA-256 mismatch: expected $NORMALIZED_EXPECTED_KERNEL_SHA256 got $KERNEL_SHA256"
fi
if [ "$DRY_RUN" = "1" ]; then
    cat <<EOF
dry_run=1
qemu_started=0
run_id=$TAG
kernel_dir=$KERNEL_DIR
kernel_bin=$KERNEL_BIN
kernel_sha256=$KERNEL_SHA256
expected_kernel_sha256=${EXPECTED_KERNEL_SHA256:-UNSET}
session_max_seconds=$DUR
screendump_interval_seconds=$IVL
diagnostic_only=$DIAGNOSTIC_ONLY
trace_mode=$TRACE_MODE
guest_max_seconds=$GUEST_MAX_SECONDS
ready_timeout_seconds=$READY_TIMEOUT
ready_timeout_source=$READY_TIMEOUT_SOURCE
reload_count=$RELOAD_COUNT
reload_interval_seconds=$RELOAD_INTERVAL
hold_seconds=$HOLD_SECONDS
reload_window_seconds=$RELOAD_WINDOW
reload_settle_seconds=$RELOAD_SETTLE_SECONDS
capture_guest_clock_sync=$CAPTURE_GUEST_CLOCK_SYNC
memory_sampler_enabled=$MEMORY_SAMPLER_ENABLED
memory_sample_seconds=$MEMORY_SAMPLE_SECONDS
lifecycle_preload_enabled=$LIFECYCLE_PRELOAD_ENABLED
chromium_bin=$CHROMIUM_BIN_VALUE
pkg_tarball=${PKG_TARBALL:-UNSET}
process_sample_seconds=$PROCESS_SAMPLE_SECONDS
memory=2g
architecture=aarch64
accelerator=pure TCG
EOF
    exit 0
fi
[ "$(uname -s)" = Linux ] || die "只能在 T490/Linux 主机运行"
[ -f "$BASE_IMG" ] || die "基础镜像不存在: $BASE_IMG"
[ -d "$KERNEL_DIR" ] || die "内核工作树不存在: $KERNEL_DIR"
[ -f "$KERNEL_BIN" ] || die "内核二进制不存在: $KERNEL_BIN"
[ -d "$HERE" ] || die "T490 scripts directory missing"
[ ! -e "$EVID" ] || die "证据目录已存在，拒绝覆盖: $EVID"
[ ! -e "$QMP_SOCKET" ] || die "QMP socket 已存在，拒绝覆盖: $QMP_SOCKET"
ps -eo comm= 2>/dev/null | grep -qx 'qemu-system-aarch64' && die "已有 QEMU 在运行，拒绝并行"
bash "$HERE/verify_chromium_image.sh" "$BASE_IMG" "${EXPECTED_CHROMIUM_MAJOR:-149}" \
    || die "基础镜像 Chromium 版本不匹配"

mkdir -p "$WORK" "$DRIVER_DIR"
rm -f "$ROUND_LOG"

echo "STABILITY_START=$(date -Is) TAG=$TAG DUR=$DUR IVL=$IVL AUTORUN=$STABILITY_AUTORUN FAMILY_WATCHDOG_INTERVAL=$FAMILY_WATCHDOG_INTERVAL PROCESS_SAMPLE_SECONDS=$PROCESS_SAMPLE_SECONDS RELOAD_COUNT=$RELOAD_COUNT RELOAD_INTERVAL=$RELOAD_INTERVAL HOLD_SECONDS=$HOLD_SECONDS READY_TIMEOUT=$READY_TIMEOUT READY_TIMEOUT_SOURCE=$READY_TIMEOUT_SOURCE TRACE_MODE=$TRACE_MODE GUEST_MAX_SECONDS=$GUEST_MAX_SECONDS DIAGNOSTIC_ONLY=$DIAGNOSTIC_ONLY BOOTSTRAP_POLL=30 RELOAD_POLL=5 RELOAD_SETTLE_SECONDS=$RELOAD_SETTLE_SECONDS CAPTURE_GUEST_CLOCK_SYNC=$CAPTURE_GUEST_CLOCK_SYNC MEMORY_SAMPLER=$MEMORY_SAMPLER_ENABLED MEMORY_SAMPLE_SECONDS=$MEMORY_SAMPLE_SECONDS"
echo "EVIDENCE=$EVID"

MEMORY_PROBE_ARGS=()
if [ "$MEMORY_SAMPLER_ENABLED" = "1" ]; then
    MEMORY_PROBE_ARGS+=(proc_tree_sampler.c)
fi
MP_LIFECYCLE_PRELOAD_VALUE=""
if [ "$LIFECYCLE_PRELOAD_ENABLED" = "1" ]; then
    MEMORY_PROBE_ARGS+=(lifecycle_event_preload.c)
    MP_LIFECYCLE_PRELOAD_VALUE=/lifecycle_event_preload.so
fi
PAGE_URL="file:///usr/share/html-test/index.html" \
QMP_SOCKET="$QMP_SOCKET" \
BASE_IMG="$BASE_IMG" \
PKG_TARBALL="$PKG_TARBALL" \
INJECT_AUTOSTART=1 \
OZ_PLATFORM=wayland \
MP_TRACE_VALUE="$TRACE_MODE" \
MP_LEDGER_VALUE=0 \
MP_SAMPLE_SECONDS="$PROCESS_SAMPLE_SECONDS" \
MP_MAX_SECONDS="$GUEST_MAX_SECONDS" \
MP_HOLD_SECONDS=40 \
MP_MEMORY_SAMPLER_VALUE="$MEMORY_SAMPLER_ENABLED" \
MP_MEMORY_SAMPLE_SECONDS_VALUE="$MEMORY_SAMPLE_SECONDS" \
MP_LIFECYCLE_PRELOAD_VALUE="$MP_LIFECYCLE_PRELOAD_VALUE" \
MP_WESTON_CONTINUE=0 \
MP_FAMILY_WATCHDOG_INTERVAL="$FAMILY_WATCHDOG_INTERVAL" \
MP_FAMILY_DIAGNOSTICS="${MP_FAMILY_DIAGNOSTICS:-0}" \
ASSERT_PROFILE=official-index \
STRICT_GATE=0 \
FIRST_SHOT=240 \
bash "$HERE/t490_round.sh" "$TAG" "$DUR" "$IVL" "$STABILITY_AUTORUN" "${MEMORY_PROBE_ARGS[@]}" > "$ROUND_LOG" 2>&1 &
ROUND_PID=$!

i=0
while [ "$i" -lt 360 ] && [ ! -S "$QMP_SOCKET" ]; do
    kill -0 "$ROUND_PID" 2>/dev/null || die "QEMU 会话提前退出，见 $ROUND_LOG"
    sleep 1
    i=$((i + 1))
done
[ -S "$QMP_SOCKET" ] || die "QMP socket 超时: $QMP_SOCKET"
[ -f "$EVID/console.log" ] || die "console.log 尚未创建: $EVID"
{
    EXPECTED_KERNEL_ENV=""
    if [ -n "$EXPECTED_KERNEL_SHA256" ]; then
        EXPECTED_KERNEL_ENV=" STABILITY_EXPECTED_KERNEL_SHA256=$EXPECTED_KERNEL_SHA256"
    fi
    printf 'run_id=%s\n' "$TAG"
    printf 'kernel_dir=%s\n' "$KERNEL_DIR"
    printf 'kernel_bin=%s\n' "$KERNEL_BIN"
    printf 'kernel_sha256=%s\n' "$KERNEL_SHA256"
    printf 'expected_kernel_sha256=%s\n' "${EXPECTED_KERNEL_SHA256:-UNSET}"
    printf 'session_max_seconds=%s\n' "$DUR"
    printf 'screendump_interval_seconds=%s\n' "$IVL"
    printf 'family_watchdog_target_guest_seconds=%s\n' "$FAMILY_WATCHDOG_INTERVAL"
    printf 'family_diagnostics=%s\n' "${MP_FAMILY_DIAGNOSTICS:-0}"
    printf 'process_sample_seconds=%s\n' "$PROCESS_SAMPLE_SECONDS"
    printf 'ready_timeout_seconds=%s\n' "$READY_TIMEOUT"
    printf 'ready_timeout_source=%s\n' "$READY_TIMEOUT_SOURCE"
    printf 'trace_mode=%s\n' "$TRACE_MODE"
    printf 'guest_max_seconds=%s\n' "$GUEST_MAX_SECONDS"
    printf 'reload_count=%s\n' "$RELOAD_COUNT"
    printf 'reload_interval_seconds=%s\n' "$RELOAD_INTERVAL"
    printf 'hold_seconds=%s\n' "$HOLD_SECONDS"
    printf 'diagnostic_only=%s\n' "$DIAGNOSTIC_ONLY"
    printf 'reload_window_seconds=%s\n' "$RELOAD_WINDOW"
    printf 'reload_settle_seconds=%s\n' "$RELOAD_SETTLE_SECONDS"
    printf 'capture_guest_clock_sync=%s\n' "$CAPTURE_GUEST_CLOCK_SYNC"
    printf 'lifecycle_preload_enabled=%s\n' "$LIFECYCLE_PRELOAD_ENABLED"
    printf 'chromium_bin=%s\npkg_tarball=%s\n' "$CHROMIUM_BIN_VALUE" "${PKG_TARBALL:-UNSET}"
    printf 'initial_page_poll_seconds=30\nreload_poll_seconds=5\n'
    printf 'memory=2g\narchitecture=aarch64\naccelerator=tcg\n'
    printf 'command=KERNEL_DIR=%s%s STABILITY_DIAGNOSTIC_ONLY=%s STABILITY_RELOAD_WINDOW=%s STABILITY_RELOAD_SETTLE_SECONDS=%s STABILITY_CAPTURE_GUEST_CLOCK_SYNC=%s STABILITY_MEMORY_SAMPLER=%s STABILITY_MEMORY_SAMPLE_SECONDS=%s STABILITY_LIFECYCLE_PRELOAD=%s STABILITY_PROCESS_SAMPLE_SECONDS=%s MP_FAMILY_DIAGNOSTICS=%s MP_FAMILY_WATCHDOG_INTERVAL=%s bash scripts/t490/run_stability_round_mp.sh %s %s %s %s %s %s\n' \
        "$KERNEL_DIR" "$EXPECTED_KERNEL_ENV" "$DIAGNOSTIC_ONLY" "$RELOAD_WINDOW" "$RELOAD_SETTLE_SECONDS" "$CAPTURE_GUEST_CLOCK_SYNC" "$MEMORY_SAMPLER_ENABLED" "$MEMORY_SAMPLE_SECONDS" "$LIFECYCLE_PRELOAD_ENABLED" "$PROCESS_SAMPLE_SECONDS" "${MP_FAMILY_DIAGNOSTICS:-0}" "$FAMILY_WATCHDOG_INTERVAL" \
        "$TAG" "$DUR" "$IVL" "$RELOAD_COUNT" "$RELOAD_INTERVAL" "$HOLD_SECONDS"
} > "$EVID/stability-run-config.txt"

DRIVER_DIAGNOSTIC_ARGS=()
if [ "$DIAGNOSTIC_ONLY" = "1" ]; then
    DRIVER_DIAGNOSTIC_ARGS+=(--diagnostic-only)
fi
DRIVER_CLOCK_ARGS=()
if [ "$CAPTURE_GUEST_CLOCK_SYNC" = "1" ]; then
    DRIVER_CLOCK_ARGS+=(--capture-guest-clock-sync)
fi
python3 "$HERE/stability_driver.py" \
    --socket "$QMP_SOCKET" \
    --run-id "$TAG" \
    --out-dir "$DRIVER_DIR" \
    --events "$DRIVER_DIR/stability-events.jsonl" \
    --console-log "$EVID/console.log" \
    --duration-seconds "$HOLD_SECONDS" \
    --reload-count "$RELOAD_COUNT" \
    --reload-interval-seconds "$RELOAD_INTERVAL" \
    --reload-window-seconds "$RELOAD_WINDOW" \
    --reload-settle-seconds "$RELOAD_SETTLE_SECONDS" \
    --ready-timeout-seconds "$READY_TIMEOUT" \
    --bootstrap-poll-seconds 30 \
    --poll-seconds 5 \
    --heartbeat-seconds 30 \
    --schedule-tolerance-seconds "${STABILITY_SCHEDULE_TOLERANCE:-10}" \
    --profile official-index \
    "${DRIVER_DIAGNOSTIC_ARGS[@]}" \
    "${DRIVER_CLOCK_ARGS[@]}" \
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
NORMALIZER_RC=1
if [ -d "$EVID" ] && [ -f "$EVID/stability/stability-events.jsonl" ]; then
    python3 "$HERE/normalize_stability_events.py" \
        "$EVID/stability/stability-events.jsonl" \
        "$EVID/stability/stability-events.normalized.jsonl" \
        --summary "$EVID/stability/stability-event-normalization.json" \
        > "$EVID/stability-event-normalization.log" 2>&1
    NORMALIZER_RC=$?
fi
if [ "$DIAGNOSTIC_ONLY" = "1" ] && [ -d "$EVID" ]; then
    GATE_RC=78
    printf 'STABILITY_GATE_SKIPPED: diagnostic-only reproduction; not an acceptance run\n' \
        > "$EVID/stability-gate.log"
elif [ "$NORMALIZER_RC" -eq 0 ] && [ -d "$EVID" ]; then
    python3 "$HERE/stability_gate.py" "$EVID" \
        --events "$EVID/stability/stability-events.normalized.jsonl" \
        --console-log "$EVID/console.log" \
        --run-id "$TAG" \
        --out "$EVID/stability-gate.json" \
        --profile official-index \
        --checker "$HERE/ppm_assert.py" \
        > "$EVID/stability-gate.log" 2>&1
    GATE_RC=$?
elif [ -d "$EVID" ]; then
    printf 'STABILITY_GATE_SKIPPED: normalization rc=%s; see stability-event-normalization.log\n' \
        "$NORMALIZER_RC" > "$EVID/stability-gate.log"
fi

printf 'STABILITY_DRIVER_RC=%s\nSTABILITY_ROUND_RC=%s\nSTABILITY_NORMALIZER_RC=%s\nSTABILITY_GATE_RC=%s\nSTABILITY_DIAGNOSTIC_ONLY=%s\n' \
    "$DRIVER_RC" "$ROUND_RC" "$NORMALIZER_RC" "$GATE_RC" "$DIAGNOSTIC_ONLY" | tee "$WORK/result.env"
cp -f "$WORK/result.env" "$EVID/stability-result.env" 2>/dev/null || true
cat "$WORK/stability-driver.log" 2>/dev/null || true
(
    cd "$EVID" || exit 1
    find . -type f ! -name stability-bundle-sha256.txt -print0 | sort -z | xargs -0 sha256sum
) > "$EVID/stability-bundle-sha256.txt"
[ "$DRIVER_RC" -eq 0 ] && [ "$ROUND_RC" -eq 0 ] \
    && [ "$NORMALIZER_RC" -eq 0 ] && [ "$GATE_RC" -eq 0 ]
