#!/usr/bin/env bash
set -u
cd /home/mo/xk6 || exit 70
TAG=codex-2026-11-18_184024-input-noevdev
RCFILE=/home/mo/xk6/tmp/codex-2026-11-18_184024-input-noevdev.rc
env -u PLAT_MEM_OVERRIDE EVDEV_PROBE=0 MULTIPROCESS=1 FORCE_HMP=1 ABS_POINTER=0 NO_CLAMP=1 EXTRA_FLAGS_VALUE=--js-flags=--jitless READY_TIMEOUT=2000 bash scripts/t490/run_input_final.sh "$TAG" 2400 60
rc=$?
printf '%s\n' "$rc" > "$RCFILE"
exit "$rc"