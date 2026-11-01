#!/usr/bin/env bash
# Shared T490 connection entry point for active operations.
set -u
set -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROFILE="${T490_PROFILE:-${ROOT_DIR}/scripts/t490/remote.env}"
if [[ ! -f "${PROFILE}" ]]; then
    PROFILE="${ROOT_DIR}/scripts/t490/remote.env.example"
fi
# shellcheck disable=SC1090
source "${PROFILE}"

: "${T490_TARGET:?T490_TARGET is missing from ${PROFILE}}"
SSH_BIN="${SSH_BIN:-ssh}"
SCP_BIN="${SCP_BIN:-scp}"
SSH_KEY_ARGS=()
if [[ -n "${T490_SSH_KEY:-}" && -f "${T490_SSH_KEY}" ]]; then
    SSH_KEY_ARGS=(-i "${T490_SSH_KEY}")
fi

usage() {
    cat <<'EOF'
Usage:
  remote.sh show                 Print the resolved connection profile.
  remote.sh check                Run the read-only T490 baseline check.
  remote.sh ssh COMMAND          Run COMMAND on T490.
  remote.sh scp SRC DEST         Copy SRC to DEST using the active profile.
EOF
}

case "${1:-}" in
    show)
        printf 'T490_TARGET=%s\nT490_SSH_KEY=%s\nT490_KERNEL_DIR=%s\nT490_WORK_DIR=%s\n' \
            "${T490_TARGET}" "${T490_SSH_KEY}" "${T490_KERNEL_DIR}" "${T490_WORK_DIR}"
        ;;
    check)
        exec "${ROOT_DIR}/scripts/t490/remote_baseline_check.sh"
        ;;
    ssh)
        shift
        [[ $# -gt 0 ]] || { usage >&2; exit 2; }
        # Keep the command as one argument so remote shell quoting remains the caller's choice.
        exec "${SSH_BIN}" ${T490_SSH_OPTIONS} "${SSH_KEY_ARGS[@]}" "${T490_TARGET}" "$*"
        ;;
    scp)
        [[ $# -eq 3 ]] || { usage >&2; exit 2; }
        exec "${SCP_BIN}" ${T490_SSH_OPTIONS} "${SSH_KEY_ARGS[@]}" "$2" "${T490_TARGET}:$3"
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
