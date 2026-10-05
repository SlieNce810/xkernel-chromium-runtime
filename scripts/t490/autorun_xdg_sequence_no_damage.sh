#!/bin/sh
set -u
LOG=/root/xdg-raw.log
RUNTIME_DIR=/run/user/0
: > "$LOG"
log() { echo "[xdgraw] $*" >> "$LOG"; echo "[xdgraw] $*" > /dev/console 2>/dev/null || true; }

mkdir -p /run/udev/data "$RUNTIME_DIR" /tmp/.X11-unix 2>/dev/null || true
chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
rm -f /run/seatd.sock "$RUNTIME_DIR"/wayland-* 2>/dev/null || true
if [ -s /pkgs.tar.gz ]; then tar -xzf /pkgs.tar.gz -C / >> "$LOG" 2>&1 || log "PKG_RC=$?"; fi
if command -v udevd >/dev/null 2>&1; then
    udevd --debug >> /root/xdg-udevd.log 2>&1 &
    UDEVD_PID=$!
    sleep 1
    udevadm trigger --action=add --subsystem-match=input >/root/xdg-udev-trigger.log 2>&1 || true
    udevadm settle --timeout=8 >/root/xdg-udev-settle.log 2>&1 || true
fi
mkdir -p /sys/dev/char/226:0/device /sys/class/drm/card0 /sys/devices/simpledrm /sys/bus/faux /sys/class/faux 2>/dev/null || true
ln -sf ../../faux /sys/dev/char/226:0/device/subsystem 2>/dev/null || true
printf 'MAJOR=226\nMINOR=0\nDEVNAME=dri/card0\nSUBSYSTEM=drm\nDEVTYPE=drm_minor\n' > /sys/class/drm/card0/uevent 2>/dev/null || true
printf '226:0\n' > /sys/class/drm/card0/dev 2>/dev/null || true
ln -sf ../../bus/faux /sys/class/drm/card0/subsystem 2>/dev/null || true
printf 'drm 1.1.0 simpledrm 1.0.0\n' > /sys/class/drm/version 2>/dev/null || true

SEATD_VTBOUND=0 seatd -l info >/root/xdg-seatd.log 2>&1 &
SEATD_PID=$!
sleep 1
env XDG_RUNTIME_DIR="$RUNTIME_DIR" WESTON_DISABLE_ATOMIC=1 \
    LIBSEAT_BACKEND=seatd SEATD_SOCK=/run/seatd.sock \
    weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
    --seat=seat0 --idle-time=0 --debug --log=/root/xdg-weston.log \
    >/root/xdg-weston-stdout.log 2>&1 &
WESTON_PID=$!
i=0
sock=""
while [ "$i" -lt 30 ]; do
    sock=$(find "$RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' 2>/dev/null | head -1)
    [ -n "$sock" ] && break
    i=$((i + 1)); sleep 1
done
if [ -z "$sock" ]; then
    log "WAYLAND_SOCKET_MISSING"
    tail -n 100 /root/xdg-weston.log >> "$LOG" 2>&1 || true
    sync
    exit 31
fi
export XDG_RUNTIME_DIR WAYLAND_DISPLAY=${sock##*/}
log "WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
XDG_RUNTIME_DIR="$RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" /xdg_sequence_probe_prebuilt >> "$LOG" 2>&1
rc=$?
cat "$LOG" > /dev/console 2>&1 || true
log "PROBE_RC=$rc"
sync
exit "$rc"
