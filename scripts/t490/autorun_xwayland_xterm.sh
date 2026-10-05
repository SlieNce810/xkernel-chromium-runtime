#!/bin/sh
set -u
LOG=/root/xwayland-xterm.log
: > "$LOG"
log() { echo "[xwayland-xterm] $*" > /dev/console 2>/dev/null || true; echo "[xwayland-xterm] $*" >> "$LOG"; }

mkdir -p /run/udev/data /run/user/0 /tmp/.X11-unix \
    /sys/dev/char/226:0/device /sys/devices/simpledrm /sys/bus/faux /sys/class/drm/card0 2>/dev/null || true
printf 'E:ID_INPUT=1\nE:ID_INPUT_KEYBOARD=1\nE:ID_SEAT=seat0\n' > /run/udev/data/c13:1
ln -sf ../../faux /sys/dev/char/226:0/device/subsystem 2>/dev/null || true
printf 'MAJOR=226\nMINOR=0\nDEVNAME=dri/card0\nSUBSYSTEM=drm\nDEVTYPE=drm_minor\n' > /sys/class/drm/card0/uevent 2>/dev/null || true
printf '226:0\n' > /sys/class/drm/card0/dev 2>/dev/null || true
ln -sf ../../bus/faux /sys/class/drm/card0/subsystem 2>/dev/null || true
printf 'drm 1.1.0 simpledrm 1.0.0\n' > /sys/class/drm/version 2>/dev/null || true
chmod 700 /run/user/0 2>/dev/null || true
chmod 1777 /tmp/.X11-unix 2>/dev/null || true

pkill -x xterm 2>/dev/null || true
pkill -x weston 2>/dev/null || true
pkill -x seatd 2>/dev/null || true
rm -f /run/seatd.sock /run/user/0/wayland-* /tmp/.X11-unix/X* /tmp/weston.log
SEATD_VTBOUND=0 seatd -g root -l debug >/tmp/seatd.log 2>&1 &
sleep 2
env LD_PRELOAD=/usr/local/lib/libseat-shim.so XDG_RUNTIME_DIR=/run/user/0 WESTON_DISABLE_ATOMIC=1 \
    weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
    --seat=seat0 --continue-without-input --idle-time=0 --socket=wayland-0 --xwayland \
    --log=/tmp/weston.log >/dev/console 2>&1 &

i=0
while [ "$i" -lt 45 ]; do
    [ -S /tmp/.X11-unix/X0 ] || [ -S /tmp/.X11-unix/X1 ] || { i=$((i + 1)); sleep 1; continue; }
    break
done
XSOCK=$(ls /tmp/.X11-unix/X* 2>/dev/null | head -n1)
if [ -z "$XSOCK" ]; then
    log "Xwayland FAILED after ${i}s"
    tail -40 /tmp/weston.log >> "$LOG" 2>&1 || true
    exit 21
fi
DISPLAY=":${XSOCK##*X}"
export DISPLAY
log "Xwayland UP display=$DISPLAY socket=$XSOCK after ${i}s"

command -v xterm >/root/xwayland-xterm-command.txt 2>&1 || true
command -v xclock >>/root/xwayland-xterm-command.txt 2>&1 || true
if [ -x /usr/bin/xterm ]; then
    xterm -display "$DISPLAY" -geometry 80x24 -title xwayland-probe \
        -e /bin/sh -c 'echo XTERM_XWAYLAND_OK; sleep 90' >/root/xwayland-xterm-client.log 2>&1 &
    XPID=$!
    log "xterm pid=$XPID"
    sleep 20
    if [ -d "/proc/$XPID" ]; then
        log "xterm alive after 20s"
    else
        wait "$XPID"; log "xterm exit rc=$?"
    fi
else
    log "xterm missing"
fi
cat /root/xwayland-xterm-command.txt >> "$LOG" 2>&1 || true
cat /root/xwayland-xterm-client.log >> "$LOG" 2>&1 || true
tail -60 /tmp/weston.log >> "$LOG" 2>&1 || true
sync
