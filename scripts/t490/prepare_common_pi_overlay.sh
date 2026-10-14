#!/usr/bin/env bash
# Opt-in common user-space stack for the first-tag/current-kernel comparison.
set -u
set -o pipefail
if [ "$#" -eq 1 ] && [ "$1" = "--help" ]; then
    echo "Usage: $0 <p31-overlay.tar.gz> <new-common-overlay.tar.gz>"
    echo "Both comparison kernels must use the same generated overlay and common autorun."
    exit 0
fi
[ "$#" -eq 2 ] || { echo "Expected input and new output paths" >&2; exit 2; }
BASE_OVERLAY=$1
OUT_OVERLAY=$2
HERE="$(cd "$(dirname "$0")" && pwd)"
CC=aarch64-linux-musl-gcc
if [ -n "$(printenv COMMON_PI_CC)" ]; then CC="$(printenv COMMON_PI_CC)"; fi
[ -f "$BASE_OVERLAY" ] || { echo "Missing input overlay" >&2; exit 1; }
[ ! -e "$OUT_OVERLAY" ] && [ ! -e "$OUT_OVERLAY.sha256" ] || { echo "Refuse existing output" >&2; exit 1; }
STAGE="$(mktemp -d -t xk-common-pi.XXXXXXXX)" || exit 1
trap 'rm -rf -- "$STAGE"' EXIT
tar -xzf "$BASE_OVERLAY" -C "$STAGE" || exit 1
mkdir -p "$STAGE/usr/local/lib" || exit 1
"$CC" -shared -fPIC -O2 -Wall -Wextra -pthread "$HERE/common_pi_adapter.c" \
    -ldl -o "$STAGE/usr/local/lib/libxk-common-pi.so" || exit 1
mkdir -p "$(dirname "$OUT_OVERLAY")" || exit 1
tar -czf "$OUT_OVERLAY" -C "$STAGE" . || exit 1
{
    sha256sum "$BASE_OVERLAY" "$OUT_OVERLAY" "$HERE/common_pi_adapter.c"
    sha256sum "$STAGE/usr/local/lib/libxk-common-pi.so"
} > "$OUT_OVERLAY.sha256"
echo "COMMON_OVERLAY=$OUT_OVERLAY"
echo "Priority inheritance is disabled for Chromium mutex attributes in BOTH comparison cases."
