#!/bin/sh
# 单进程 Chromium 初赛主流程。
#
# 目的：在暂不处理多进程/多线程 renderer 的阶段，验证 Weston + Wayland +
# Chromium --single-process 的首页首帧、10 分钟稳定性和可复现测量格式。
# 该脚本只做单进程功能门禁和测量，不把结果写成多进程兼容性结论。

set -u

LOG=/root/single-initial.log
METRICS=/root/single-initial.csv
CHROME_LOG=/root/single-chromium.log
WLOG=/root/single-weston.log
SEATD_LOG=/root/single-seatd.log
UDEVD_LOG=/root/single-udevd.log
RUNTIME_DIR=/run/user/0
PAGE_URL="file:///usr/share/html-test/index.html"
HOLD_SECONDS=${SINGLE_HOLD_SECONDS:-__SINGLE_HOLD_SECONDS__}
SAMPLE_SECONDS=${SINGLE_SAMPLE_SECONDS:-__SINGLE_SAMPLE_SECONDS__}

: > "$LOG"
: > "$METRICS"
: > "$CHROME_LOG"
printf 'elapsed_sec,epoch_sec,browser_pid,browser_alive,weston_alive,rss_kb,navigation_started\n' > "$METRICS"

log() {
    echo "[single] $*" >> "$LOG"
    echo "[single] $*" > /dev/console 2>/dev/null || true
}

epoch_sec() { date +%s 2>/dev/null || echo 0; }

cleanup() {
    if [ -n "${CHROME_PID:-}" ] && [ -d "/proc/$CHROME_PID" ]; then
        kill -TERM "$CHROME_PID" 2>/dev/null || true
        sleep 2
        kill -KILL "$CHROME_PID" 2>/dev/null || true
    fi
    if [ -n "${WESTON_PID:-}" ] && [ -d "/proc/$WESTON_PID" ]; then
        kill -TERM "$WESTON_PID" 2>/dev/null || true
    fi
    if [ -n "${SEATD_PID:-}" ] && [ -d "/proc/$SEATD_PID" ]; then
        kill -TERM "$SEATD_PID" 2>/dev/null || true
    fi
    if [ -n "${UDEVD_PID:-}" ] && [ -d "/proc/$UDEVD_PID" ]; then
        kill -TERM "$UDEVD_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

log "PAGE_URL=$PAGE_URL"
log "HOLD_SECONDS=$HOLD_SECONDS SAMPLE_SECONDS=$SAMPLE_SECONDS"
log "kernel=$(uname -srm 2>/dev/null || true)"
log "chromium=$(chromium --version 2>&1 | head -1)"
log "LD_PRELOAD=${LD_PRELOAD:-<unset>}"

mkdir -p /run/udev/data "$RUNTIME_DIR" /tmp/.X11-unix 2>/dev/null || true
chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
rm -f /run/seatd.sock "$RUNTIME_DIR"/wayland-* 2>/dev/null || true

if [ -s /pkgs.tar.gz ]; then
    tar -xzf /pkgs.tar.gz -C / >> "$LOG" 2>&1 || log "PKG_OVERLAY_RC=$?"
fi

if command -v udevd >/dev/null 2>&1; then
    udevd --debug > "$UDEVD_LOG" 2>&1 &
    UDEVD_PID=$!
    sleep 1
    udevadm trigger --action=add --subsystem-match=input >/root/single-udev-trigger.log 2>&1 &
    UDEV_TRIGGER_PID=$!
    sleep 2
    kill -TERM "$UDEV_TRIGGER_PID" 2>/dev/null || true
    udevadm settle --timeout=8 >/root/single-udev-settle.log 2>&1 || true
fi

# Minimal sysfs contract used by the existing agentos Weston setup.
mkdir -p /sys/dev/char/226:0/device /sys/class/drm/card0 \
    /sys/devices/simpledrm /sys/bus/faux /sys/class/faux 2>/dev/null || true
ln -sf ../../faux /sys/dev/char/226:0/device/subsystem 2>/dev/null || true
printf 'MAJOR=226\nMINOR=0\nDEVNAME=dri/card0\nSUBSYSTEM=drm\nDEVTYPE=drm_minor\n' \
    > /sys/class/drm/card0/uevent 2>/dev/null || true
printf '226:0\n' > /sys/class/drm/card0/dev 2>/dev/null || true
ln -sf ../../bus/faux /sys/class/drm/card0/subsystem 2>/dev/null || true
printf 'drm 1.1.0 simpledrm 1.0.0\n' > /sys/class/drm/version 2>/dev/null || true

SEATD_VTBOUND=0 seatd -l info > "$SEATD_LOG" 2>&1 &
SEATD_PID=$!
sleep 1

env XDG_RUNTIME_DIR="$RUNTIME_DIR" WESTON_DISABLE_ATOMIC=1 \
    LIBSEAT_BACKEND=seatd SEATD_SOCK=/run/seatd.sock \
    weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
    --seat=seat0 --idle-time=0 --debug --log="$WLOG" \
    >/root/single-weston-stdout.log 2>&1 &
WESTON_PID=$!

i=0
SOCKET=""
while [ "$i" -lt 45 ]; do
    SOCKET=$(find "$RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' 2>/dev/null | head -1)
    [ -n "$SOCKET" ] && break
    i=$((i + 1))
    sleep 1
done
if [ -z "$SOCKET" ]; then
    log "WESTON_SOCKET_MISSING after ${i}s"
    tail -n 100 "$WLOG" >> "$LOG" 2>&1 || true
    exit 31
fi

export XDG_RUNTIME_DIR
export WAYLAND_DISPLAY=${SOCKET##*/}
log "WESTON_SOCKET=$WAYLAND_DISPLAY"

rm -rf /root/single-initial-profile 2>/dev/null || true
export VK_ICD_FILENAMES=${VK_ICD_FILENAMES:-/usr/lib/chromium/vk_swiftshader_icd.json}
CHROME_ARGS="--ozone-platform=wayland --use-gl=angle --use-angle=swiftshader --in-process-gpu --no-zygote --single-process --no-sandbox --disable-dev-shm-usage --disable-crash-reporter --disable-breakpad --no-first-run --no-default-browser-check --disable-sync --disable-component-update --disable-background-networking --disable-extensions --window-size=1280,800 --start-fullscreen --kiosk --remote-debugging-port=9222 --remote-allow-origins=* --disable-features=Vulkan,SegmentationPlatform,OptimizationGuideModelDownloading,OptimizationHints,WebAppProvider,InterestFeedContentSuggestions,AudioServiceOutOfProcess,AudioServiceSandbox --enable-logging=stderr --v=1 --vmodule=*wayland*=2,*ozone*=2,*navigation*=2,*render_process*=2,*content*=2,*viz*=2 --user-data-dir=/root/single-initial-profile"
log "CHROME_ARGS=$CHROME_ARGS"
log "SINGLE_MODE=single-process,no-zygote,in-process-gpu"

START_EPOCH=$(epoch_sec)
env XDG_RUNTIME_DIR="$RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
    /usr/lib/chromium/chromium $CHROME_ARGS "$PAGE_URL" > "$CHROME_LOG" 2>&1 &
CHROME_PID=$!
log "BROWSER_PID=$CHROME_PID BROWSER_START_EPOCH=$START_EPOCH"

elapsed=0
navigation_started=0
first_nav_epoch=0
while [ "$elapsed" -le "$HOLD_SECONDS" ] && [ -d "/proc/$CHROME_PID" ]; do
    if [ "$navigation_started" -eq 0 ] && grep -q 'FileURLLoader::Start' "$CHROME_LOG" 2>/dev/null; then
        navigation_started=1
        first_nav_epoch=$(epoch_sec)
        log "FIRST_NAV_EPOCH=$first_nav_epoch FIRST_NAV_ELAPSED=$elapsed"
    fi

    browser_alive=0
    [ -d "/proc/$CHROME_PID" ] && browser_alive=1
    weston_alive=0
    [ -d "/proc/$WESTON_PID" ] && weston_alive=1
    rss_kb=$(awk '/^VmRSS:/ {print $2; found=1} END {if (!found) print 0}' "/proc/$CHROME_PID/status" 2>/dev/null || echo 0)
    now=$(epoch_sec)
    printf '%s,%s,%s,%s,%s,%s,%s\n' "$elapsed" "$now" "$CHROME_PID" \
        "$browser_alive" "$weston_alive" "$rss_kb" "$navigation_started" >> "$METRICS"

    if [ $((elapsed % 60)) -eq 0 ]; then
        log "SAMPLE elapsed=$elapsed browser_alive=$browser_alive weston_alive=$weston_alive rss_kb=$rss_kb navigation=$navigation_started"
    fi
    sleep "$SAMPLE_SECONDS"
    elapsed=$((elapsed + SAMPLE_SECONDS))
done

if [ -d "/proc/$CHROME_PID" ]; then
    log "SINGLE_HOLD_REACHED elapsed=$elapsed"
else
    wait "$CHROME_PID" 2>/dev/null || true
    log "BROWSER_EXITED before hold elapsed=$elapsed"
fi

if [ "$navigation_started" -eq 1 ] && [ "$elapsed" -gt "$HOLD_SECONDS" ] && \
   [ -d "/proc/$CHROME_PID" ]; then
    log "SINGLE_GATE=1"
else
    log "SINGLE_GATE=0"
fi

log "METRICS_BEGIN"
cat "$METRICS" >> "$LOG"
log "METRICS_END"
log "CHROME_LOG_TAIL_BEGIN"
tail -n 160 "$CHROME_LOG" >> "$LOG" 2>&1 || true
log "CHROME_LOG_TAIL_END"
sync

# Keep the process alive only until cleanup runs; the host round owns the final
# screendump and guest log recovery.
exit 0
