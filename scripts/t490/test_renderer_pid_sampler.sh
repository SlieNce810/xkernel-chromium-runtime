#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTORUN="$HERE/autorun_mp_diag.sh"

if ! grep -Fq "grep '[t]ype=renderer' | awk '{ print \$1 }'" "$AUTORUN"; then
    echo "renderer sampler does not use the self-match-safe filter" >&2
    exit 1
fi

# The old awk matcher also selects its own command line from a ps snapshot.
old_ids="$(printf '%s\n' \
    '70 /usr/lib/chromium --type=renderer' \
    '99 awk /type=renderer/ { print $1 }' \
    | awk '/type=renderer/ { print $1 }' \
    | paste -sd, -)"

# The bracket expression matches the renderer row but not grep's own argv;
# the downstream awk command no longer contains the renderer pattern.
new_ids="$(printf '%s\n' \
    '70 /usr/lib/chromium --type=renderer' \
    '71 grep [t]ype=renderer' \
    '72 awk { print $1 }' \
    | grep '[t]ype=renderer' \
    | awk '{ print $1 }' \
    | paste -sd, -)"

printf 'old_pattern_pids=%s\nnew_pattern_pids=%s\n' "$old_ids" "$new_ids"
[[ "$old_ids" == "70,99" ]]
[[ "$new_ids" == "70" ]]
echo 'PASS renderer PID sampler avoids its own process'