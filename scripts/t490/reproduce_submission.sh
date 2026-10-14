#!/usr/bin/env bash
# Minimal submission entry point for the native Linux T490 host.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export XK6_ROOT="$ROOT"
export KERNEL_REPO="${KERNEL_REPO:-$(dirname "$ROOT")/x-kernel-final}"
export XKERNEL_DIR="$KERNEL_REPO"
export PATH="$HOME/.cargo/bin:$HOME/qemu-root/usr/bin:$HOME/musl/aarch64-linux-musl-cross/bin:/usr/sbin:/sbin:$PATH"
export PKG_TARBALL="$ROOT/guest-overlays/eudev-seatprobe-libinput-swiftshader-p31.tar.gz"
export BASE_IMG="${BASE_IMG:-$KERNEL_REPO/images/agentos-weston.img}"
IMAGE_XZ="${BASE_IMAGE_XZ:-$ROOT/assets/agentos-weston.img.xz}"
REV=2a1b101ccf97ed255821b85628f366700089cda3
IMAGE_HASH=bb25e0b298d619a62df06b0ab044750c0885adc2d34602eb0c5875a022aaee09
XZ_HASH=6ed1bff70cabaa7d215693c10d2fef72f5f23d834031e260c70e5bcfae68e561
SOURCE_HASH=39655cd1769a838e67bc4078a37ad3e868541f7be795981fac717503605d0366
OVERLAY_HASH=56dba17c74ff80399d32a3fceef9ffa724a0197992fdc5934e0e254a8d8cf4b2
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
check_hash() { printf '%s  %s\n' "$2" "$1" | sha256sum -c -; }
usage() {
    cat <<'EOF'
Usage: bash scripts/t490/reproduce_submission.sh [--prepare|--check|--dry-run|--run]
  --prepare  Verify assets, download the pinned base image if needed, extract/build source.
  --check    Verify assets, source revision, image, tools and platform without starting QEMU.
  --dry-run  Run --check, then save the full QEMU command without starting QEMU.
  --run      Run --check, then execute the 900-second official-index round (default).
Environment: KERNEL_REPO (default sibling x-kernel-final), BASE_IMAGE_XZ (cached .xz),
             BASE_IMG (uncompressed base), TAG (new scenario name),
             QEMU_DISPLAY=gtk|none (default gtk with DISPLAY, otherwise none).
Run on native T490 Linux. Keep existing source/evidence directories intact.
EOF
}
case "${1:---run}" in
    --help|-h) usage; exit 0 ;;
    --prepare|--check|--dry-run|--run) ACTION="${1:---run}" ;;
    *) usage >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || die 'Only one action is accepted'
[ "$(uname -s)" = Linux ] || die 'Native Linux host required'
for tool in python3 git make cargo rustc qemu-system-aarch64 aarch64-linux-musl-gcc debugfs e2fsck sha256sum tar xz flock; do
    command -v "$tool" >/dev/null || die "Missing tool: $tool"
done
check_hash "$ROOT/assets/x-kernel-source-2a1b101.tar.gz" "$SOURCE_HASH"
check_hash "$PKG_TARBALL" "$OVERLAY_HASH"
if [ "$ACTION" = --prepare ]; then
    if [ ! -e "$KERNEL_REPO" ]; then
        mkdir -p "$(dirname "$KERNEL_REPO")"
        STAGE="$(mktemp -d "$(dirname "$KERNEL_REPO")/.xkernel-source.XXXXXX")"
        tar -xzf "$ROOT/assets/x-kernel-source-2a1b101.tar.gz" -C "$STAGE"
        [ ! -e "$KERNEL_REPO" ] || die 'Source destination appeared during extraction'
        mv -- "$STAGE/x-kernel" "$KERNEL_REPO"
        rmdir -- "$STAGE"
        cp "$ROOT/config/xkernel.config" "$KERNEL_REPO/.config"
    fi
    [ "$(git -C "$KERNEL_REPO" rev-parse HEAD)" = "$REV" ] || die 'Source revision differs'
    [ -z "$(git -C "$KERNEL_REPO" status --porcelain)" ] || die 'Source worktree is dirty'
    if [ ! -e "$BASE_IMG" ]; then
        if [ ! -f "$IMAGE_XZ" ]; then
            command -v curl >/dev/null || die 'Install curl or provide BASE_IMAGE_XZ'
            mkdir -p "$(dirname "$IMAGE_XZ")"
            PART="$(mktemp "${IMAGE_XZ}.download.XXXXXX")"
            curl --fail --location --retry 2 'https://github.com/SlieNce810/xkernel-chromium-runtime/releases/download/v0.1-single-initial/agentos-weston.img.xz' -o "$PART"
            check_hash "$PART" "$XZ_HASH"
            [ ! -e "$IMAGE_XZ" ] || die 'Download destination already exists'
            mv -- "$PART" "$IMAGE_XZ"
        fi
        check_hash "$IMAGE_XZ" "$XZ_HASH"
        mkdir -p "$(dirname "$BASE_IMG")"
        IMG_PART="$(mktemp "${BASE_IMG}.extract.XXXXXX")"
        xz -dc "$IMAGE_XZ" > "$IMG_PART"
        check_hash "$IMG_PART" "$IMAGE_HASH"
        [ ! -e "$BASE_IMG" ] || die 'Image destination already exists'
        mv -- "$IMG_PART" "$BASE_IMG"
    fi
    check_hash "$BASE_IMG" "$IMAGE_HASH"
    (cd "$KERNEL_REPO" && make defconfig && make build GRAPHIC=y ACCEL=n MEM=2g SMP=4 VSOCK=n)
    printf 'PREPARE=PASS\n'
    exit 0
fi
[ "$(git -C "$KERNEL_REPO" rev-parse HEAD)" = "$REV" ] || die 'Run --prepare first; pinned source required'
[ -z "$(git -C "$KERNEL_REPO" status --porcelain)" ] || die 'Source worktree is dirty'
check_hash "$BASE_IMG" "$IMAGE_HASH"
mkdir -p "$ROOT/tmp"
bash "$ROOT/scripts/t490/t490_platform_check.sh" "$ROOT/tmp/submission-platform-check.txt"
if [ "$ACTION" = --check ]; then
    printf 'CHECK=PASS\n'; exit 0
fi
TAG="${TAG:-final-$(date +%Y%m%d-%H%M%S)}"
. "$ROOT/scripts/t490/platform.env"
if [ "$ACTION" = --dry-run ]; then
    python3 "$ROOT/scripts/run-session.py" --dry-run --cwd "$KERNEL_REPO" \
        --make-args "$PLAT_MAKE_ARGS" --with-input --require-platform-compliance \
        --display-mode "$PLAT_DISPLAY_MODE" --display-size "$PLAT_DISPLAY_SIZE" \
        --duration 900 --first-shot 180 --interval 60 --out "$ROOT/tmp/dry-run-$TAG"
    exit 0
fi
EVID="$ROOT/evidence/$(date +%F)_t490-$TAG"
FINAL_FRAME_DIAGNOSTIC_ONLY=1 ASSERT_PROFILE=official-index FIRST_SHOT=180 \
    SINGLE_HOLD_VALUE=600 STRICT_GATE=1 \
    bash "$ROOT/scripts/t490/t490_round.sh" "$TAG" 900 60 autorun_single_initial.sh
GUEST_LOG="$EVID/guest/_root_single-initial.log"
grep -Fq 'SINGLE_GATE=1' "$GUEST_LOG" || die 'Guest single-process gate did not pass'
HOLD_OBSERVED="$(sed -n 's/.*SINGLE_HOLD_REACHED elapsed=\([0-9][0-9]*\).*/\1/p' "$GUEST_LOG" | tail -1)"
[ "${HOLD_OBSERVED:-0}" -ge 600 ] || die 'Guest hold is shorter than 600 seconds'
grep -Eq '^PASS=15[[:space:]]+FAIL=0[[:space:]]*$' "$EVID/platform-compliance.txt" || die 'Platform gate did not pass'
printf 'REPRODUCTION=PASS evidence=%s hold=%ss\n' "$EVID" "$HOLD_OBSERVED"
