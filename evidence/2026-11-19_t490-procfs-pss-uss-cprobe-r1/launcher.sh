#!/usr/bin/env bash
set -u
cd /home/mo/xk6 || exit 70
TAG=codex-2026-11-19_122600-procfs-pss-uss-cprobe-r1
RCFILE=/home/mo/xk6/tmp/${TAG}.rc
env -u PLAT_MEM_OVERRIDE \
  KERNEL_DIR=/home/mo/xk6/worktrees/xk-compat-fix-r1 \
  BASE_IMG=/home/mo/x-kernel/images/pkg-installed.img \
  ASSERT_PROFILE=legacy STRICT_GATE=0 FIRST_SHOT=60 \
  bash scripts/t490/t490_round.sh "$TAG" 300 60 \
  autorun_compat_memory_bundle.sh compatprobe.c procfs_memory_probe.c
rc=$?
printf '%s\n' "$rc" > "$RCFILE"
exit "$rc"
