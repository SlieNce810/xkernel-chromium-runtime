#!/usr/bin/env bash
# Read-only T490 connectivity and reproducibility baseline.
set -u
set -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE="${T490_PROFILE:-${ROOT_DIR}/scripts/t490/remote.env}"
if [[ ! -f "${PROFILE}" ]]; then PROFILE="${ROOT_DIR}/scripts/t490/remote.env.example"; fi
# shellcheck disable=SC1090
source "${PROFILE}"

: "${T490_TARGET:?T490_TARGET is missing from ${PROFILE}}"
SSH_BIN="${SSH_BIN:-ssh}"
OUT="${1:-${ROOT_DIR}/tmp/t490-baseline.txt}"
mkdir -p "$(dirname "${OUT}")"
SSH_KEY_ARGS=()
if [[ -n "${T490_SSH_KEY:-}" && -f "${T490_SSH_KEY}" ]]; then
    SSH_KEY_ARGS=(-i "${T490_SSH_KEY}")
fi

REMOTE_SCRIPT='set -u
printf "hostname="; hostname
printf "system="; . /etc/os-release 2>/dev/null && printf "%s %s" "${NAME:-unknown}" "${VERSION_ID:-unknown}" || uname -a
printf "qemu="; command -v qemu-system-aarch64 >/dev/null 2>&1 && qemu-system-aarch64 --version | head -1 || echo missing
printf "kernel_dir="; test -d "$HOME/x-kernel" && echo present || echo missing
printf "work_dir="; test -d "$HOME/xk6" && echo present || echo missing
printf "evidence_dir="; test -d "$HOME/xk6/evidence" && echo present || echo missing
printf "git="; if test -d "$HOME/x-kernel/.git"; then git -C "$HOME/x-kernel" describe --always --dirty; else echo missing; fi
printf "disk="; df -Pk "$HOME" | awk "NR==2 {print \$4 \" KiB free\"}"
printf "timestamp="; date -Is'

{
    printf '# T490 baseline check\n# target=%s\n# profile=%s\n' "${T490_TARGET}" "${PROFILE}"
    date -Is | sed 's/^/local_timestamp=/'
    printf '\n'
    "${SSH_BIN}" ${T490_SSH_OPTIONS} "${SSH_KEY_ARGS[@]}" "${T490_TARGET}" "${REMOTE_SCRIPT}"
} 2>&1 | tee "${OUT}"

if command -v rg >/dev/null 2>&1; then
    ERROR_MATCH=(rg -q 'Permission denied|Could not resolve|Connection timed out|No route to host' "${OUT}")
else
    ERROR_MATCH=(grep -E -q 'Permission denied|Could not resolve|Connection timed out|No route to host' "${OUT}")
fi
if "${ERROR_MATCH[@]}"; then
    exit 1
fi
