#!/usr/bin/env bash
# Add the single-seat policy as a real eudev rule to the official eudev overlay.
set -euo pipefail

ROOTFS="$HOME/xk6/tmp/eudev-overlay-3.22/root"
RULE_ROOT="$HOME/xk6/tmp/eudev-seat0-rule"
RULE="$RULE_ROOT/etc/udev/rules.d/99-xkernel-seat0.rules"
OUT="$HOME/xk6/tmp/eudev-runtime-overlay-3.22-seat0.tar.gz"

[[ -d "$ROOTFS/usr/lib/udev/rules.d" ]] || { echo "missing staged eudev tree" >&2; exit 1; }
[[ ! -e "$RULE_ROOT" && ! -e "$OUT" ]] || {
    echo "refusing to overwrite existing seat0 overlay artifacts" >&2
    exit 1
}
mkdir -p "$(dirname "$RULE")"
cat > "$RULE" <<'EOF'
# QEMU task platform has one seat; classify registered evdev nodes through udev rules.
SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT}=="1", ENV{ID_SEAT}="seat0", TAG+="seat"
EOF

tar -czf "$OUT" -C "$ROOTFS" \
    sbin/udevd sbin/udevadm bin/udevadm \
    etc/udev/udev.conf usr/lib/udev \
    -C "$RULE_ROOT" etc/udev/rules.d/99-xkernel-seat0.rules
sha256sum "$OUT" | tee "$OUT.sha256"
printf 'overlay=%s\n' "$OUT"
printf 'seat rule:\n'; cat "$RULE"
