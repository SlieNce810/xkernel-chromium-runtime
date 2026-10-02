#!/usr/bin/env bash
# Five-run single-process initial-round measurement.
# Run on the Linux T490 host; every run uses a fresh QEMU and immutable evidence dir.

set -u
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
RUNS="${MEASURE_RUNS:-5}"
DURATION="${MEASURE_DURATION:-300}"
INTERVAL="${MEASURE_INTERVAL:-60}"
TAG_PREFIX="${MEASURE_TAG_PREFIX:-single-perf}"
OUT_ROOT="${MEASURE_OUT_ROOT:-$ROOT/evidence/$(date +%Y-%m-%d)_measure-$TAG_PREFIX}"
RAW_CSV="$OUT_ROOT/raw.csv"
SUMMARY_JSON="$OUT_ROOT/summary.json"
BASE_IMG="${BASE_IMG:-$HOME/x-kernel/images/agentos-weston.img}"
PKG_TARBALL="${PKG_TARBALL:-$HOME/xk6/tmp/eudev-seatprobe-libinput-swiftshader-p31.tar.gz}"

export PATH="$HOME/qemu-root/usr/bin:$HOME/.cargo/bin:$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"

die() { echo "ERROR: $*" >&2; exit 2; }
case "$(uname -s 2>/dev/null || true)" in Linux) ;; *) die "只在 Linux/T490 主机运行" ;; esac
case "$RUNS" in ''|*[!0-9]*) die "MEASURE_RUNS 必须为正整数" ;; esac
[ "$RUNS" -ge 5 ] || die "初赛测量至少 5 次"
[ -x "$HERE/t490_round.sh" ] || die "缺少 t490_round.sh"
[ -f "$ROOT/scripts/collect_single_metrics.py" ] || die "缺少 collect_single_metrics.py"
[ ! -e "$RAW_CSV" ] || die "拒绝覆盖已有 raw.csv: $RAW_CSV"
mkdir -p "$OUT_ROOT"

{
    echo "MEASURE_START=$(date -Is)"
    echo "HOST=$(hostname)"
    uname -a
    lscpu | grep -E 'Model name|CPU\(s\)|Architecture' || true
    if command -v qemu-system-aarch64 >/dev/null 2>&1; then qemu-system-aarch64 --version | head -1; else echo 'qemu-system-aarch64: unavailable in PATH'; fi
    sha256sum "$BASE_IMG" "$PKG_TARBALL"
} > "$OUT_ROOT/host.txt"

for n in $(seq 1 "$RUNS"); do
    run_id=$(printf '%02d' "$n")
    tag="${TAG_PREFIX}-${run_id}-$(date +%H%M%S)"
    round_log="$OUT_ROOT/round-${run_id}.log"
    set +e
    ASSERT_PROFILE=official-index FIRST_SHOT=180 SINGLE_HOLD_VALUE=120 SINGLE_SAMPLE_VALUE=15 \
        MP_TRACE_VALUE=0 STRICT_GATE=1 BASE_IMG="$BASE_IMG" PKG_TARBALL="$PKG_TARBALL" \
        bash "$HERE/t490_round.sh" "$tag" "$DURATION" "$INTERVAL" autorun_single_initial.sh \
        2>&1 | tee "$round_log"
    round_rc=${PIPESTATUS[0]}
    set -e
    evidence=$(sed -n 's/^EVIDENCE=//p' "$round_log" | tail -1)
    if [ -z "$evidence" ] || [ ! -d "$evidence" ]; then
        evidence=$(find "$HOME/xk6/evidence" -maxdepth 1 -type d -name "*_t490-$tag" -print -quit)
    fi
    [ -n "$evidence" ] && [ -d "$evidence" ] || die "无法定位 evidence: $round_log"
    printf '%s\n' "$evidence" > "$OUT_ROOT/evidence-${run_id}.txt"
    set +e
    python3 "$ROOT/scripts/collect_single_metrics.py" "$evidence" --run "$run_id" \
        --csv "$RAW_CSV" --profile official-index 2>&1 | tee "$OUT_ROOT/collect-${run_id}.log"
    collect_rc=${PIPESTATUS[0]}
    set -e
    if [ "$round_rc" -ne 0 ] || [ "$collect_rc" -ne 0 ]; then
        echo "MEASURE_ABORT run=$run_id round_rc=$round_rc collect_rc=$collect_rc" >&2
        exit 4
    fi
done

python3 "$ROOT/scripts/measure.py" "$RAW_CSV" "$SUMMARY_JSON" --minimum "$RUNS"
sha256sum "$RAW_CSV" "$SUMMARY_JSON" "$OUT_ROOT/host.txt" > "$OUT_ROOT/sha256sums.txt"
echo "MEASURE_PASS raw=$RAW_CSV summary=$SUMMARY_JSON"
