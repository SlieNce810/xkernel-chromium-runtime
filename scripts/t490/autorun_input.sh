#!/bin/sh
# Validate real virtio-input -> evdev -> kernel sysfs -> eudev/libudev -> Weston.
# This scenario uses the official HTML trio and fails Weston closed if it cannot
# initialize its normal input seat.

set -u
LOG=/root/input.log
WLOG=/root/input-weston.log
RD=/run/user/0
PAGE="file:///usr/share/html-test/index.html"
: > "$LOG"

log() {
    echo "[input] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}

snapshot_profile() {
    want="$1"
    for d in /proc/[0-9]*; do
        [ -r "$d/cmdline" ] || continue
        cmd=$(tr '\000' ' ' < "$d/cmdline" 2>/dev/null)
        case "$cmd" in
            *"$want"*) log "PROC pid=${d##*/} cmd=$cmd" ;;
        esac
    done
}

log "===== A. clean official pages and no preload shim ====="
log "kernel: $(uname -srm)"
log "LD_PRELOAD=${LD_PRELOAD:-<unset>}"
log "pages: $(sha256sum /usr/share/html-test/index.html /usr/share/html-test/interaction.html /usr/share/html-test/layout.html 2>/dev/null | tr '\n' ';')"

if [ -s /pkgs.tar.gz ]; then
    log "extracting per-round official eudev package overlay"
    tar -xzf /pkgs.tar.gz -C / >> "$LOG" 2>&1
    log "package overlay extract rc=$?"
else
    log "[UDEV_OVERLAY] /pkgs.tar.gz missing"
fi

log "===== B. actual evdev nodes and sysfs ====="
ls -l /dev/input/ >> "$LOG" 2>&1
for p in /sys/class/input/event*/dev /sys/class/input/event*/uevent \
         /sys/class/input/event*/device/name /sys/class/input/event*/device/phys \
         /sys/class/input/event*/device/id/bustype \
         /sys/class/input/event*/device/capabilities/ev \
         /sys/class/input/event*/device/capabilities/key \
         /sys/class/input/event*/device/capabilities/rel; do
    [ -r "$p" ] || continue
    log "$p=$(tr '\n' ';' < "$p" 2>/dev/null)"
done

if [ -x /evprobe ]; then
    /evprobe > /root/input-evprobe.log 2>&1
    ev_rc=$?
    cat /root/input-evprobe.log >> "$LOG"
    log "[EVPROBE_EXIT] rc=$ev_rc"
else
    log "[EVPROBE_MISSING] /evprobe was not injected"
fi

log "===== C. standard eudev coldplug; no hand-written udev records ====="
mkdir -p /run/udev/data 2>/dev/null
if command -v udevd >/dev/null 2>&1; then
    udevd --daemon > /root/input-udevd.log 2>&1
    log "udevd_start_rc=$?"
elif [ -x /sbin/udevd ]; then
    /sbin/udevd --daemon > /root/input-udevd.log 2>&1
    log "udevd_start_rc=$?"
else
    log "[UDEVD_MISSING] no standard eudev daemon in the image"
fi
if command -v udevadm >/dev/null 2>&1; then
    udevadm trigger --action=add --subsystem-match=input > /root/input-udevadm-trigger.log 2>&1
    log "udevadm_trigger_rc=$?"
    udevadm settle --timeout=10 >> /root/input-udevadm-trigger.log 2>&1
    log "udevadm_settle_rc=$?"
    for n in event0 event1; do
        udevadm info --query=property --name="/dev/input/$n" > "/root/input-$n-udev.log" 2>&1
        log "udevadm_info_$n_rc=$?"
        grep -E '^(DEVNAME|DEVTYPE|ID_INPUT|ID_INPUT_KEYBOARD|ID_INPUT_MOUSE|ID_SEAT|ID_PATH)=' \
            "/root/input-$n-udev.log" >> "$LOG" 2>&1
    done
else
    log "[UDEVADM_MISSING] no udevadm coldplug tool in the image"
fi
for f in /run/udev/data/c13:64 /run/udev/data/c13:65; do
    [ -r "$f" ] && { log "$(basename "$f"): $(tr '\n' ';' < "$f")"; }
done

if [ -x /inputudevprobe ]; then
    /inputudevprobe > /root/input-udevprobe.log 2>&1
    udev_rc=$?
    cat /root/input-udevprobe.log >> "$LOG"
    log "[INPUT_UDEVPROBE_EXIT] rc=$udev_rc"
else
    log "[INPUT_UDEVPROBE_MISSING] /inputudevprobe was not injected"
fi

log "===== D. start seatd and standard Weston DRM backend ====="
chmod 700 "$RD" 2>/dev/null
rm -f /run/seatd.sock "$RD"/wayland-*
SEATD_VTBOUND=0 seatd -l info > /root/input-seatd.log 2>&1 &
SD=$!
sleep 1
env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 \
    LIBSEAT_BACKEND=seatd SEATD_SOCK=/run/seatd.sock LIBINPUT_LOG_LEVEL=debug \
    weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
    --seat=seat0 --idle-time=0 --debug --log="$WLOG" \
    > /root/input-weston-stdout.log 2>&1 &
W=$!
sleep 10
SOCKPATH=$(find "$RD" -maxdepth 1 -type s -name 'wayland-*' 2>/dev/null | head -1)
WDISPLAY=$(basename "$SOCKPATH")
log "weston_alive=$([ -d /proc/$W ] && echo yes || echo no) socket=[${SOCKPATH:-missing}]"
grep -aiE "using /dev/dri/card0|Output .* enabled|Failed to find primary|input|libinput|seat0|shadow framebuffer" "$WLOG" \
    | tail -100 >> "$LOG" 2>&1

if [ -n "$SOCKPATH" ] && command -v chromium >/dev/null 2>&1; then
    PROFILE=/root/input-chromium-profile
    rm -rf "$PROFILE" 2>/dev/null
    log "===== E. Chromium normal renderer mode on the real input-enabled seat ====="
    env XDG_RUNTIME_DIR="$RD" WAYLAND_DISPLAY="$WDISPLAY" \
        chromium --ozone-platform=wayland --in-process-gpu --disable-gpu-sandbox \
        --no-sandbox --disable-dev-shm-usage --disable-crash-reporter --disable-breakpad \
        --no-first-run --no-default-browser-check --disable-sync \
        --window-size=1280,800 --start-fullscreen --kiosk \
        --disable-features=SegmentationPlatform,OptimizationGuideModelDownloading,OptimizationHints,WebAppProvider,InterestFeedContentSuggestions \
        --enable-logging=stderr --v=1 \
        --vmodule='*wayland*=2,*ozone*=2,*navigation*=2,*render_process*=2' \
        --user-data-dir="$PROFILE" "$PAGE" > /root/input-chromium.log 2>&1 &
    C=$!
    log "chromium pid=$C"
    (
        elapsed=0
        while [ "$elapsed" -lt 180 ] && [ -d "/proc/$C" ]; do
            if [ $((elapsed % 15)) -eq 0 ]; then
                log "chromium_alive elapsed=${elapsed}s"
                snapshot_profile "$PROFILE"
            fi
            sleep 5
            elapsed=$((elapsed + 5))
        done
        if [ -d "/proc/$C" ]; then
            log "chromium watchdog timeout=180s; sending SIGTERM"
            kill -TERM "$C" 2>/dev/null
            sleep 10
            kill -KILL "$C" 2>/dev/null
        fi
    ) &
    WATCH=$!
    wait "$C"
    rc=$?
    kill "$WATCH" 2>/dev/null
    wait "$WATCH" 2>/dev/null
    log "[INPUT_CHROMIUM_EXIT] wait_rc=$rc"
    grep -aE "FileURLLoader|NavigationRequest|renderer|Failed to initialize cpuinfo|missing credentials|wl_seat|wayland_surface|FATAL|ERROR|inotify" \
        /root/input-chromium.log | tail -100 >> "$LOG" 2>&1
    snapshot_profile "$PROFILE"
else
    log "[INPUT_CHROMIUM_SKIP] no Weston socket or Chromium binary"
fi

sleep 15
kill "$W" 2>/dev/null
kill "$SD" 2>/dev/null
log "[INPUT_SUM] weston_alive=$([ -d /proc/$W ] && echo yes || echo no) socket=${SOCKPATH:-missing}"
sync
