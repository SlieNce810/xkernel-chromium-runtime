#!/bin/sh
# Short guest-side smoke for proc_tree_sampler.c; this does not launch Chromium.
set -u

RUN_ID=proc-tree-smoke-01
OUT_DIR=/tmp/proc-tree-smoke
mkdir -p "$OUT_DIR"
launch_ms=$(awk 'NR == 1 { printf "%.0f", $1 * 1000 }' /proc/uptime 2>/dev/null || echo 0)
case "$launch_ms" in
    ''|*[!0-9]*) echo "PROC_TREE_SMOKE_FAIL invalid guest monotonic time" > /dev/console; exit 2 ;;
esac
launch_ns=$((launch_ms * 1000000))
root_pid=$$
root_stat=$(cat "/proc/$root_pid/stat" 2>/dev/null || echo unavailable)
echo "PROC_TREE_SMOKE_BEGIN root_pid=$root_pid root_stat=$root_stat launch_ns=$launch_ns" > /dev/console

if [ ! -x /proc_tree_sampler ]; then
    echo "PROC_TREE_SMOKE_FAIL sampler binary missing" > /dev/console
    exit 2
fi

if ! /proc_tree_sampler \
    --run-id "$RUN_ID" \
    --root-pid "$root_pid" \
    --launch-ns "$launch_ns" \
    --duration-seconds 8 \
    --interval-ms 1000 \
    --out-dir "$OUT_DIR" > "$OUT_DIR/sampler.log" 2>&1; then
    cat "$OUT_DIR/sampler.log" > /dev/console 2>&1
    cat "$OUT_DIR/memory-sampling-errors.log" > /dev/console 2>&1
    head -n 4 "$OUT_DIR/memory-samples.csv" > /dev/console 2>&1
    echo "PROC_TREE_SMOKE_FAIL sampler returned non-zero" > /dev/console
    exit 1
fi

sample_lines=$(wc -l < "$OUT_DIR/memory-samples.csv" 2>/dev/null || echo 0)
sample_rows=$((sample_lines - 1))
started=$(grep -c '"event":"process_started"' "$OUT_DIR/lifecycle-events.jsonl" 2>/dev/null || true)
missing=$(grep -c 'smaps_rollup=unavailable' "$OUT_DIR/memory-sampling-errors.log" 2>/dev/null || true)
bad_values=$(awk -F, 'NR > 1 { if ($8 <= 0 || $9 <= 0 || $10 <= 0) bad++ } END { print bad + 0 }' "$OUT_DIR/memory-samples.csv")
[ -n "$started" ] || started=0
[ -n "$missing" ] || missing=0
cat "$OUT_DIR/sampler.log" > /dev/console 2>&1
echo "PROC_TREE_SMOKE run_id=$RUN_ID sample_rows=$sample_rows processes_started=$started memory_errors=$missing bad_values=$bad_values" > /dev/console
head -n 4 "$OUT_DIR/memory-samples.csv" > /dev/console 2>&1
echo "PROC_TREE_SMOKE_ROOT_SMAPS_BEGIN pid=$root_pid" > /dev/console
cat "/proc/$root_pid/smaps_rollup" > /dev/console 2>&1
tail -n 4 "$OUT_DIR/lifecycle-events.jsonl" > /dev/console 2>&1

[ "$sample_rows" -ge 16 ] && [ "$started" -ge 1 ] && [ "$missing" -eq 0 ] && [ "$bad_values" -eq 0 ] \
    || { echo "PROC_TREE_SMOKE_FAIL output validation" > /dev/console; exit 1; }
echo "PROC_TREE_SMOKE_PASS" > /dev/console
exit 0
