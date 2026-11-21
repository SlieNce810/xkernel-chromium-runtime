#!/usr/bin/env bash
# 决赛统一验收入口。每个阶段都保留独立 evidence，失败不会被后续阶段洗成 PASS。
set -u
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T490="$ROOT/scripts/t490"

usage() {
    cat <<'EOF'
Usage: bash scripts/final-acceptance.sh <baseline|precheck|score|score-process|html|multiprocess|tabs|input|javascript|css|sandbox|function|stability|perf|report|all>

Environment hooks (the default commands are intentionally conservative):
  T490_TARGET         SSH target, e.g. mo@10.249.11.192 (required for live stages)
  T490_KERNEL_DIR     remote kernel tree; pass an isolated candidate to test it
  T490_EXPECTED_KERNEL_SHA256  expected binary hash; aborts a stability run before QEMU on mismatch
  T490_BASE_IMG       remote base image (default: T490 runner's configured image)
  ACCEPTANCE_OUT      evidence output directory
  ACCEPTANCE_PRECHECK platform command (default: remote T490 read-only precheck)
  RUN_FUNCTION_CMD    optional override; default runs all six browser score items on T490/2 GiB
  RUN_HTML_CMD        optional override; default specified-HTML T490 runner (4 points)
  RUN_TABS_CMD        optional override; default two-tab QMP runner (4 points)
  RUN_INPUT_CMD       optional override; default real QMP input runner
  RUN_JAVASCRIPT_CMD  optional override; default interaction.html JS runner (2 points)
  RUN_CSS_CMD         optional override; default CSS page runner (2 points)
  RUN_STABILITY_CMD   optional override; default 30-minute/10-reload T490 runner
  RUN_PERF_CMD        optional override; default plan-driven before/after collector
  RUN_REPORT_CMD      optional override; default goal audit/report
  ACCEPTANCE_EVENTS   JSONL renderer/browser event ledger for process and render gates
  ACCEPTANCE_CONSOLE_LOG  guest Chromium console.log; derive MP_EVENT JSONL automatically
  ACCEPTANCE_CMD_FILE score command/evidence file checked for diagnostic flags
  ACCEPTANCE_SANDBOX_EVENTS JSONL sandbox evidence (preferred over a custom command)
  ACCEPTANCE_SANDBOX_CMD explicit sandbox negative-test command
  ACCEPTANCE_EVIDENCE_ROOT immutable evidence directory to check before report
  ACCEPTANCE_EVIDENCE_STAGE stage name for the evidence completeness check
  ACCEPTANCE_GOAL_AUDIT=1 run the full browser goal audit in the report stage
  ACCEPTANCE_BASELINE_ROOT  repository root used for baseline manifest (default: ROOT)
  ACCEPTANCE_PERF_PLAN      T490-side xkernel.perf-plan.v1 JSON for the perf stage
  ACCEPTANCE_DRY_RUN=1  validate wiring without starting QEMU

One-command stage entry (long running on the pure-TCG T490):
  bash scripts/final-acceptance.sh all

The `function` and `score` stages run all six browser score items. Use `html`
to run only the specified index page.
EOF
}

if [[ $# -eq 1 ]]; then
    case "$1" in
        -h|--help) usage; exit 0 ;;
    esac
fi
if [[ $# -ne 1 ]]; then usage >&2; exit 64; fi
stage="$1"
case "$stage" in baseline|precheck|score|score-process|html|multiprocess|tabs|input|javascript|css|sandbox|function|stability|perf|report|all) ;; *) usage; exit 64 ;; esac

RUN_DATE="$(date +%Y-%m-%d)"
RUN_TIME="$(date +%H%M%S)"
STAMP="${RUN_DATE}_${RUN_TIME}"
OUT="${ACCEPTANCE_OUT:-$ROOT/evidence/${RUN_DATE}_t490-acceptance-${RUN_TIME}}"
SUMMARY="$OUT/acceptance.json"
if [[ -e "$OUT" ]]; then
    echo "ACCEPTANCE_OUT already exists; refusing to overwrite: $OUT" >&2
    exit 73
fi
mkdir -p "$OUT"
{
    printf 'command='
    if [[ -n "${T490_TARGET:-}" ]]; then printf 'T490_TARGET=%q ' "$T490_TARGET"; fi
    if [[ -n "${T490_KERNEL_DIR:-}" ]]; then printf 'T490_KERNEL_DIR=%q ' "$T490_KERNEL_DIR"; fi
    if [[ -n "${T490_EXPECTED_KERNEL_SHA256:-}" ]]; then printf 'T490_EXPECTED_KERNEL_SHA256=%q ' "$T490_EXPECTED_KERNEL_SHA256"; fi
    if [[ -n "${T490_BASE_IMG:-}" ]]; then printf 'T490_BASE_IMG=%q ' "$T490_BASE_IMG"; fi
    printf 'bash scripts/final-acceptance.sh %q\n' "$stage"
} > "$OUT/cmd.txt"
{
    printf 'started_at=%s\n' "$(date -Is)"
    printf 'host_platform=%s\n' "$(uname -srm 2>/dev/null || uname -a)"
    printf 'T490_TARGET=%s\n' "${T490_TARGET:-unset}"
    printf 'T490_KERNEL_DIR=%s\n' "${T490_KERNEL_DIR:-unset}"
    printf 'T490_EXPECTED_KERNEL_SHA256=%s\n' "${T490_EXPECTED_KERNEL_SHA256:-unset}"
    printf 'T490_BASE_IMG=%s\n' "${T490_BASE_IMG:-unset}"
    printf 'ACCEPTANCE_DRY_RUN=%s\n' "${ACCEPTANCE_DRY_RUN:-0}"
    printf 'PLAT_MEM_OVERRIDE=%s\n' "${PLAT_MEM_OVERRIDE:-unset}"
} > "$OUT/env.txt"

declare -A results
run_stage() {
    local name="$1"; shift
    local log="$OUT/${name}.log" rc=0
    echo "[$(date -Is)] BEGIN $name" | tee "$log"
    if [[ "${ACCEPTANCE_DRY_RUN:-0}" == 1 ]]; then
        printf 'DRY_RUN command:' | tee -a "$log"
        printf ' %q' "$@" | tee -a "$log"
        printf '\n' | tee -a "$log"
        rc=0
    else
        {
            printf '[%s] COMMAND=' "$(date -Is)"
            printf '%q ' "$@"
            printf '\n'
        } | tee -a "$log"
        "$@" 2>&1 | tee -a "$log"
        rc=${PIPESTATUS[0]}
    fi
    results["$name"]=$rc
    echo "[$(date -Is)] END $name rc=$rc" | tee -a "$log"
    return "$rc"
}

run_remote_stage() {
    local name="$1" remote_code="$2"
    local remote_env=() remote_prefix=""
    local value
    for value in "${T490_KERNEL_DIR:-}" "${T490_BASE_IMG:-}"; do
        [[ -z "$value" ]] && continue
        case "$value" in
            /*) ;;
            *) echo "T490 remote paths must be absolute: $value" >&2; results["$name"]=64; return 64 ;;
        esac
        case "$value" in
            *[!A-Za-z0-9_./-]*) echo "T490 remote paths contain unsupported characters: $value" >&2; results["$name"]=64; return 64 ;;
            */../*|*/..|*/./*|*/.) echo "T490 remote paths may not contain dot segments: $value" >&2; results["$name"]=64; return 64 ;;
        esac
    done
    [[ -z "${T490_KERNEL_DIR:-}" ]] || remote_env+=("KERNEL_DIR=$T490_KERNEL_DIR")
    [[ -z "${T490_BASE_IMG:-}" ]] || remote_env+=("BASE_IMG=$T490_BASE_IMG")
    if [[ -n "${T490_EXPECTED_KERNEL_SHA256:-}" ]]; then
        if [[ ! "${T490_EXPECTED_KERNEL_SHA256}" =~ ^[[:xdigit:]]{64}$ ]]; then
            echo "T490_EXPECTED_KERNEL_SHA256 must be exactly 64 hexadecimal characters" >&2
            results["$name"]=64
            return 64
        fi
        remote_env+=("STABILITY_EXPECTED_KERNEL_SHA256=$T490_EXPECTED_KERNEL_SHA256")
    fi
    if (( ${#remote_env[@]} > 0 )); then
        printf -v remote_prefix '%q ' "${remote_env[@]}"
    fi
    local remote_command="bash -lc 'cd /home/mo/xk6 && ${remote_prefix}${remote_code}'"
    run_stage "$name" bash "$T490/remote.sh" ssh "$remote_command"
}

run_default_stage() {
    local name="$1"
    local tag="codex-${STAMP}"
    case "$name" in
        function)
            run_function_stage
            ;;
        html)
            run_remote_stage "$name" \
                "env -u PLAT_MEM_OVERRIDE SCORE_AUTORUN=autorun_mp_score_observe6.sh PROCESS_STRUCTURE_GATE=1 EXTRA_FLAGS_VALUE=--js-flags=--jitless bash scripts/t490/run_score_page_mp.sh html ${tag}-html 1800 60"
            ;;
        score-process)
            run_remote_stage "$name" \
                "env -u PLAT_MEM_OVERRIDE SCORE_AUTORUN=autorun_mp_score_observe6.sh PROCESS_STRUCTURE_GATE=1 PROCESS_STRUCTURE_ONLY=1 EXTRA_FLAGS_VALUE=--js-flags=--jitless bash scripts/t490/run_score_page_mp.sh html ${tag}-process 1800 60"
            ;;
        tabs)
            run_remote_stage "$name" \
                "env -u PLAT_MEM_OVERRIDE EXTRA_FLAGS_VALUE=--js-flags=--jitless TABS_READY_WAIT=1800 TABS_SWITCH_TIMEOUT=1200 MP_MAX_SECONDS=2200 bash scripts/t490/run_tabs_round_mp.sh ${tag}-tabs 2400 60"
            ;;
        input)
            run_remote_stage "$name" \
                "env -u PLAT_MEM_OVERRIDE MULTIPROCESS=1 FORCE_HMP=1 ABS_POINTER=0 NO_CLAMP=1 EXTRA_FLAGS_VALUE=--js-flags=--jitless READY_TIMEOUT=2000 bash scripts/t490/run_input_final.sh ${tag}-input 2400 60"
            ;;
        javascript)
            run_remote_stage "$name" \
                "env -u PLAT_MEM_OVERRIDE EXTRA_FLAGS_VALUE=--js-flags=--jitless READY_TIMEOUT=2000 bash scripts/t490/run_javascript_round_mp.sh ${tag}-javascript 2400 60"
            ;;
        css)
            run_remote_stage "$name" \
                "env -u PLAT_MEM_OVERRIDE EXTRA_FLAGS_VALUE=--js-flags=--jitless bash scripts/t490/run_score_page_mp.sh css ${tag}-css 1800 60"
            ;;
        stability)
            run_remote_stage "$name" \
                "env -u PLAT_MEM_OVERRIDE MP_FAMILY_WATCHDOG_INTERVAL=14 MP_FAMILY_DIAGNOSTICS=1 bash scripts/t490/run_stability_round_mp.sh ${tag}-stability 4200 30"
            ;;
        perf)
            local plan="${ACCEPTANCE_PERF_PLAN:-}"
            if [[ -z "$plan" ]]; then
                if [[ "${ACCEPTANCE_DRY_RUN:-0}" == 1 ]]; then
                    run_remote_stage perf \
                        "python3 scripts/run_perf_plan.py /home/mo/xk6/evidence/perf-plan.json --out /home/mo/xk6/evidence/${STAMP%%_*}_t490-${tag}-perf-comparison"
                    return $?
                fi
                echo "缺少 ACCEPTANCE_PERF_PLAN：perf 阶段需要 T490 上的有效事件/内存样本计划" >&2
                results[perf]=78
                return 78
            fi
            case "$plan" in
                /home/mo/xk6/evidence/*) ;;
                *) echo "ACCEPTANCE_PERF_PLAN 必须位于 /home/mo/xk6/evidence" >&2; results[perf]=78; return 78 ;;
            esac
            case "$plan" in
                *[!A-Za-z0-9_./-]*) echo "ACCEPTANCE_PERF_PLAN 含非法字符" >&2; results[perf]=78; return 78 ;;
            esac
            run_remote_stage "$name" \
                "python3 scripts/run_perf_plan.py ${plan} --out /home/mo/xk6/evidence/${STAMP%%_*}_t490-${tag}-perf-comparison"
            ;;
        report)
            run_stage report python3 "$ROOT/scripts/goal_audit.py" \
                --root "$ROOT" --summary "$OUT/goal-audit.json" --strict
            ;;
        *)
            echo "no default command for stage: $name" >&2
            results["$name"]=78
            return 78
            ;;
    esac
}

run_precheck_stage() {
    local value="${ACCEPTANCE_PRECHECK:-}"
    if [[ -z "$value" ]]; then
        run_remote_stage precheck "bash scripts/t490/run_acceptance_precheck.sh ${STAMP}"
        return $?
    fi
    # shellcheck disable=SC2206
    local cmd=( $value )
    run_stage precheck "${cmd[@]}"
}

run_explicit() {
    local name="$1" var="$2"; shift 2
    local value="${!var:-}"
    if [[ -z "$value" ]]; then
        run_default_stage "$name"
        return $?
    fi
    # shellcheck disable=SC2206
    local cmd=( $value )
    run_stage "$name" "${cmd[@]}"
}

run_multiprocess_gate() {
    local events="${ACCEPTANCE_EVENTS:-}" command_file="${ACCEPTANCE_CMD_FILE:-}"
    local summary="$OUT/multiprocess-summary.json"
    if [[ -z "$events" && -n "${ACCEPTANCE_CONSOLE_LOG:-}" ]]; then
        bash "$ROOT/scripts/t490/collect_chromium_eventlog.sh" \
            "$ACCEPTANCE_CONSOLE_LOG" "$OUT/events-derived" || {
            results[multiprocess]=1
            return 1
        }
        events="$OUT/events-derived/events.raw.log"
    fi
    if [[ -z "$events" ]]; then
        if [[ "${ACCEPTANCE_DRY_RUN:-0}" == 1 ]]; then
            run_stage multiprocess python3 "$ROOT/scripts/multiprocess_eventlog.py" \
                "$OUT/placeholder-events.jsonl" --strict --summary "$summary"
            return $?
        fi
        echo "缺少 ACCEPTANCE_EVENTS：多进程阶段不会伪造 PASS" >&2
        results[multiprocess]=78
        return 78
    fi
    local cmd=(python3 "$ROOT/scripts/multiprocess_eventlog.py" "$events" --strict --summary "$summary")
    [[ -z "$command_file" ]] || cmd+=(--command "$command_file")
    run_stage multiprocess "${cmd[@]}"
}

run_process_score_gate() {
    local events="${ACCEPTANCE_EVENTS:-}" command_file="${ACCEPTANCE_CMD_FILE:-}"
    local summary="$OUT/process-structure-summary.json"
    if [[ -z "$events" && -n "${ACCEPTANCE_CONSOLE_LOG:-}" ]]; then
        bash "$ROOT/scripts/t490/collect_chromium_eventlog.sh" \
            "$ACCEPTANCE_CONSOLE_LOG" "$OUT/events-derived-process" process-structure || {
            results[score-process]=1
            return 1
        }
        events="$OUT/events-derived-process/events.raw.log"
    fi
    if [[ -z "$events" ]]; then
        if [[ "${ACCEPTANCE_DRY_RUN:-0}" == 1 ]]; then
            run_stage score-process python3 "$ROOT/scripts/multiprocess_eventlog.py" \
                "$OUT/placeholder-events.jsonl" --criterion process-structure \
                --strict --summary "$summary"
            return $?
        fi
        run_default_stage score-process
        return $?
    fi
    local cmd=(python3 "$ROOT/scripts/multiprocess_eventlog.py" "$events" \
        --criterion process-structure --strict --summary "$summary")
    [[ -z "$command_file" ]] || cmd+=(--command "$command_file")
    run_stage score-process "${cmd[@]}"
}

# The competition's 20-point browser block is intentionally independent from
# the broader system gates.  Each item has its own command and evidence so a
# sandbox, stability, or performance investigation cannot hide a score item.
run_browser_score_path() {
    run_explicit html RUN_HTML_CMD
    if [[ -z "${RUN_HTML_CMD:-}" ]]; then
        if [[ "${ACCEPTANCE_DRY_RUN:-0}" == 1 ]]; then
            results[score-process]=0
        else
            local process_rc="$(sed -n 's/^PROCESS_STRUCTURE_GATE_RC=//p' "$OUT/html.log" | tail -1)"
            if [[ "$process_rc" =~ ^[0-9]+$ ]]; then
                results[score-process]=$process_rc
            else
                echo "HTML runner did not produce PROCESS_STRUCTURE_GATE_RC" >&2
                results[score-process]=78
            fi
        fi
    else
        run_process_score_gate
    fi
    run_explicit tabs RUN_TABS_CMD
    run_explicit input RUN_INPUT_CMD
    run_explicit javascript RUN_JAVASCRIPT_CMD
    run_explicit css RUN_CSS_CMD
}

run_function_stage() {
    run_browser_score_path
    local rc=0 name
    for name in score-process html tabs input javascript css; do
        if [[ "${results[$name]:-78}" -ne 0 ]]; then
            rc=1
        fi
    done
    results[function]=$rc
    return "$rc"
}

run_baseline() {
    local baseline_root="${ACCEPTANCE_BASELINE_ROOT:-$ROOT}"
    run_stage baseline python3 "$ROOT/scripts/baseline_inventory.py" \
        --root "$baseline_root" --out "$OUT/baseline.json"
}

run_sandbox_gate() {
    local events="${ACCEPTANCE_SANDBOX_EVENTS:-}" command_file="${ACCEPTANCE_CMD_FILE:-}"
    if [[ -z "$events" ]]; then
        if [[ "${ACCEPTANCE_DRY_RUN:-0}" == 1 ]]; then
            run_stage sandbox python3 "$ROOT/scripts/sandbox_gate.py" \
                "$OUT/placeholder-sandbox-events.jsonl" --strict
            return $?
        fi
        run_explicit sandbox ACCEPTANCE_SANDBOX_CMD
        return $?
    fi
    local cmd=(python3 "$ROOT/scripts/sandbox_gate.py" "$events" --strict)
    [[ -z "$command_file" ]] || cmd+=(--command "$command_file")
    run_stage sandbox "${cmd[@]}"
}

run_report_stage() {
    if [[ -n "${ACCEPTANCE_EVIDENCE_ROOT:-}" ]]; then
        local stage_name="${ACCEPTANCE_EVIDENCE_STAGE:-report}"
        run_stage report python3 "$ROOT/scripts/evidence_completeness.py" \
            "$ACCEPTANCE_EVIDENCE_ROOT" --stage "$stage_name" --strict
        local evidence_rc=$?
        [[ "$evidence_rc" -eq 0 ]] || return "$evidence_rc"
    fi
    if [[ "${ACCEPTANCE_GOAL_AUDIT:-0}" == 1 ]]; then
        run_stage goal-audit python3 "$ROOT/scripts/goal_audit.py" \
            --root "$ROOT" --summary "$OUT/goal-audit.json" --strict
        local audit_rc=$?
        [[ "$audit_rc" -eq 0 ]] || return "$audit_rc"
    fi
    if [[ -n "${ACCEPTANCE_EVIDENCE_ROOT:-}" || "${ACCEPTANCE_GOAL_AUDIT:-0}" == 1 ]]; then
        results[report]=0
        return 0
    fi
    run_explicit report RUN_REPORT_CMD
}

set +e
case "$stage" in
    baseline) run_baseline ;;
    precheck) run_precheck_stage ;;
    score) run_explicit function RUN_FUNCTION_CMD ;;
    score-process) run_process_score_gate ;;
    html) run_explicit html RUN_HTML_CMD ;;
    multiprocess) run_multiprocess_gate ;;
    tabs) run_explicit tabs RUN_TABS_CMD ;;
    sandbox) run_sandbox_gate ;;
    function) run_explicit function RUN_FUNCTION_CMD ;;
    input) run_explicit input RUN_INPUT_CMD ;;
    javascript) run_explicit javascript RUN_JAVASCRIPT_CMD ;;
    css) run_explicit css RUN_CSS_CMD ;;
    stability) run_explicit stability RUN_STABILITY_CMD ;;
    perf) run_explicit perf RUN_PERF_CMD ;;
    report) run_report_stage ;;
    all)
        run_baseline
        run_precheck_stage
        if [[ ${results[precheck]} -eq 0 ]]; then
            run_explicit function RUN_FUNCTION_CMD
            run_explicit stability RUN_STABILITY_CMD
            run_explicit perf RUN_PERF_CMD
        else
            # Do not launch browser sessions on a platform that failed its
            # required precheck. Preserve explicit skipped statuses in report.
            for name in score-process html tabs input javascript css function stability perf; do
                results[$name]=78
            done
        fi
        run_report_stage
        ;;
esac
set -e

overall=0
for key in "${!results[@]}"; do [[ "${results[$key]}" -eq 0 ]] || overall=1; done
for key in "${!results[@]}"; do
    printf '%s=%s\n' "$key" "${results[$key]}"
done > "$OUT/result.env"
python3 - "$SUMMARY" "$stage" "$overall" "$OUT/result.env" <<'PY'
import json, sys
out, stage, overall, result_file = sys.argv[1:]
import os
dry_run = os.environ.get("ACCEPTANCE_DRY_RUN", "0") == "1"
rows = {}
for line in open(result_file, encoding="utf-8"):
    name, value = line.rstrip("\n").split("=", 1)
    rows[name] = int(value)
with open(out, "w", encoding="utf-8") as stream:
    points = {
        "score-process": 4,
        "html": 4,
        "tabs": 4,
        "input": 4,
        "javascript": 2,
        "css": 2,
    }
    score_rows = {name: rows[name] for name in points if name in rows}
    score_stages = {"score", "function", "all", *points}
    score_points = (
        sum(points[name] for name, rc in score_rows.items() if rc == 0)
        if not dry_run and stage in score_stages and score_rows
        else None
    )
    payload = {
        "stage": stage,
        "overall_rc": int(overall),
        "dry_run": dry_run,
        "results": rows,
        "browser_score": {
            "points": score_points,
            "max_points": 20,
            "items": {
                name: ({"points": points[name], "status": "NOT_RUN", "planned_rc": rc}
                       if dry_run or score_points is None else {"points": points[name], "rc": rc})
                for name, rc in score_rows.items()
            },
        },
    }
    json.dump(payload, stream, ensure_ascii=False, indent=2)
    stream.write("\n")
PY
echo "ACCEPTANCE_OUT=$OUT"
if [[ -f "$SUMMARY" ]]; then
    python3 - "$SUMMARY" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
score = data.get("browser_score", {})
if data.get("dry_run") or score.get("points") is None:
    print(f"BROWSER_SCORE=NOT_RUN/{score.get('max_points', 20)}")
else:
    print(f"BROWSER_SCORE={score.get('points', 0)}/{score.get('max_points', 20)}")
PY
fi
echo "ACCEPTANCE_RC=$overall"
python3 - "$SUMMARY" "$OUT/acceptance-report.md" <<'PY'
import json, sys
source, output = sys.argv[1:]
payload = json.load(open(source, encoding="utf-8"))
lines = [
    "# Unified acceptance result",
    "",
    f"- Stage: `{payload['stage']}`",
    f"- Overall exit code: `{payload['overall_rc']}`",
    (f"- Browser score: NOT RUN / {payload['browser_score']['max_points']}"
     if payload.get("dry_run") or payload['browser_score']['points'] is None else
     f"- Browser score: {payload['browser_score']['points']}/{payload['browser_score']['max_points']}"),
    "",
    "| Stage | Exit code |",
    "|---|---:|",
]
for name, result in sorted(payload.get("results", {}).items()):
    lines.append(f"| `{name}` | {result} |")
with open(output, "x", encoding="utf-8") as stream:
    stream.write("\n".join(lines) + "\n")
PY
exit "$overall"
