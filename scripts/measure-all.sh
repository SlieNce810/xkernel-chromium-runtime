#!/usr/bin/env bash
# Run immutable cold-start samples and aggregate the four required metrics.
# This script must run on the Linux T490 host, never on Windows.

set -u
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
T490="$ROOT/scripts/t490"

RUNS="${MEASURE_RUNS:-5}"
DURATION="${MEASURE_DURATION:-660}"
INTERVAL="${MEASURE_INTERVAL:-60}"
PAGE="${MEASURE_PAGE:-index}"
TAG_PREFIX="${MEASURE_TAG_PREFIX:-mp-measure}"
OUT_ROOT="${MEASURE_OUT_ROOT:-$ROOT/evidence/$(date +%Y-%m-%d)_measure-$TAG_PREFIX}"
RAW_CSV="$OUT_ROOT/raw.csv"
SUMMARY_JSON="$OUT_ROOT/summary.json"
BASELINE_SUMMARY="${MEASURE_BASELINE_SUMMARY:-}"

die() { echo "ERROR: $*" >&2; exit 2; }

case "$(uname -s 2>/dev/null || true)" in
    Linux) ;;
    *) die "measure-all.sh 只能在 Linux/T490 主机运行" ;;
esac

case "$RUNS" in ''|*[!0-9]*) die "MEASURE_RUNS 必须是正整数" ;; esac
[ "$RUNS" -ge 5 ] || die "MEASURE_RUNS=$RUNS 小于赛题要求的 5 次"
case "$PAGE" in index|layout|interaction) ;; *) die "MEASURE_PAGE 只能是 index/layout/interaction" ;; esac
[ -x "$T490/t490_round.sh" ] || die "缺少 $T490/t490_round.sh"
[ -f "$T490/autorun_mp_diag.sh" ] || die "缺少多进程诊断入口 autorun_mp_diag.sh"
[ -f "$ROOT/scripts/collect_metrics.py" ] || die "缺少 collect_metrics.py"
[ -f "$ROOT/scripts/measure.py" ] || die "缺少 measure.py"

mkdir -p "$OUT_ROOT"
[ ! -e "$RAW_CSV" ] || die "拒绝覆盖已有 raw.csv: $RAW_CSV"

PAGE_URL="file:///usr/share/html-test/${PAGE}.html"
AUTORUN="autorun_mp_diag.sh"
echo "MEASURE_START=$(date -Is)"
echo "MEASURE_RUNS=$RUNS DURATION=$DURATION INTERVAL=$INTERVAL PAGE=$PAGE"
echo "MEASURE_OUT_ROOT=$OUT_ROOT"

for n in $(seq 1 "$RUNS"); do
    run_id=$(printf '%02d' "$n")
    tag="${TAG_PREFIX}-${run_id}-$(date +%H%M%S)"
    round_log="$OUT_ROOT/round-${run_id}.log"
    echo "=== RUN $run_id/$RUNS tag=$tag ==="
    set +e
    PAGE_URL="$PAGE_URL" \
        MP_TRACE_VALUE=0 \
        STRICT_GATE=1 \
        BASE_IMG="${BASE_IMG:-}" \
        PKG_TARBALL="${PKG_TARBALL:-}" \
        bash "$T490/t490_round.sh" "$tag" "$DURATION" "$INTERVAL" "$AUTORUN" \
        2>&1 | tee "$round_log"
    round_rc=${PIPESTATUS[0]}
    set -e

    evidence=$(sed -n 's/^EVIDENCE=//p' "$round_log" | tail -1)
    if [ -z "$evidence" ]; then
        evidence=$(find "$ROOT/evidence" -maxdepth 1 -type d -name "*_t490-$tag" -print -quit)
    fi
    [ -n "$evidence" ] && [ -d "$evidence" ] || die "无法定位本轮 evidence 目录，见 $round_log"
    printf '%s\n' "$evidence" > "$OUT_ROOT/evidence-${run_id}.txt"

    set +e
    python3 "$ROOT/scripts/collect_metrics.py" "$evidence" \
        --run "$run_id" --csv "$RAW_CSV" --profile "official-$PAGE" \
        2>&1 | tee "$OUT_ROOT/collect-${run_id}.log"
    collect_rc=${PIPESTATUS[0]}
    set -e
    if [ "$round_rc" -ne 0 ] || [ "$collect_rc" -ne 0 ]; then
        echo "MEASURE_ABORT run=$run_id round_rc=$round_rc collect_rc=$collect_rc"
        echo "保留失败证据，不生成通过的汇总。" >&2
        exit 4
    fi
done

if [ -n "$BASELINE_SUMMARY" ]; then
    python3 "$ROOT/scripts/measure.py" "$RAW_CSV" "$SUMMARY_JSON" \
        --minimum 5 --baseline "$BASELINE_SUMMARY"
else
    python3 "$ROOT/scripts/measure.py" "$RAW_CSV" "$SUMMARY_JSON" --minimum 5
fi
sha256sum "$RAW_CSV" "$SUMMARY_JSON" > "$OUT_ROOT/sha256sums.txt"
echo "MEASURE_PASS raw=$RAW_CSV summary=$SUMMARY_JSON"

