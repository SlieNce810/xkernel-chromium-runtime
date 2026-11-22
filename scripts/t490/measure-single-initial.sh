#!/usr/bin/env bash
# Five-run single-process initial-round measurement.
# Run on the Linux T490 host; every run uses a fresh QEMU and immutable evidence dir.

set -u
set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
export XK6_ROOT="${XK6_ROOT:-$ROOT}"
export KERNEL_REPO="${KERNEL_REPO:-$HOME/x-kernel}"
# Preserve the archived performance stack even when started in a desktop terminal.
export QEMU_DISPLAY="${QEMU_DISPLAY:-none}"
RUNS="${MEASURE_RUNS:-5}"
DURATION="${MEASURE_DURATION:-300}"
INTERVAL="${MEASURE_INTERVAL:-60}"
FIRST_SHOT="${MEASURE_FIRST_SHOT:-180}"
ROUND_STRICT="${MEASURE_STRICT_GATE:-1}"
TAG_PREFIX="${MEASURE_TAG_PREFIX:-single-perf}"
AUTORUN="${MEASURE_AUTORUN:-autorun_single_initial.sh}"
OUT_ROOT="${MEASURE_OUT_ROOT:-$ROOT/evidence/$(date +%Y-%m-%d)_measure-$TAG_PREFIX}"
RAW_CSV="$OUT_ROOT/raw.csv"
SUMMARY_JSON="$OUT_ROOT/summary.json"
BASE_IMG="${BASE_IMG:-$KERNEL_REPO/images/agentos-weston.img}"
PKG_TARBALL="${PKG_TARBALL:-}"
if [ -z "$PKG_TARBALL" ]; then
    if [ -f "$ROOT/guest-overlays/eudev-seatprobe-libinput-swiftshader-p31.tar.gz" ]; then
        PKG_TARBALL="$ROOT/guest-overlays/eudev-seatprobe-libinput-swiftshader-p31.tar.gz"
    else
        PKG_TARBALL="$ROOT/tmp/eudev-seatprobe-libinput-swiftshader-p31.tar.gz"
    fi
fi

export PATH="$HOME/qemu-root/usr/bin:$HOME/.cargo/bin:$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"

die() { echo "ERROR: $*" >&2; exit 2; }
case "$(uname -s 2>/dev/null || true)" in Linux) ;; *) die "只在 Linux/T490 主机运行" ;; esac
case "$RUNS" in ''|*[!0-9]*) die "MEASURE_RUNS 必须为正整数" ;; esac
[ "$RUNS" -ge 5 ] || die "初赛测量至少 5 次"
case "$FIRST_SHOT" in ''|*[!0-9]*) die "MEASURE_FIRST_SHOT must be an integer" ;; esac
case "$ROUND_STRICT" in 0|1) ;; *) die "MEASURE_STRICT_GATE must be 0 or 1" ;; esac
[ -x "$HERE/t490_round.sh" ] || die "缺少 t490_round.sh"
case "$AUTORUN" in autorun_single_initial.sh) ;; *) die "Unsupported MEASURE_AUTORUN in the minimal delivery" ;; esac
[ -f "$HERE/$AUTORUN" ] || die "Missing autorun: $AUTORUN"
[ -f "$ROOT/scripts/collect_single_metrics.py" ] || die "缺少 collect_single_metrics.py"
[ ! -e "$RAW_CSV" ] || die "拒绝覆盖已有 raw.csv: $RAW_CSV"
mkdir -p "$OUT_ROOT"

{
    echo "MEASURE_START=$(date -Is)"
    echo "QEMU_DISPLAY=$QEMU_DISPLAY DISPLAY_SIZE=1280x800"
    echo "AUTORUN=$AUTORUN DURATION=$DURATION INTERVAL=$INTERVAL FIRST_SHOT=$FIRST_SHOT STRICT_GATE=$ROUND_STRICT HOLD=120"
    echo "HOST=$(hostname)"
    uname -a
    lscpu | grep -E 'Model name|CPU\(s\)|Architecture' || true
    if command -v qemu-system-aarch64 >/dev/null 2>&1; then qemu-system-aarch64 --version | head -1; else echo 'qemu-system-aarch64: unavailable in PATH'; fi
    sha256sum "$BASE_IMG" "$PKG_TARBALL"
    echo "--- 脚本指纹（复现入口）---"
    sha256sum "$HERE/measure-single-initial.sh" "$HERE/t490_round.sh" \
              "$HERE/autorun_single_initial.sh" "$ROOT/scripts/collect_single_metrics.py" \
              "$ROOT/scripts/observe_qemu.py" "$ROOT/scripts/measure.py" 2>/dev/null
} > "$OUT_ROOT/host.txt"

for n in $(seq 1 "$RUNS"); do
    run_id=$(printf '%02d' "$n")
    tag="${TAG_PREFIX}-${run_id}-$(date +%H%M%S)"
    round_log="$OUT_ROOT/round-${run_id}.log"
    # host 观测器（observe_qemu.py）：/proc 采样 QEMU 进程，产出峰值 RSS 与 CPU%
    # 两类 host 侧指标（perf/eBPF 权限受限时的合规回退，2026-10-13 接入）
    obs_csv="$OUT_ROOT/observer-run${run_id}.csv"
    obs_json="$OUT_ROOT/observer-run${run_id}.json"
    (
        set +e          # pgrep 轮询无命中属正常；避免继承测量的 set -e/pipefail 致死
        set +o pipefail # （2026-10-13 修复：否则第 2 轮起观测器子 shell 被静默杀死）
        qpid=""
        for _ in $(seq 1 180); do
            qpid=$(pgrep -f "qemu-system-aarch64" | head -1)
            [ -n "$qpid" ] && break
            sleep 1
        done
        if [ -n "$qpid" ]; then
            python3 "$ROOT/scripts/observe_qemu.py" --pid "$qpid" --interval 2 \
                --csv "$obs_csv" --summary "$obs_json" >> "$OUT_ROOT/observer-run${run_id}.log" 2>&1
        fi
    ) &
    OBS_BG_PID=$!
    set +e
    ASSERT_PROFILE=official-index FIRST_SHOT="$FIRST_SHOT" SINGLE_HOLD_VALUE=120 SINGLE_SAMPLE_VALUE=15 \
        MP_TRACE_VALUE=0 STRICT_GATE="$ROUND_STRICT" BASE_IMG="$BASE_IMG" PKG_TARBALL="$PKG_TARBALL" \
        bash "$HERE/t490_round.sh" "$tag" "$DURATION" "$INTERVAL" "$AUTORUN" \
        2>&1 | tee "$round_log"
    round_rc=${PIPESTATUS[0]}
    set -e
    evidence=$(sed -n 's/^EVIDENCE=//p' "$round_log" | tail -1)
    if [ -z "$evidence" ] || [ ! -d "$evidence" ]; then
        evidence=$(find "$XK6_ROOT/evidence" -maxdepth 1 -type d -name "*_t490-$tag" -print -quit)
    fi
    [ -n "$evidence" ] && [ -d "$evidence" ] || die "无法定位 evidence: $round_log"
    printf '%s\n' "$evidence" > "$OUT_ROOT/evidence-${run_id}.txt"
    wait "$OBS_BG_PID" 2>/dev/null || true
    set +e
    obs_args=()
    [ -f "$obs_json" ] && obs_args=(--observer "$obs_json")
    python3 "$ROOT/scripts/collect_single_metrics.py" "$evidence" --run "$run_id" \
        --csv "$RAW_CSV" --profile official-index \
        ${obs_args[@]+"${obs_args[@]}"} 2>&1 | tee "$OUT_ROOT/collect-${run_id}.log"
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
