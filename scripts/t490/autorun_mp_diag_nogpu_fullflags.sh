#!/bin/sh
# Chromium default multi-process diagnostic round.
#
# This entry point deliberately omits --single-process and --no-zygote.  It is
# intended to answer the renderer gate before any performance sample is taken.
# The script writes machine-readable MP_* markers to /root/mp-diag.log so the
# host-side collector can reject a run that never created a renderer.

set -u

LOG=/root/mp-diag.log
WLOG=/root/mp-weston.log
CHROME_LOG=/root/mp-chromium.log
RUNTIME_DIR=/run/user/0
PAGE_URL=${PAGE_URL:-file:///usr/share/html-test/index.html}
# This value is injected by t490_round.sh; host environment variables do not
# cross the QEMU boundary by themselves.
TRACE_MODE=__MP_TRACE__
GL_MODE=__MP_GL__
NET_MODE=__MP_NET__
CHROME_PROFILE=/root/mp-chromium-profile
MAX_SECONDS=${MP_MAX_SECONDS:-30}
SAMPLE_SECONDS=${MP_SAMPLE_SECONDS:-5}
HOLD_SECONDS=${MP_HOLD_SECONDS:-5}

: > "$LOG"
: > "$CHROME_LOG"

log() {
    line="[mpdiag] $*"
    echo "$line" >> "$LOG"
    echo "$line" > /dev/console 2>/dev/null || true
}

epoch_ms() {
    value=$(date +%s%3N 2>/dev/null || true)
    case "$value" in
        ''|*[!0-9]*)
            seconds=$(date +%s 2>/dev/null || echo 0)
            echo "$((seconds * 1000))"
            ;;
        *) echo "$value" ;;
    esac
}

mono_ms() {
    awk 'NR == 1 { printf "%.0f\\n", $1 * 1000 }' /proc/uptime 2>/dev/null || echo 0
}

mark() {
    key="$1"
    value="$2"
    echo "MP_${key}=${value}" >> "$LOG"
    echo "[mpdiag] MP_${key}=${value}" > /dev/console 2>/dev/null || true
}

snapshot_processes() {
    label="$1"
    echo "MP_SNAPSHOT=${label}" >> "$LOG"
    echo "[mpdiag] MP_SNAPSHOT=${label}" > /dev/console 2>/dev/null || true
    echo "MP_PS_BEGIN=${label}" >> "$LOG"
    ps w 2>/dev/null \
        | grep -E 'chromium|chrome|type=(renderer|zygote|utility|gpu-process)' \
        | while IFS= read -r line; do
            echo "MP_PS $line" >> "$LOG"
            echo "[mpdiag] PS $line" > /dev/console 2>/dev/null || true
        done
    echo "MP_PS_END=${label}" >> "$LOG"
}

chromium_rss_kb() {
    ps -o pid=,rss=,args= 2>/dev/null \
        | awk '$0 ~ /chromium|chrome/ { total += $2 } END { print total + 0 }'
}

wait_for_wayland() {
    i=0
    while [ "$i" -lt 40 ]; do
        socket=$(find "$RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' 2>/dev/null | head -1)
        if [ -n "$socket" ]; then
            WAYLAND_DISPLAY=${socket##*/}
            export WAYLAND_DISPLAY
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    return 1
}

cleanup() {
    if [ -n "${CHROME_PID:-}" ] && [ -d "/proc/$CHROME_PID" ]; then
        kill -TERM "$CHROME_PID" 2>/dev/null || true
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

mark AUTORUN_START_EPOCH_MS "$(epoch_ms)"
mark AUTORUN_START_MONO_MS "$(mono_ms)"
log "PAGE_URL=$PAGE_URL"
log "TRACE_MODE=$TRACE_MODE"
log "GL_MODE=$GL_MODE"
log "NET_MODE=$NET_MODE"
log "kernel=$(uname -srm 2>/dev/null || true)"
log "LD_PRELOAD=${LD_PRELOAD:-<unset>}"
log "STRACE_PATH=$(command -v strace 2>/dev/null || echo missing)"

mkdir -p /run/udev/data "$RUNTIME_DIR" /tmp/.X11-unix 2>/dev/null || true
chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
rm -f /run/seatd.sock "$RUNTIME_DIR"/wayland-* 2>/dev/null || true

# The package overlay is immutable evidence input.  Extraction is allowed only
# when the caller supplied the tarball; no apk solver is run in this round.
if [ -s /pkgs.tar.gz ]; then
    tar -xzf /pkgs.tar.gz -C / >> "$LOG" 2>&1 || log "PKG_OVERLAY_RC=$?"
fi
if [ -x /usr/bin/strace ]; then
    log "STRACE_FILE=/usr/bin/strace"
    ls -l /usr/bin/strace /usr/bin/strace-log-merge > /dev/console 2>&1 || true
else
    log "STRACE_FILE=missing"
fi

if command -v udevd >/dev/null 2>&1; then
    udevd --debug > /root/mp-udevd.log 2>&1 &
    UDEVD_PID=$!
    sleep 1
    udevadm trigger --action=add --subsystem-match=input >/root/mp-udev-trigger.log 2>&1 || true
    udevadm settle --timeout=8 >/root/mp-udev-settle.log 2>&1 || true
fi

# Keep the minimal runtime sysfs contract used by the existing Weston package.
# The kernel-side sysfs implementation remains a separate hardening task.
mkdir -p /sys/dev/char/226:0/device /sys/class/drm/card0 /sys/devices/simpledrm /sys/bus/faux /sys/class/faux 2>/dev/null || true
ln -sf ../../faux /sys/dev/char/226:0/device/subsystem 2>/dev/null || true
printf 'MAJOR=226\nMINOR=0\nDEVNAME=dri/card0\nSUBSYSTEM=drm\nDEVTYPE=drm_minor\n' > /sys/class/drm/card0/uevent 2>/dev/null || true
printf '226:0\n' > /sys/class/drm/card0/dev 2>/dev/null || true
ln -sf ../../bus/faux /sys/class/drm/card0/subsystem 2>/dev/null || true
printf 'drm 1.1.0 simpledrm 1.0.0\n' > /sys/class/drm/version 2>/dev/null || true

if command -v seatd >/dev/null 2>&1; then
    SEATD_VTBOUND=0 seatd -l info >/root/mp-seatd.log 2>&1 &
    SEATD_PID=$!
    sleep 1
fi

env XDG_RUNTIME_DIR="$RUNTIME_DIR" WESTON_DISABLE_ATOMIC=1 \
    LIBSEAT_BACKEND=seatd SEATD_SOCK=/run/seatd.sock \
    weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
    --seat=seat0 --idle-time=0 --debug --log="$WLOG" \
    >/root/mp-weston-stdout.log 2>&1 &
WESTON_PID=$!
if ! wait_for_wayland; then
    mark GATE 0
    log "WAYLAND_SOCKET_MISSING=1"
    weston_alive=no
    seatd_alive=no
    udevd_alive=no
    [ -n "${WESTON_PID:-}" ] && [ -d "/proc/$WESTON_PID" ] && weston_alive=yes
    [ -n "${SEATD_PID:-}" ] && [ -d "/proc/$SEATD_PID" ] && seatd_alive=yes
    [ -n "${UDEVD_PID:-}" ] && [ -d "/proc/$UDEVD_PID" ] && udevd_alive=yes
    log "WESTON_PID=${WESTON_PID:-unset} alive=$weston_alive"
    log "SEATD_PID=${SEATD_PID:-unset} alive=$seatd_alive"
    log "UDEVD_PID=${UDEVD_PID:-unset} alive=$udevd_alive"
    log "INPUT_DEV_NODES_BEGIN"
    ls -la /dev/input /sys/class/input >> "$LOG" 2>&1 || true
    find /sys/class/input -maxdepth 2 \( -type f -o -type l \) >> "$LOG" 2>&1 || true
    log "INPUT_DEV_NODES_END"
    for failure_log in "$WLOG" /root/mp-weston-stdout.log /root/mp-seatd.log /root/mp-udevd.log /root/mp-udev-trigger.log /root/mp-udev-settle.log; do
        [ -f "$failure_log" ] || continue
        log "FAILURE_LOG=$failure_log"
        tail -n 120 "$failure_log" >> "$LOG" 2>&1 || true
        echo "[mpdiag] FAILURE_LOG=$failure_log" > /dev/console 2>/dev/null || true
        tail -n 80 "$failure_log" > /dev/console 2>&1 || true
    done
    exit 31
fi
mark WESTON_SOCKET "$WAYLAND_DISPLAY"
log "weston_pid=$WESTON_PID alive=$([ -d "/proc/$WESTON_PID" ] && echo yes || echo no)"
ls -l /dev/input /sys/class/input 2>/dev/null >> "$LOG" || true

rm -rf "$CHROME_PROFILE" 2>/dev/null || true
XDG_RUNTIME_DIR="$RUNTIME_DIR"
export XDG_RUNTIME_DIR WAYLAND_DISPLAY
export VK_ICD_FILENAMES=${VK_ICD_FILENAMES:-/usr/lib/chromium/vk_swiftshader_icd.json}

# This command is intentionally multi-process.  Keep the string in the log so
# a collector can fail a run that accidentally regresses to diagnostic mode.
case "$GL_MODE" in
    legacy)
        GL_ARGS="--disable-gpu --disable-gpu-compositing --disable-threaded-compositing --disable-gpu-rasterization"
        GL_FEATURES="Vulkan,SegmentationPlatform,OptimizationGuideModelDownloading,OptimizationHints,WebAppProvider,InterestFeedContentSuggestions"
        ;;
    angle)
        GL_ARGS="--use-gl=angle --use-angle=swiftshader"
        GL_FEATURES="SegmentationPlatform,OptimizationGuideModelDownloading,OptimizationHints,WebAppProvider,InterestFeedContentSuggestions"
        ;;
    *)
        log "INVALID_GL_MODE=$GL_MODE"
        exit 33
        ;;
esac
case "$NET_MODE" in
    normal) NET_FEATURES="$GL_FEATURES" ;;
    disable) NET_FEATURES="$GL_FEATURES,NetworkService" ;;
    *) log "INVALID_NET_MODE=$NET_MODE"; exit 34 ;;
esac
CHROME_ARGS="--ozone-platform=wayland $GL_ARGS --no-sandbox --disable-dev-shm-usage --disable-crash-reporter --disable-breakpad --no-first-run --no-default-browser-check --disable-sync --disable-component-update --disable-background-networking --window-size=1280,800 --start-fullscreen --kiosk --disable-features=$NET_FEATURES --enable-logging=stderr --v=1 --vmodule=*wayland*=2,*ozone*=2,*navigation*=2,*render_process*=2,*content*=2,*viz*=2,*renderer*=2,*child_process*=2,*site_instance*=2,*render_frame_host*=2,*zygote*=2,*mojo*=2 --user-data-dir=$CHROME_PROFILE"
case "$CHROME_ARGS" in
    *--single-process*|*--no-zygote*)
        mark GATE 0
        log "MULTIPROCESS_ARGUMENT_GUARD=FAIL"
        exit 32
        ;;
esac
log "CHROME_ARGS=$CHROME_ARGS"
mark BROWSER_START_EPOCH_MS "$(epoch_ms)"
mark BROWSER_START_MONO_MS "$(mono_ms)"

if [ "$TRACE_MODE" = "1" ] && command -v strace >/dev/null 2>&1; then
    # The Alpine strace overlay used by the guest does not recognize the
    # newer %sched trace group.  A short diagnostic run is safer with the
    # portable all-syscall form; this output is never used as a performance
    # sample.
    strace -ff -ttt -T -yy -s 256 -o /root/mp-trace \
        /usr/lib/chromium/chromium $CHROME_ARGS "$PAGE_URL" >> "$CHROME_LOG" 2>&1 &
else
    [ "$TRACE_MODE" = "1" ] && log "STRACE_SKIPPED=unavailable"
    /usr/lib/chromium/chromium $CHROME_ARGS "$PAGE_URL" >> "$CHROME_LOG" 2>&1 &
fi
CHROME_PID=$!
log "browser_pid=$CHROME_PID"

renderer_streak=0
renderer_max_streak=0
renderer_seen=0
max_rss=0
elapsed=0
while [ "$elapsed" -lt "$MAX_SECONDS" ] && [ -d "/proc/$CHROME_PID" ]; do
    renderer_count=0
    for proc in /proc/[0-9]*; do
        [ -r "$proc/cmdline" ] || continue
        cmd=$(tr '\000' ' ' < "$proc/cmdline" 2>/dev/null || true)
        case "$cmd" in *type=renderer*) renderer_count=$((renderer_count + 1));; esac
    done
    case "$renderer_count" in ''|*[!0-9]*) renderer_count=0 ;; esac
    rss=$(chromium_rss_kb)
    [ "$rss" -gt "$max_rss" ] 2>/dev/null && max_rss=$rss
    mark SAMPLE_ELAPSED_SEC "$elapsed"
    mark RENDERER_COUNT "$renderer_count"
    mark RSS_KB "$rss"
    snapshot_processes "${elapsed}s"
    if [ "$renderer_count" -gt 0 ]; then
        renderer_seen=1
        renderer_streak=$((renderer_streak + 1))
        [ "$renderer_streak" -gt "$renderer_max_streak" ] && renderer_max_streak=$renderer_streak
        if [ "$renderer_streak" -eq 1 ]; then
            mark RENDERER_FIRST_EPOCH_MS "$(epoch_ms)"
            mark RENDERER_FIRST_MONO_MS "$(mono_ms)"
        fi
    else
        renderer_streak=0
    fi
    elapsed=$((elapsed + SAMPLE_SECONDS))
    sleep "$SAMPLE_SECONDS"
done

if [ -d "/proc/$CHROME_PID" ]; then
    kill -TERM "$CHROME_PID" 2>/dev/null || true
fi
grace=0
while [ "$grace" -lt 5 ] && [ -d "/proc/$CHROME_PID" ]; do
    sleep 1
    grace=$((grace + 1))
done
if [ -d "/proc/$CHROME_PID" ]; then
    log "BROWSER_TERM_TIMEOUT=1"
    kill -KILL "$CHROME_PID" 2>/dev/null || true
fi
wait "$CHROME_PID" 2>/dev/null
chrome_rc=$?
mark BROWSER_EXIT_EPOCH_MS "$(epoch_ms)"
mark BROWSER_EXIT_RC "$chrome_rc"
mark RSS_MAX_KB "$max_rss"
mark RENDERER_SEEN "$renderer_seen"
mark RENDERER_MAX_STREAK "$renderer_max_streak"
if [ "$renderer_max_streak" -ge 12 ]; then
    mark GATE 1
else
    mark GATE 0
fi
log "CHROMIUM_LOG_BYTES=$(wc -c < "$CHROME_LOG" 2>/dev/null || echo 0)"
cat "$CHROME_LOG" >> "$LOG" 2>&1 || true
cat "$CHROME_LOG" > /dev/console 2>&1 || true
if [ "$TRACE_MODE" = "1" ]; then
    for trace_file in /root/mp-trace.*; do
        [ -f "$trace_file" ] || continue
        echo "[mpdiag] TRACE_FILE=$trace_file" > /dev/console 2>/dev/null || true
        tail -n 80 "$trace_file" > /dev/console 2>&1 || true
    done
fi

# Keep the compositor alive long enough for a caller to take a stability shot.
hold=0
while [ "$hold" -lt "$HOLD_SECONDS" ] && [ -d "/proc/$WESTON_PID" ]; do
    sleep 5
    hold=$((hold + 5))
done
sync

