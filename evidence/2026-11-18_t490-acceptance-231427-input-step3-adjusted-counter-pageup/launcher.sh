#!/usr/bin/env bash
set -u
cd /home/mo/xk6 || exit 70
TAG=codex-2026-11-18_231427-input-step3-adjusted-counter-pageup
RCFILE=/home/mo/xk6/tmp/codex-2026-11-18_231427-input-step3-adjusted-counter-pageup.rc
env -u PLAT_MEM_OVERRIDE EVDEV_PROBE=0 INTERACTION_POINTER_MODE=step3 INPUT_NAVIGATION_WAIT=60 MULTIPROCESS=1 FORCE_HMP=1 ABS_POINTER=0 NO_CLAMP=1 EXTRA_FLAGS_VALUE=--js-flags=--jitless READY_TIMEOUT=2000 bash scripts/t490/run_input_final.sh "$TAG" 2400 60
rc=$?
printf '%s\n' "$rc" > "$RCFILE"
exit "$rc"