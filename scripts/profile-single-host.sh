#!/usr/bin/env bash
# One single-process profiling round. Failed perf/eBPF attempts are preserved;
# the /proc observer fallback still produces a usable host-side measurement.

set -u
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_ROOT="${PROFILE_OUT_ROOT:-$ROOT/evidence/$(date +%Y-%m-%d)_profile-single}"
TAG="${PROFILE_TAG:-single-profile-01}"
DURATION="${PROFILE_DURATION:-300}"
INTERVAL="${PROFILE_INTERVAL:-60}"
BASE_IMG="${BASE_IMG:-$HOME/x-kernel/images/agentos-weston.img}"
PKG_TARBALL="${PKG_TARBALL:-$HOME/xk6/tmp/eudev-seatprobe-libinput-swiftshader-p31.tar.gz}"
export PATH="$HOME/qemu-root/usr/bin:$HOME/.cargo/bin:$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"

mkdir -p "$OUT_ROOT"
[ ! -e "$OUT_ROOT/profile-command.txt" ] || { echo "refuse overwrite: $OUT_ROOT" >&2; exit 2; }
{
    echo "PROFILE_START=$(date -Is)"
    echo "TAG=$TAG DURATION=$DURATION INTERVAL=$INTERVAL"
    uname -a
    lscpu | grep -E 'Model name|CPU\(s\)|Architecture' || true
    sha256sum "$BASE_IMG" "$PKG_TARBALL"
} > "$OUT_ROOT/host.txt"

echo "ASSERT_PROFILE=official-index FIRST_SHOT=180 SINGLE_HOLD_VALUE=120 SINGLE_SAMPLE_VALUE=15" > "$OUT_ROOT/profile-command.txt"
echo "BASE_IMG=$BASE_IMG PKG_TARBALL=$PKG_TARBALL bash scripts/t490/t490_round.sh $TAG $DURATION $INTERVAL autorun_single_initial.sh" >> "$OUT_ROOT/profile-command.txt"

(
    ASSERT_PROFILE=official-index FIRST_SHOT=180 SINGLE_HOLD_VALUE=120 SINGLE_SAMPLE_VALUE=15 \
        MP_TRACE_VALUE=0 STRICT_GATE=1 BASE_IMG="$BASE_IMG" PKG_TARBALL="$PKG_TARBALL" \
        bash "$ROOT/scripts/t490/t490_round.sh" "$TAG" "$DURATION" "$INTERVAL" autorun_single_initial.sh
) > "$OUT_ROOT/round.log" 2>&1 &
ROUND_PID=$!

QEMU_PID=""
for _ in $(seq 1 90); do
    QEMU_PID=$(pgrep -n -f '^qemu-system-aarch64 ' || true)
    [ -n "$QEMU_PID" ] && break
    sleep 1
done
if [ -z "$QEMU_PID" ]; then
    echo "QEMU_NOT_FOUND=1" > "$OUT_ROOT/profile-status.txt"
    wait "$ROUND_PID" || true
    exit 3
fi
echo "QEMU_PID=$QEMU_PID" >> "$OUT_ROOT/profile-status.txt"

python3 "$ROOT/scripts/observe_qemu.py" --pid "$QEMU_PID" --interval 1 \
    --csv "$OUT_ROOT/qemu-proc.csv" --summary "$OUT_ROOT/qemu-proc.json" \
    > "$OUT_ROOT/qemu-proc.log" 2>&1 &
OBSERVER_PID=$!

perf stat -p "$QEMU_PID" -e cycles,instructions,context-switches,page-faults,cpu-migrations \
    -o "$OUT_ROOT/perf-stat.txt" -- sleep 120 > "$OUT_ROOT/perf-stat.stderr" 2>&1 || true

perf record -F 99 -g -p "$QEMU_PID" -o "$OUT_ROOT/perf.data" -- sleep 120 \
    > "$OUT_ROOT/perf-record.stdout" 2> "$OUT_ROOT/perf-record.stderr" || true

if command -v bpftrace >/dev/null 2>&1; then
    timeout 10 bpftrace -e 'tracepoint:sched:sched_switch { @[comm] = count(); }' \
        > "$OUT_ROOT/bpftrace.log" 2>&1 || true
else
    echo 'bpftrace unavailable' > "$OUT_ROOT/bpftrace.log"
fi

wait "$OBSERVER_PID" || true
wait "$ROUND_PID"; ROUND_RC=$?
echo "ROUND_RC=$ROUND_RC" >> "$OUT_ROOT/profile-status.txt"

if [ -s "$OUT_ROOT/perf.data" ]; then
    perf script -i "$OUT_ROOT/perf.data" > "$OUT_ROOT/perf-script.txt" 2> "$OUT_ROOT/perf-script.stderr" || true
    perf report --stdio -i "$OUT_ROOT/perf.data" > "$OUT_ROOT/perf-report.txt" 2>&1 || true
else
    echo 'perf.data not produced; perf_event permissions/counters unavailable' > "$OUT_ROOT/flamegraph-status.txt"
fi

sha256sum "$OUT_ROOT"/* > "$OUT_ROOT/sha256sums.txt" 2>/dev/null || true
exit "$ROUND_RC"
