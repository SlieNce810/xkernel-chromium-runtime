#!/usr/bin/env bash
# Pack only the eudev daemon, tools, and standard rules from the staged Alpine
# package install. Shared system libraries already match the Alpine 3.22 guest.
set -euo pipefail

ROOTFS="$HOME/xk6/tmp/eudev-overlay-3.22/root"
OUT="$HOME/xk6/tmp/eudev-runtime-overlay-3.22.tar.gz"

[[ -d "$ROOTFS/usr/lib/udev/rules.d" ]] || {
    echo "missing staged eudev rules: $ROOTFS/usr/lib/udev/rules.d" >&2
    exit 1
}
[[ -x "$ROOTFS/sbin/udevd" && -x "$ROOTFS/bin/udevadm" ]] || {
    echo "missing staged udevd/udevadm" >&2
    exit 1
}
[[ ! -e "$OUT" ]] || {
    echo "refusing to overwrite existing runtime overlay: $OUT" >&2
    exit 1
}

tar -czf "$OUT" -C "$ROOTFS" \
    sbin/udevd sbin/udevadm bin/udevadm \
    etc/udev/udev.conf usr/lib/udev

sha256sum "$OUT" | tee "$OUT.sha256"
printf 'overlay=%s\n' "$OUT"
printf 'entries=%s\n' "$(tar -tzf "$OUT" | wc -l)"
