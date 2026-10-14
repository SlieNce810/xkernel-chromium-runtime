#!/usr/bin/env bash
# Reproduce the single-process initial-round candidate on T490.

set -u
set -o pipefail

BASE_IMG="${BASE_IMG:-$HOME/x-kernel/images/agentos-weston.img}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PKG_TARBALL="${PKG_TARBALL:-}"
if [ -z "$PKG_TARBALL" ]; then
    if [ -f "$REPO_ROOT/guest-overlays/eudev-seatprobe-libinput-swiftshader-p31.tar.gz" ]; then
        PKG_TARBALL="$REPO_ROOT/guest-overlays/eudev-seatprobe-libinput-swiftshader-p31.tar.gz"
    else
        PKG_TARBALL="$HOME/xk6/tmp/eudev-seatprobe-libinput-swiftshader-p31.tar.gz"
    fi
fi
TAG="${TAG:-single-reproduce-$(date +%H%M%S)}"

cd "$REPO_ROOT" || exit 1
ASSERT_PROFILE=official-index \
FIRST_SHOT=180 \
BASE_IMG="$BASE_IMG" \
PKG_TARBALL="$PKG_TARBALL" \
INJECT_AUTOSTART=1 \
STRICT_GATE=1 \
bash scripts/t490/t490_round.sh "$TAG" 720 60 autorun_single_initial.sh
