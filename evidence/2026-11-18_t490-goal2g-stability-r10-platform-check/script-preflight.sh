#!/usr/bin/env bash
set -uo pipefail
cd /home/mo/xk6
bash -n scripts/t490/autorun_mp_score_observe6.sh scripts/t490/t490_round.sh scripts/t490/run_stability_round_mp.sh
bash scripts/t490/run_stability_round_mp.sh --help > /tmp/r10-help.txt
grep -F MP_FAMILY_WATCHDOG_INTERVAL /tmp/r10-help.txt
set +e
MP_FAMILY_WATCHDOG_INTERVAL=invalid bash scripts/t490/run_stability_round_mp.sh goal2g-stability-r10 4200 30 > /tmp/r10-invalid.log 2>&1
rc=$?
set -e
cat /tmp/r10-invalid.log
[[ "$rc" -eq 2 ]]
echo "INVALID_ARGUMENT_REJECTED_RC=$rc"
if ps -eo comm= | grep -qx qemu-system-aarch64; then
    echo QEMU_ALREADY_RUNNING
    exit 1
fi
echo NO_QEMU_RUNNING
sha256sum scripts/t490/autorun_mp_score_observe6.sh scripts/t490/t490_round.sh scripts/t490/run_stability_round_mp.sh
