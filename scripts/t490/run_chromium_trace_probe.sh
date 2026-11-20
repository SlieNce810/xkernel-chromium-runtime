#!/usr/bin/env bash
# Capture a bounded Chromium startup Perfetto trace in a diagnostic-only run.
set -u
set -o pipefail

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=1
    shift
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
TAG="${1:-chromium-trace-probe}"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<'EOF'
Usage: run_chromium_trace_probe.sh [--dry-run] [tag]

Runs one diagnostic-only 2 GiB Wayland session with Chrome startup tracing.
The guest writes /root/mp-perf-trace.json and exports verified chunks over the
serial console; the host screenshot cadence is kept outside the export window.
On T490, --dry-run also exercises the trace-only guard without touching the disk
image or starting QEMU. This probe validates trace capture only, not acceptance.
EOF
    exit 0
fi

TRACE_FLAGS="--trace-startup=startup,ipc,loading,blink,cc,viz,navigation --trace-startup-file=/root/mp-perf-trace.json --trace-startup-duration=500 --trace-startup-format=json"
if ! grep -q '^EXTRA_FLAGS="__EXTRA_FLAGS__"$' "$HERE/autorun_mp_score_observe6.sh" \
        || ! grep -q 'ALLOW_CHROMIUM_PERF_TRACE_ONLY' "$HERE/t490_round.sh" \
        || ! grep -Fq 'fold -w 256' "$HERE/autorun_mp_score_observe6.sh" \
        || ! grep -Fq 'gzip -t "$trace_gzip_file"' "$HERE/autorun_mp_score_observe6.sh" \
        || ! grep -Fq 'gzip_sha256=$trace_gzip_sha' "$HERE/autorun_mp_score_observe6.sh" \
        || ! grep -Fq 'len=%s' "$HERE/autorun_mp_score_observe6.sh" \
        || ! grep -q 'CHROME_ARGS=.*\$EXTRA_FLAGS' "$HERE/autorun_mp_score_observe6.sh"; then
    echo "PERF_TRACE_PROBE_ABORT: trace-only template guard or EXTRA_FLAGS injection is missing" >&2
    exit 3
fi
INJECTED_TEMPLATE="$(mktemp)"
trap 'rm -f "$INJECTED_TEMPLATE"' EXIT
sed "s|__EXTRA_FLAGS__|$TRACE_FLAGS|g" "$HERE/autorun_mp_score_observe6.sh" > "$INJECTED_TEMPLATE"
if ! grep -F "EXTRA_FLAGS=\"$TRACE_FLAGS\"" "$INJECTED_TEMPLATE" >/dev/null \
        || ! grep -F 'CHROME_ARGS=' "$INJECTED_TEMPLATE" | grep -F '$EXTRA_FLAGS' >/dev/null; then
    echo "PERF_TRACE_PROBE_ABORT: Chrome trace flags did not survive template substitution" >&2
    exit 4
fi
echo "PERF_TRACE_TEMPLATE_INJECTION=PASS"
echo "PERF_TRACE_TRACE_ONLY_GUARD=PASS"
echo "PERF_TRACE_COMPRESSED_SELFTEST=PASS"
echo "PERF_TRACE_CHUNK_LENGTH=PASS"
RUN_ARGS=()
if [ "$DRY_RUN" = "1" ]; then
    if [ "$(uname -s)" = "Linux" ]; then
        MP_TRACE_VALUE=0 \
        EXTRA_FLAGS_VALUE="$TRACE_FLAGS" \
        ALLOW_CHROMIUM_PERF_TRACE_ONLY=1 \
        T490_ROUND_TRACE_GUARD_ONLY=1 \
        KERNEL_DIR=/home/mo/xk6/worktrees/xk-compat-fix-r1 \
            bash "$HERE/t490_round.sh" "$TAG-guard-preflight" 1800 1200 autorun_mp_score_observe6.sh
    fi
    RUN_ARGS+=(--dry-run)
fi

echo "PERF_TRACE_PROBE tag=$TAG duration=1800 guest_browser_max=1400 ready_timeout=700 reloads=1 interval=30 hold=650 screenshot_interval=1200 first_screenshot=240 trace_duration=500 trace_format=json trace_categories=startup,ipc,loading,blink,cc,viz,navigation serial_chunk_chars=256 trace_file=/root/mp-perf-trace.json"
EXTRA_FLAGS_VALUE="$TRACE_FLAGS" \
ALLOW_CHROMIUM_PERF_TRACE_ONLY=1 \
STABILITY_DIAGNOSTIC_ONLY=1 \
STABILITY_TRACE_MODE=0 \
STABILITY_RELOAD_COUNT=1 \
STABILITY_RELOAD_INTERVAL=30 \
STABILITY_HOLD_SECONDS=650 \
STABILITY_READY_TIMEOUT=700 \
MP_MAX_SECONDS=1400 \
KERNEL_DIR=/home/mo/xk6/worktrees/xk-compat-fix-r1 \
BASE_IMG=/home/mo/x-kernel/images/pkg-installed.img \
XKMAKE_ARGS=--no-build \
env -u PLAT_MEM_OVERRIDE MP_FAMILY_WATCHDOG_INTERVAL=14 MP_FAMILY_DIAGNOSTICS=1 \
bash "$HERE/run_stability_round_mp.sh" "${RUN_ARGS[@]}" "$TAG" 1800 1200 1 30 650
