#!/usr/bin/env bash
# Verify the Chromium major version embedded in a guest image without booting it.
set -u
set -o pipefail

IMAGE="${1:-}"
EXPECTED_MAJOR="${2:-${EXPECTED_CHROMIUM_MAJOR:-149}}"

die() {
    echo "CHROMIUM_IMAGE_VERIFY_FAIL: $*" >&2
    exit 1
}

[ -n "$IMAGE" ] || die "usage: $0 <image> [expected-major]"
[ -f "$IMAGE" ] || die "image does not exist: $IMAGE"
case "$EXPECTED_MAJOR" in
    ''|*[!0-9]*) die "expected major must be numeric: $EXPECTED_MAJOR" ;;
esac
command -v debugfs >/dev/null 2>&1 || die "debugfs is required"
command -v strings >/dev/null 2>&1 || die "strings is required"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/chromium-image-verify.XXXXXX") || die "mktemp failed"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

BIN="$TMP_DIR/chromium"
debugfs -R "dump /usr/lib/chromium/chromium $BIN" "$IMAGE" \
    >/dev/null 2>"$TMP_DIR/debugfs.log" \
    || die "cannot extract /usr/lib/chromium/chromium from $IMAGE"
[ -s "$BIN" ] || die "chromium binary is missing from $IMAGE"

VERSION_LINE=$(strings "$BIN" | grep -E "Chrome/${EXPECTED_MAJOR}\\.[0-9]" | head -1 || true)
[ -n "$VERSION_LINE" ] || die "expected Chromium major $EXPECTED_MAJOR not found in $IMAGE"

echo "CHROMIUM_IMAGE=$IMAGE"
echo "CHROMIUM_IMAGE_SHA256=$(sha256sum "$BIN" | awk '{print $1}')"
echo "CHROMIUM_IMAGE_VERSION=$VERSION_LINE"
echo "CHROMIUM_IMAGE_VERIFY=PASS"
