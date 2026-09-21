#!/bin/sh
# 基础任务 X11/Xwayland 兜底路线。
LOG=/root/x11-render.log
: > "$LOG"
log() { echo "[x11] $*" > /dev/console 2>/dev/null; echo "$(date 2>/dev/null) $*" >> "$LOG"; }

mkdir -p /run/udev/data /run/user/0 /tmp/.X11-unix \
    /sys/dev/char/226:0/device /sys/devices/simpledrm /sys/bus/faux /sys/class/drm/card0 2>/dev/null
printf 'E:ID_INPUT=1\nE:ID_INPUT_KEYBOARD=1\nE:ID_SEAT=seat0\n' > /run/udev/data/c13:1
ln -sf ../../faux /sys/dev/char/226:0/device/subsystem 2>/dev/null
printf 'MAJOR=226\nMINOR=0\nDEVNAME=dri/card0\nSUBSYSTEM=drm\nDEVTYPE=drm_minor\n' > /sys/class/drm/card0/uevent 2>/dev/null
printf '226:0\n' > /sys/class/drm/card0/dev 2>/dev/null
ln -sf ../../bus/faux /sys/class/drm/card0/subsystem 2>/dev/null
printf 'drm 1.1.0 simpledrm 1.0.0\n' > /sys/class/drm/version 2>/dev/null
chmod 700 /run/user/0; chmod 1777 /tmp/.X11-unix

pkill -x chromium 2>/dev/null; pkill -x weston 2>/dev/null; pkill -x seatd 2>/dev/null
rm -f /run/seatd.sock /run/user/0/wayland-* /tmp/.X11-unix/X* /tmp/weston.log
seatd -g root -l debug >/tmp/seatd.log 2>&1 &
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
    tail -40 /tmp/weston.log >> "$LOG" 2>&1
    exit 21
fi
DISPLAY=":${XSOCK##*X}"
export DISPLAY
log "Xwayland UP display=$DISPLAY socket=$XSOCK after ${i}s"

export XDG_RUNTIME_DIR=/run/user/0
mkdir -p /tmp/chromium-x11
OUT=/root/x11-chrome.log
: > "$OUT"
chromium --ozone-platform=x11 --display="$DISPLAY" --no-sandbox --disable-dev-shm-usage \
    --disable-gpu --in-process-gpu --use-gl=angle --use-angle=swiftshader \
    --disable-crash-reporter --disable-breakpad --disable-crashpad \
    --mute-audio --disable-audio-output \
    --disable-features=Vulkan,AudioServiceOutOfProcess,AudioServiceSandbox,SegmentationPlatform,OptimizationGuideModelDownloading,OptimizationHints,WebAppProvider,InterestFeedContentSuggestions \
    --enable-logging=stderr --v=1 --user-data-dir=/tmp/chromium-x11 \
    --no-first-run --no-default-browser-check --disable-component-update \
    --disable-background-networking --disable-sync --disable-extensions \
    file:///usr/share/html-test/index.html >> "$OUT" 2>&1 &
p=$!
log "chromium pid=$p"
t=0
while [ "$t" -lt 120 ] && [ -d "/proc/$p" ]; do
    if grep -q 'FileURLLoader::Start' "$OUT" 2>/dev/null; then
        log "navigation-start at ${t}s"
        sleep 45
        break
    fi
    t=$((t + 5)); sleep 5
done
if [ -d "/proc/$p" ]; then
    log "browser alive; renderer=[$(pgrep -f 'type=renderer' | tr '\n' ' ')]"
else
    wait "$p"; log "browser exited rc=$? after ${t}s"
fi
grep -nE 'FileURLLoader|ERROR|FATAL|GPU process|missing credentials|Assertion' "$OUT" | tail -60 >> "$LOG" 2>&1
sync
