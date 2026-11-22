#!/usr/bin/env bash
# Read-only T490 platform precheck with a unique disposable output file.
set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TAG="${1:-$(date +%Y%m%d-%H%M%S)}"
case "$TAG" in
    *[!A-Za-z0-9_-]*) echo "invalid precheck tag: $TAG" >&2; exit 2 ;;
esac
OUT="$HOME/xk6/tmp/final-acceptance-${TAG}-platform.txt"
[ ! -e "$OUT" ] || { echo "refusing to overwrite $OUT" >&2; exit 73; }
bash "$HERE/t490_platform_check.sh" "$OUT"
rc=$?
cat "$OUT"
exit "$rc"
