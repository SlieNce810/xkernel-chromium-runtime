#!/bin/sh

LOG=/root/strace-round.log
TRACE=/root/browser.strace
CHROME=/root/strace-chrome.log
: > "$LOG"
: > "$TRACE"
: > "$CHROME"
log() {
    echo "[strace] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}
ps_types() {
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
        case "$cmd" in
            *type=renderer*|*type=zygote*|*type=utility*|*type=gpu-process*) echo "$p $cmd";;
        esac
    done
}

log "start chromium=$(chromium --version 2>&1 | head -1)"
mkdir -p /run/udev/data /sys/dev/char/226:0/device /sys/devices/simpledrm /sys/bus/faux /sys/class/drm/card0 /run/user/0 /tmp/.X11-unix 2>/dev/null
cat > /run/udev/data/c13:1 <<'EOF'
E:ID_INPUT=1
E:ID_INPUT_KEYBOARD=1
E:ID_SEAT=seat0
EOF
ln -sf ../../faux /sys/dev/char/226:0/device/subsystem 2>/dev/null
printf 'MAJOR=226\nMINOR=0\nDEVNAME=dri/card0\nSUBSYSTEM=drm\nDEVTYPE=drm_minor\n' > /sys/class/drm/card0/uevent 2>/dev/null
printf '226:0\n' > /sys/class/drm/card0/dev 2>/dev/null
ln -sf ../../bus/faux /sys/class/drm/card0/subsystem 2>/dev/null
printf 'drm 1.1.0 simpledrm 1.0.0\n' > /sys/class/drm/version 2>/dev/null
chmod 700 /run/user/0 2>/dev/null; chmod 1777 /tmp/.X11-unix 2>/dev/null
pkill -x weston 2>/dev/null; pkill -x seatd 2>/dev/null; sleep 1
rm -f /run/seatd.sock /tmp/weston.log /run/user/0/wayland-*
seatd -g root -l debug >/tmp/seatd.log 2>&1 &
sleep 2
env LD_PRELOAD=/usr/local/lib/libseat-shim.so XDG_RUNTIME_DIR=/run/user/0 WESTON_DISABLE_ATOMIC=1 \
    weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
    --seat=seat0 --continue-without-input --idle-time=0 --socket=wayland-0 \
    --log=/tmp/weston.log >/dev/console 2>&1 &
i=0
while [ "$i" -lt 30 ]; do
    [ -S /run/user/0/wayland-0 ] && break
    i=$((i + 1)); sleep 1
done
export XDG_RUNTIME_DIR=/run/user/0
export WAYLAND_DISPLAY=wayland-0

log "weston=$(pgrep -x weston | tr '\n' ' ') socket=$WAYLAND_DISPLAY"
chromium --ozone-platform=wayland --no-sandbox --disable-dev-shm-usage \
    --use-gl=angle --use-angle=vulkan --disable-gpu-sandbox \
    --disable-crash-reporter \
    --disable-features=Vulkan,SegmentationPlatform,OptimizationGuideModelDownloading,OptimizationHints,WebAppProvider,InterestFeedContentSuggestions,AudioServiceOutOfProcess,AudioServiceSandbox \
    --disable-background-networking --disable-component-update --disable-sync --disable-extensions \
    --no-first-run --no-default-browser-check --mute-audio --disable-audio-output \
    --enable-logging=stderr --v=1 --user-data-dir=/tmp/chromium-strace \
    file:///usr/share/html-test/index.html >> "$CHROME" 2>&1 &
CP=$!
log "browser=$CP"
sleep 3
if command -v strace >/dev/null 2>&1 && kill -0 "$CP" 2>/dev/null; then
    strace -ff -tt -s 256 -o "$TRACE" -p "$CP" >/root/strace-attach.log 2>&1 &
    SP=$!
    log "strace=$SP attached"
else
    log "strace unavailable or browser already exited"
fi

t=0
while [ "$t" -lt 60 ]; do
    if [ ! -d "/proc/$CP" ]; then
        wait "$CP"; rc=$?; log "browser exited rc=$rc at ${t}s"; break
    fi
    echo "--- t=${t}s ---" >> "$LOG"
    ps_types >> "$LOG"
    t=$((t + 5)); sleep 5
done
[ -n "${SP:-}" ] && kill "$SP" 2>/dev/null || true
sleep 1
log "renderer_count=$(ps_types | grep -c 'type=renderer' 2>/dev/null)"
log "trace_tail"
tail -80 /root/browser.strace* >> "$LOG" 2>&1
tail -80 /root/browser.strace* > /dev/console 2>&1
log "chrome_tail"
tail -80 "$CHROME" >> "$LOG" 2>&1
tail -80 "$CHROME" > /dev/console 2>&1
sync; sync
