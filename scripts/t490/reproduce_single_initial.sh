#!/usr/bin/env bash
# Reproduce the single-process initial-round candidate on T490.

set -u
set -o pipefail

BASE_IMG="${BASE_IMG:-$HOME/x-kernel/images/agentos-weston.img}"
PKG_TARBALL="${PKG_TARBALL:-$HOME/xk6/tmp/eudev-seatprobe-libinput-swiftshader-p31.tar.gz}"
TAG="${TAG:-single-reproduce-$(date +%H%M%S)}"

cd "$HOME/xk6" || exit 1
ASSERT_PROFILE=official-index \
FIRST_SHOT=180 \
BASE_IMG="$BASE_IMG" \
PKG_TARBALL="$PKG_TARBALL" \
INJECT_AUTOSTART=1 \
STRICT_GATE=1 \
bash scripts/t490/t490_round.sh "$TAG" 720 60 autorun_single_initial.sh
