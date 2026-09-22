#!/bin/sh
# autorun_n1b.sh — Chromium 191/zygote 追踪轮

LOG=/root/n1b.log
CL=/root/n1b-chrome.log
: > "$LOG"
: > "$CL"
log() {
    echo "[n1b] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}
psnode() { pgrep -f "type=$1" | tr '\n' ' '; }

log "start uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null) chromium=$(chromium --version 2>&1 | head -1)"
mkdir -p /run/udev/data /sys/dev/char/226:0/device /sys/devices/simpledrm /sys/bus/faux 2>/dev/null
cat > /run/udev/data/c13:1 <<'EOF'
E:ID_INPUT=1
E:ID_INPUT_KEYBOARD=1
E:ID_SEAT=seat0
EOF
ln -sf ../../faux /sys/dev/char/226:0/device/subsystem 2>/dev/null
mkdir -p /sys/class/drm/card0 /run/user/0 /tmp/.X11-unix 2>/dev/null
printf 'MAJOR=226\nMINOR=0\nDEVNAME=dri/card0\nSUBSYSTEM=drm\nDEVTYPE=drm_minor\n' > /sys/class/drm/card0/uevent 2>/dev/null
printf '226:0\n' > /sys/class/drm/card0/dev 2>/dev/null
ln -sf ../../bus/faux /sys/class/drm/card0/subsystem 2>/dev/null
printf 'drm 1.1.0 simpledrm 1.0.0\n' > /sys/class/drm/version 2>/dev/null
chmod 700 /run/user/0 2>/dev/null
chmod 1777 /tmp/.X11-unix 2>/dev/null
pkill -x weston 2>/dev/null; pkill -x seatd 2>/dev/null; sleep 1
rm -f /run/seatd.sock /tmp/weston.log /run/user/0/wayland-*
seatd -g root -l debug >/tmp/seatd.log 2>&1 &
sleep 2
if [ -f /usr/local/lib/libseat-shim.so ]; then
    env LD_PRELOAD=/usr/local/lib/libseat-shim.so XDG_RUNTIME_DIR=/run/user/0 WESTON_DISABLE_ATOMIC=1 \
        weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
        --seat=seat0 --continue-without-input --idle-time=0 --socket=wayland-0 \
        --log=/tmp/weston.log >/dev/console 2>&1 &
    i=0
    while [ "$i" -lt 30 ]; do
        [ -n "$(ls /run/user/0 2>/dev/null | grep -E '^wayland-[0-9]+$')" ] && break
        i=$((i + 1)); sleep 1
    done
    WL_SOCK=$(ls /run/user/0 2>/dev/null | grep -E '^wayland-[0-9]+$' | head -n1)
    log "weston pid=$(pgrep -x weston | tr '\n' ' ') socket=${WL_SOCK:-NONE} wait=${i}s"
fi
export XDG_RUNTIME_DIR=/run/user/0
export WAYLAND_DISPLAY="${WL_SOCK:-wayland-0}"
mkdir -p /tmp/chromium-n1b

log "launch detailed Chromium"
chromium --ozone-platform=wayland --no-sandbox --disable-dev-shm-usage \
    --enable-logging=stderr --v=1 \
    --vmodule='*content*=2,*mojo*=2,*zygote*=2,*sandbox*=2,*crashpad*=2' \
    --user-data-dir=/tmp/chromium-n1b --in-process-gpu --use-gl=swiftshader \
    --disable-gpu-sandbox \
    --disable-features=Vulkan,SegmentationPlatform,OptimizationGuideModelDownloading,OptimizationHints,WebAppProvider,InterestFeedContentSuggestions \
    --no-first-run --no-default-browser-check --disable-component-update \
    --disable-background-networking --disable-sync --disable-extensions \
    --disable-crash-reporter \
    file:///usr/share/html-test/index.html >> "$CL" 2>&1 &
CP=$!
log "browser pid=$CP"
k=0
while [ "$k" -lt 120 ]; do
    [ -d "/proc/$CP" ] || break
    {
        echo "--- +${k}s browser=[$CP] zygote=[$(psnode zygote)] gpu=[$(psnode gpu)] utility=[$(psnode utility)] renderer=[$(psnode renderer)]"
    } >> "$LOG"
    k=$((k + 5)); sleep 5
done
if [ -d "/proc/$CP" ]; then
    log "still running at ${k}s"
else
    wait "$CP"; rc=$?
    log "browser exited rc=$rc after ${k}s"
fi
for pat in 'missing credentials' 'RenderProcessHost' 'type=renderer' 'zygote' 'GPU process' 'FATAL' 'ERROR' 'CHECK' 'sandbox' 'Mojo'; do
    log "COUNT [$pat] = $(grep -ic "$pat" "$CL" 2>/dev/null)"
done
log "key lines"
grep -nEi 'FileURLLoader|Navigation|DidStart|Commit|RenderProcessHost|zygote|GPU process|FATAL|ERROR|CHECK|sandbox|Mojo|exit' "$CL" | tail -80 >> "$LOG"
sync; sync
log "autorun_n1b done"
