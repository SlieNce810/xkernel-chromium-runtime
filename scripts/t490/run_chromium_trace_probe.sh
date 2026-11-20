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
TRACE_PROBE_HOLD_SECONDS="${TRACE_PROBE_HOLD_SECONDS:-800}"
TRACE_PROBE_GUEST_MAX_SECONDS="${TRACE_PROBE_GUEST_MAX_SECONDS:-1700}"
TRACE_PROBE_MEMORY_SAMPLE_SECONDS="${TRACE_PROBE_MEMORY_SAMPLE_SECONDS:-900}"

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
        || ! grep -q '^PERF_MEMORY_SAMPLER_ENABLED="__MP_MEMORY_SAMPLER__"$' "$HERE/autorun_mp_score_observe6.sh" \
        || ! grep -q '^PERF_MEMORY_SAMPLE_SECONDS="__MP_MEMORY_SAMPLE_SECONDS__"$' "$HERE/autorun_mp_score_observe6.sh" \
        || ! grep -Fq 's|__MP_MEMORY_SAMPLER__|$MP_MEMORY_SAMPLER_VALUE|g' "$HERE/t490_round.sh" \
        || ! grep -Fq 's|__MP_MEMORY_SAMPLE_SECONDS__|$MP_MEMORY_SAMPLE_SECONDS_VALUE|g' "$HERE/t490_round.sh" \
        || ! grep -Fq 'fold -w 256' "$HERE/autorun_mp_score_observe6.sh" \
        || ! grep -Fq 'gzip -t "$trace_gzip_file"' "$HERE/autorun_mp_score_observe6.sh" \
        || ! grep -Fq 'base64 -d "$trace_flat_file"' "$HERE/autorun_mp_score_observe6.sh" \
        || ! grep -Fq 'gzip_sha256=$trace_gzip_sha' "$HERE/autorun_mp_score_observe6.sh" \
        || ! grep -Fq 'len=%s' "$HERE/autorun_mp_score_observe6.sh" \
        || ! grep -q 'CHROME_ARGS=.*\$EXTRA_FLAGS' "$HERE/autorun_mp_score_observe6.sh"; then
    echo "PERF_TRACE_PROBE_ABORT: trace-only template guard or EXTRA_FLAGS injection is missing" >&2
    exit 3
fi
trace_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/trace-chunk-selftest.XXXXXX") || {
    echo "PERF_TRACE_PROBE_ABORT: cannot create chunk framing self-test directory" >&2
    exit 4
}
awk 'BEGIN { for (i = 0; i < 600; i++) printf "A" }' > "$trace_test_dir/flat"
fold -w 256 < "$trace_test_dir/flat" > "$trace_test_dir/chunks"
trace_test_expected=$(awk 'END { print NR + 0 }' "$trace_test_dir/chunks")
trace_test_observed=0
while IFS= read -r trace_test_chunk || [ -n "$trace_test_chunk" ]; do
    [ -n "$trace_test_chunk" ] || continue
    trace_test_observed=$((trace_test_observed + 1))
done < "$trace_test_dir/chunks"
rm -f "$trace_test_dir/flat" "$trace_test_dir/chunks"
rmdir "$trace_test_dir"
if [ "$trace_test_expected" != "3" ] || [ "$trace_test_observed" != "$trace_test_expected" ]; then
    echo "PERF_TRACE_PROBE_ABORT: final folded chunk was not counted/emitted (expected=$trace_test_expected observed=$trace_test_observed)" >&2
    exit 5
fi
trace_roundtrip_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/trace-roundtrip-selftest.XXXXXX") || {
    echo "PERF_TRACE_PROBE_ABORT: cannot create exporter round-trip self-test directory" >&2
    exit 4
}
printf '%s\n' 'trace exporter round-trip self-test' > "$trace_roundtrip_test_dir/payload"
gzip -c "$trace_roundtrip_test_dir/payload" > "$trace_roundtrip_test_dir/payload.gz"
base64 < "$trace_roundtrip_test_dir/payload.gz" > "$trace_roundtrip_test_dir/payload.b64"
tr -d '\r\n' < "$trace_roundtrip_test_dir/payload.b64" > "$trace_roundtrip_test_dir/payload.flat"
trace_test_gzip_bytes=$(wc -c < "$trace_roundtrip_test_dir/payload.gz" | tr -d '[:space:]')
trace_test_chars=$(wc -c < "$trace_roundtrip_test_dir/payload.flat" | tr -d '[:space:]')
trace_test_expected_chars=$(( ((trace_test_gzip_bytes + 2) / 3) * 4 ))
if [ "$trace_test_chars" -ne "$trace_test_expected_chars" ] \
        || ! base64 -d "$trace_roundtrip_test_dir/payload.flat" > "$trace_roundtrip_test_dir/decoded.gz" \
        || ! cmp -s "$trace_roundtrip_test_dir/payload.gz" "$trace_roundtrip_test_dir/decoded.gz" \
        || ! gzip -t "$trace_roundtrip_test_dir/decoded.gz" \
        || ! gzip -dc "$trace_roundtrip_test_dir/decoded.gz" | cmp -s "$trace_roundtrip_test_dir/payload" -; then
    echo "PERF_TRACE_PROBE_ABORT: gzip/base64 round-trip self-test failed" >&2
    rm -rf "$trace_roundtrip_test_dir"
    exit 6
fi
rm -rf "$trace_roundtrip_test_dir"
INJECTED_TEMPLATE="$(mktemp)"
trap 'rm -f "$INJECTED_TEMPLATE"' EXIT
sed -e "s|__EXTRA_FLAGS__|$TRACE_FLAGS|g" \
    -e 's|__MP_MEMORY_SAMPLER__|1|g' \
    -e "s|__MP_MEMORY_SAMPLE_SECONDS__|$TRACE_PROBE_MEMORY_SAMPLE_SECONDS|g" \
    "$HERE/autorun_mp_score_observe6.sh" > "$INJECTED_TEMPLATE"
if ! grep -F "EXTRA_FLAGS=\"$TRACE_FLAGS\"" "$INJECTED_TEMPLATE" >/dev/null \
        || ! grep -F 'CHROME_ARGS=' "$INJECTED_TEMPLATE" | grep -F '$EXTRA_FLAGS' >/dev/null \
        || ! grep -F 'PERF_MEMORY_SAMPLER_ENABLED="1"' "$INJECTED_TEMPLATE" >/dev/null \
        || ! grep -F "PERF_MEMORY_SAMPLE_SECONDS=\"$TRACE_PROBE_MEMORY_SAMPLE_SECONDS\"" "$INJECTED_TEMPLATE" >/dev/null; then
    echo "PERF_TRACE_PROBE_ABORT: Chrome trace flags did not survive template substitution" >&2
    exit 4
fi
echo "PERF_TRACE_TEMPLATE_INJECTION=PASS"
echo "PERF_TRACE_TRACE_ONLY_GUARD=PASS"
echo "PERF_TRACE_COMPRESSED_SELFTEST=PASS"
echo "PERF_TRACE_EXPORT_ROUNDTRIP=PASS"
echo "PERF_TRACE_CHUNK_LENGTH=PASS"
echo "PERF_TRACE_CHUNK_EOF_HANDLING=PASS"
echo "PERF_TRACE_MEMORY_SAMPLER_INJECTION=PASS"
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

echo "PERF_TRACE_PROBE tag=$TAG duration=1800 guest_browser_max=$TRACE_PROBE_GUEST_MAX_SECONDS ready_timeout=700 reloads=1 interval=30 hold=$TRACE_PROBE_HOLD_SECONDS screenshot_interval=1200 first_screenshot=240 trace_duration=500 trace_format=json trace_categories=startup,ipc,loading,blink,cc,viz,navigation serial_chunk_chars=256 trace_file=/root/mp-perf-trace.json memory_sampler=1 memory_seconds=$TRACE_PROBE_MEMORY_SAMPLE_SECONDS guest_clock_sync=1"
EXTRA_FLAGS_VALUE="$TRACE_FLAGS" \
ALLOW_CHROMIUM_PERF_TRACE_ONLY=1 \
STABILITY_DIAGNOSTIC_ONLY=1 \
STABILITY_TRACE_MODE=0 \
STABILITY_MEMORY_SAMPLER=1 \
STABILITY_MEMORY_SAMPLE_SECONDS="$TRACE_PROBE_MEMORY_SAMPLE_SECONDS" \
STABILITY_CAPTURE_GUEST_CLOCK_SYNC=1 \
STABILITY_RELOAD_COUNT=1 \
STABILITY_RELOAD_INTERVAL=30 \
STABILITY_HOLD_SECONDS="$TRACE_PROBE_HOLD_SECONDS" \
STABILITY_READY_TIMEOUT=700 \
MP_MAX_SECONDS="$TRACE_PROBE_GUEST_MAX_SECONDS" \
KERNEL_DIR=/home/mo/xk6/worktrees/xk-compat-fix-r1 \
BASE_IMG=/home/mo/x-kernel/images/pkg-installed.img \
XKMAKE_ARGS=--no-build \
env -u PLAT_MEM_OVERRIDE MP_FAMILY_WATCHDOG_INTERVAL=14 MP_FAMILY_DIAGNOSTICS=1 \
bash "$HERE/run_stability_round_mp.sh" "${RUN_ARGS[@]}" "$TAG" 1800 1200 1 30 "$TRACE_PROBE_HOLD_SECONDS"
