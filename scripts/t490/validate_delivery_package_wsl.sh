#!/usr/bin/env bash
# Build and run the packaged project in a new WSL Linux HOME.
set -u
set -o pipefail
die() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
[ "$#" -eq 2 ] || die "usage: $0 package.zip new-validation-home"
ARCHIVE="$(realpath "$1")"
REAL_HOME="$(cd "$HOME" && pwd -P)"
VALIDATION_HOME="$(realpath -m "$2")"
[ -f "$ARCHIVE" ] || die "package ZIP does not exist"
[ ! -e "$VALIDATION_HOME" ] || die "validation home already exists"
EXPECTED_ARCHIVE_SHA="$(cut -d' ' -f1 "$ARCHIVE.sha256")"
ACTUAL_ARCHIVE_SHA="$(sha256sum "$ARCHIVE" | cut -d' ' -f1)"
[ "$EXPECTED_ARCHIVE_SHA" = "$ACTUAL_ARCHIVE_SHA" ] || die "package SHA-256 mismatch"
mkdir -p "$VALIDATION_HOME"
export HOME="$VALIDATION_HOME"
export CARGO_HOME="$REAL_HOME/.cargo"
export RUSTUP_HOME="$REAL_HOME/.rustup"
export QEMU_ROOT="$REAL_HOME/qemu-8.2.3/bin"
TASK_MUSL_BIN="$REAL_HOME/musl/aarch64-linux-musl-cross/bin"
export PATH="$CARGO_HOME/bin:$QEMU_ROOT:$TASK_MUSL_BIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
mkdir -p "$HOME/xk6" "$HOME/xk6/tmp" "$HOME/xk6/evidence"
unzip -q "$ARCHIVE" -d "$HOME/xk6" || die "failed to extract package"
(
 cd "$HOME/xk6" || exit 1
 sha256sum -c SHA256SUMS
) > "$HOME/xk6/tmp/package-hashes.log" 2>&1 || die "package file checksum failed"
"$QEMU_ROOT/qemu-system-aarch64" --version | grep -Eq 'version (8|9|[1-9][0-9])' || die "QEMU must be version 8 or newer"
ldd "$QEMU_ROOT/qemu-system-aarch64" 2>&1 | grep -q 'not found' && die "QEMU has a missing host library"
BASE_IMAGE="$HOME/xk6/assets/agentos-weston.img.xz"
echo "6ed1bff70cabaa7d215693c10d2fef72f5f23d834031e260c70e5bcfae68e561  $BASE_IMAGE" | sha256sum -c - || die "Release image checksum failed"
mkdir -p "$HOME/x-kernel/images"
xz -dc "$BASE_IMAGE" > "$HOME/x-kernel/images/agentos-weston.img" || die "image extraction failed"
test "$(sha256sum "$HOME/x-kernel/images/agentos-weston.img" | cut -d' ' -f1)" = \
 "bb25e0b298d619a62df06b0ab044750c0885adc2d34602eb0c5875a022aaee09" || die "decompressed image checksum failed"
tar -xzf "$HOME/xk6/assets/x-kernel-source-2a1b101.tar.gz" -C "$HOME" || die "kernel source extraction failed"
git -C "$HOME/x-kernel" checkout --detach 2a1b101ccf97ed255821b85628f366700089cda3 || die "source checkout failed"
test "$(git -C "$HOME/x-kernel" rev-parse HEAD)" = "2a1b101ccf97ed255821b85628f366700089cda3" || die "kernel revision mismatch"
cp "$HOME/xk6/evidence/2026-09-22_t490-stage0-freeze/src-snapshot/.config" "$HOME/x-kernel/.config"
(
 cd "$HOME/x-kernel" || exit 1
 make defconfig && make build GRAPHIC=y ACCEL=n MEM=2g SMP=4 VSOCK=n
) > "$HOME/xk6/tmp/kernel-clean-build.log" 2>&1 || die "clean checkout kernel build failed"
TAG="wsl-package-$(date +%H%M%S)"
cat > "$HOME/xk6/tmp/clean-host.txt" <<EOF
$(date -Is)
host=$(uname -a)
qemu=$("$QEMU_ROOT/qemu-system-aarch64" --version | head -n 1)
rustc=$(rustc +1.95.0 --version)
kernel-source=$(git -C "$HOME/x-kernel" rev-parse HEAD)
platform=AArch64 cortex-a76; 2 GiB; 4 vCPU; TCG; WSL2 Ubuntu 22.04
EOF
cd "$HOME/xk6" || exit 1
FINAL_FRAME_DIAGNOSTIC_ONLY=1 ASSERT_PROFILE=official-index FIRST_SHOT=180 SINGLE_HOLD_VALUE=600 STRICT_GATE=1 \
BASE_IMG="$HOME/x-kernel/images/agentos-weston.img" \
PKG_TARBALL="$HOME/xk6/guest-overlays/eudev-seatprobe-libinput-swiftshader-p31.tar.gz" \
INJECT_AUTOSTART=1 MP_TRACE_VALUE=0 QMP_SOCKET="$HOME/xk6/tmp/$TAG.qmp" \
QMP_EXTRA_ARGS='-display none' \
bash scripts/t490/t490_round.sh "$TAG" 900 60 autorun_single_initial.sh
RUN_RC=$?
OUT="$(find "$HOME/xk6/evidence" -maxdepth 1 -type d -name "*_t490-$TAG" -print -quit)"
[ -n "$OUT" ] && [ -d "$OUT" ] || die "round evidence missing"
[ "$RUN_RC" -eq 0 ] || die "round gate failed; inspect $OUT/ppm-summary.txt and console.log"
grep -q 'SINGLE_GATE=1' "$OUT/console.log" || die "single-process stability gate missing"
grep -q 'PLATFORM_COMPLIANT' "$OUT/platform-compliance.txt" || die "platform compliance marker missing"
grep -q 'GATE: PASS' "$OUT/ppm-summary.txt" || die "timed screenshot or probe gate failed"
FINAL_DIAGNOSTIC_FAIL="$(sed -n 's/^GATE  strict_fail=[0-9]* final_frame_diagnostic_fail=\([0-9]*\) probe_fail=[0-9]*$/\1/p' "$OUT/ppm-summary.txt" | tail -n 1)"
[ -n "$FINAL_DIAGNOSTIC_FAIL" ] || die "round_assert did not report final-frame diagnostic scope"
printf 'round_exit=0\nSINGLE_GATE=1\nPLATFORM=PASS=15/15\nTIMED_SCREENSHOT_GATE=PASS\nfinal_frame_diagnostic_fail=%s\n' "$FINAL_DIAGNOSTIC_FAIL" > "$OUT/clean-reproduction-result.txt"
cp "$HOME/xk6/tmp/clean-host.txt" "$OUT/clean-host.txt"
sha256sum "$ARCHIVE" "$OUT/console.log" "$OUT/ppm-summary.txt" > "$OUT/clean-run-sha256.txt"
echo "FINAL_FRAME_DIAGNOSTIC_FAIL=$FINAL_DIAGNOSTIC_FAIL"
echo "CLEAN_PACKAGE=$ARCHIVE"
echo "VALIDATION_HOME=$HOME"
echo "EVIDENCE=$OUT"
exit "$RUN_RC"
