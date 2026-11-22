#!/usr/bin/env bash
set -euo pipefail
OUT=evidence/2026-11-18_wsl2-final-acceptance-preflight-r6
bash -n scripts/final-acceptance.sh scripts/t490/remote.sh
python3 -B scripts/baseline_inventory.py --help > "$OUT/baseline-help.txt"
python3 -B scripts/goal_audit.py --help > "$OUT/goal-audit-help.txt"
python3 -B scripts/evidence_completeness.py --help > "$OUT/evidence-completeness-help.txt"
bash scripts/final-acceptance.sh --help > "$OUT/final-acceptance-help.txt"
python3 scripts/baseline_inventory.py --root . --out "$OUT/baseline-inventory.json" > "$OUT/baseline-inventory.stdout"
python3 scripts/evidence_completeness.py evidence/2026-11-18_t490-goal2g-stability-r10 --stage stability --strict > "$OUT/r10-evidence-completeness.json"
set +e
python3 scripts/goal_audit.py --root . --summary "$OUT/goal-audit.json" --strict > "$OUT/goal-audit.log"
audit_rc=$?
set -e
[[ "$audit_rc" -eq 1 ]]
set +e
ACCEPTANCE_OUT="$OUT/invalid-stage-should-not-exist" bash scripts/final-acceptance.sh invalid > "$OUT/invalid-args.log" 2>&1
invalid_rc=$?
set -e
[[ "$invalid_rc" -eq 64 ]]
[[ ! -e "$OUT/invalid-stage-should-not-exist" ]]
T490_TARGET=mo@10.249.11.192 bash scripts/t490/remote.sh ssh "date +%F_%T_%Z" > "$OUT/remote-clock.txt"
T490_TARGET=mo@10.249.11.192 bash scripts/t490/remote.sh ssh "if ps -eo pid=,args= | grep -E \"^[[:space:]]*[0-9]+[[:space:]]+(qemu-system-aarch64|[^ ]*/qemu-system-aarch64)[[:space:]]\" >/dev/null; then echo QEMU_RUNNING; exit 1; else echo NO_QEMU_RUNNING; fi" > "$OUT/remote-qemu-check.txt"
grep -qx NO_QEMU_RUNNING "$OUT/remote-qemu-check.txt"
ACCEPTANCE_DRY_RUN=1 ACCEPTANCE_OUT="$OUT/dry-run" bash scripts/final-acceptance.sh all > "$OUT/dry-run-console.log" 2>&1
python3 - "$OUT/dry-run/acceptance.json" "$OUT/dry-run/result.env" "$OUT/dry-run-console.log" <<'PY'
import json, sys
from pathlib import Path
payload=json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
rows={}
for line in Path(sys.argv[2]).read_text(encoding='utf-8').splitlines():
    key,value=line.split('=',1); rows[key]=int(value)
console=Path(sys.argv[3]).read_text(encoding='utf-8',errors='replace')
required={'score-process','html','tabs','input','javascript','css','function','stability','perf','report'}
assert payload['dry_run'] is True
assert payload['overall_rc']==0
assert payload['browser_score']['points'] is None
assert payload['browser_score']['max_points']==20
assert required.issubset(rows)
assert all(rows[key]==0 for key in required)
assert console.count('DRY_RUN command:') >= 9
assert 'MP_FAMILY_WATCHDOG_INTERVAL=14' in console
assert 'goal_audit.py' in console and '--strict' in console
assert 'ACCEPTANCE_RC=0' in console
print('DRY_RUN_WIRING_PASS stages='+','.join(sorted(required)))
PY
printf 'syntax=PASS\nhelper_help=PASS\ninvalid_stage_rc=%s\ninvalid_stage_output_created=no\nr10_evidence_completeness=PASS\ngoal_audit=INCOMPLETE_expected_strict_rc=%s\nremote_ssh=PASS\nremote_qemu=NONE\ndry_run=PASS\n' "$invalid_rc" "$audit_rc" > "$OUT/verification.txt"
