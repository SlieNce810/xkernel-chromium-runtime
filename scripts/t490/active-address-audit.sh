#!/usr/bin/env bash
# Find stale T490 addresses in active scripts/docs without touching historical evidence.
set -u
set -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OLD_ADDRESSES='10\.249\.63\.140|10\.157\.181\.239|192\.168\.1\.217'
SEARCH_ROOTS=("${ROOT_DIR}/scripts/t490" "${ROOT_DIR}/docs/demo")
found=0
for path in "${SEARCH_ROOTS[@]}"; do
    [[ -d "${path}" ]] || continue
    if command -v rg >/dev/null 2>&1; then
        SEARCH=(rg -n --glob '*.sh' --glob '*.py' --glob '*.md' "${OLD_ADDRESSES}" "${path}")
    else
        SEARCH=(grep -R -n -E --include='*.sh' --include='*.py' --include='*.md' "${OLD_ADDRESSES}" "${path}")
    fi
    if "${SEARCH[@]}"; then
        found=1
    fi
done
if [[ "${found}" -eq 0 ]]; then
    echo 'ACTIVE_ADDRESS_AUDIT=PASS'
    exit 0
fi
echo 'ACTIVE_ADDRESS_AUDIT=FAIL (use remote.sh/remote.env for active operations; historical evidence is excluded)'
exit 1
