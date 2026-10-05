#!/usr/bin/env bash
# Build a disposable Alpine 3.22 eudev overlay for QEMU input discovery.
# It contains official package files only; it does not synthesize udev records.
set -euo pipefail

WORK="$HOME/xk6/tmp/eudev-overlay-3.22"
ROOTFS="$WORK/root"
APK_CACHE="$WORK/apk-cache"
OUT="$HOME/xk6/tmp/eudev-overlay-3.22.tar.gz"
APK="$HOME/xk6/tmp/apkstatic/sbin/apk.static"
MIRROR="https://dl-cdn.alpinelinux.org/alpine/v3.22"

[[ -x "$APK" ]] || { echo "missing apk.static: $APK" >&2; exit 1; }
[[ ! -e "$WORK" && ! -e "$OUT" ]] || {
    echo "refusing to overwrite existing eudev overlay work: $WORK or $OUT" >&2
    exit 1
}
mkdir -p "$ROOTFS" "$APK_CACHE"

"$APK" --usermode --arch aarch64 --root "$ROOTFS" \
    --cache-dir "$APK_CACHE" \
    --repository "$MIRROR/main" --repository "$MIRROR/community" \
    --allow-untrusted --no-scripts --initdb add eudev

printf '%s\n' '--- installed udev components ---'
find "$ROOTFS" \( -name udevd -o -name udevadm -o -path '*/udev/rules.d/*.rules' \) -type f -printf '%P %s bytes\n' | sort
[[ -x "$ROOTFS/sbin/udevd" || -x "$ROOTFS/usr/lib/eudev/udevd" || -x "$ROOTFS/usr/lib/udev/udevd" ]] || {
    echo "udevd not found in package overlay" >&2
    exit 1
}

# The overlay is extracted into a fresh per-round disk image. Do not replace
# that image's existing apk database or cache with the staging install database.
tar -czf "$OUT" \
    --exclude='./lib/apk' --exclude='./etc/apk' --exclude='./var/cache/apk' \
    -C "$ROOTFS" .
sha256sum "$OUT" | tee "$OUT.sha256"
printf 'overlay=%s\n' "$OUT"
printf 'entries=%s\n' "$(tar -tzf "$OUT" | wc -l)"
