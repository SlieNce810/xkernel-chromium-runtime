#!/bin/sh
# Bounded retry of the input-seat round. udevadm info hung in input-seat, so all
# udev operations below have a watchdog and libudev is queried before Weston.

set -u
LOG=/root/input16.log
WLOG=/root/input16-weston.log
RD=/run/user/0
PAGE="file:///usr/share/html-test/index.html"
: > "$LOG"

log() {
    echo "[input16] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}

run_guard() {
    out="$1"
    limit="$2"
    shift 2
    "$@" > "$out" 2>&1 &
    p=$!
    elapsed=0
    while [ "$elapsed" -lt "$limit" ] && [ -d "/proc/$p" ]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done
    if [ -d "/proc/$p" ]; then
        kill -TERM "$p" 2>/dev/null
        sleep 1
        kill -KILL "$p" 2>/dev/null
        wait "$p" 2>/dev/null
        return 124
    fi
    wait "$p"
    return $?
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

log "===== A. official page set and unshimmed environment ====="
log "kernel: $(uname -srm)"
log "LD_PRELOAD=${LD_PRELOAD:-<unset>}"
log "pages: $(sha256sum /usr/share/html-test/index.html /usr/share/html-test/interaction.html /usr/share/html-test/layout.html 2>/dev/null | tr '\n' ';')"
if [ -s /pkgs.tar.gz ]; then
    tar -xzf /pkgs.tar.gz -C / >> "$LOG" 2>&1
    log "eudev overlay extraction complete"
fi

log "===== B. pathname AF_UNIX SOCK_SEQPACKET control probe ====="
if [ -x /seqpacketprobe ]; then
    /seqpacketprobe > /root/input16-seqpacket.log 2>&1
    seq_rc=$?
    cat /root/input16-seqpacket.log >> "$LOG"
    log "[SEQPACKETPROBE_EXIT] rc=$seq_rc"
else
    log "[SEQPACKETPROBE_MISSING] /seqpacketprobe was not injected"
fi

log "===== C. standard eudev service and coldplug ====="
mkdir -p /run/udev/data /run/user/0 2>/dev/null
chmod 700 /run/user/0 2>/dev/null
udevd --debug > /root/input16-udevd.log 2>&1 &
UDEV=$!
sleep 1
log "udevd_foreground_pid=$UDEV alive=$([ -d /proc/$UDEV ] && echo yes || echo no)"
tail -n 50 /root/input16-udevd.log >> "$LOG" 2>&1
log "udevd_start_pid=$UDEV"
sleep 1
log "===== probe kernel KOBJECT_UEVENT delivery to NETLINK group 1 ====="
run_guard /root/input16-ueventprobe.log 25 /ueventprobe2
uevent_rc=$?
cat /root/input16-ueventprobe.log >> "$LOG" 2>&1
cat /root/input16-ueventprobe.log > /dev/console 2>&1
log "[UEVENTPROBE_EXIT] rc=$uevent_rc"
run_guard /root/input16-trigger.log 15 udevadm trigger --action=add --subsystem-match=input
trigger_rc=$?
log "udevadm_trigger_rc=$trigger_rc"
cat /root/input16-trigger.log >> "$LOG" 2>&1
cat /root/input16-trigger.log > /dev/console 2>&1
run_guard /root/input16-settle.log 15 udevadm settle --timeout=8
settle_rc=$?
log "udevadm_settle_rc=$settle_rc"
cat /root/input16-settle.log >> "$LOG" 2>&1
cat /root/input16-settle.log > /dev/console 2>&1
log "udevd processes:"
ps w | grep "[u]devd" | tee -a "$LOG" /dev/console
log "udevd debug tail:"
tail -n 100 /root/input16-udevd.log | tee -a "$LOG" /dev/console

for f in /run/udev/data/c13:64 /run/udev/data/c13:65; do
    if [ -r "$f" ]; then
        log "$(basename "$f"): $(tr '\n' ';' < "$f")"
    else
        log "MISSING_UDEV_DATA $f"
    fi
done
log "sysfs class/input entries:"
ls -la /sys/class/input/ 2>&1 | tee -a "$LOG" /dev/console
log "sysfs bus/input devices:"
ls -la /sys/bus/input/devices/ 2>&1 | tee -a "$LOG" /dev/console
log "subsystem/input -> $(readlink /sys/subsystem/input 2>&1)"

log "===== D. libudev input enumeration ====="
run_guard /root/input16-udevprobe.log 20 /inputudevprobe
udevprobe_rc=$?
cat /root/input16-udevprobe.log >> "$LOG" 2>&1
cat /root/input16-udevprobe.log > /dev/console 2>&1
log "[INPUT_UDEVPROBE_EXIT] rc=$udevprobe_rc"

log "===== E. actual evdev node capabilities ====="
ls -l /dev/input/ >> "$LOG" 2>&1
run_guard /root/input16-evprobe.log 20 /evprobe
ev_rc=$?
cat /root/input16-evprobe.log >> "$LOG" 2>&1
cat /root/input16-evprobe.log > /dev/console 2>&1
log "[EVPROBE_EXIT] rc=$ev_rc"

log "===== F. Weston DRM + libinput; input is required ====="
rm -f /run/seatd.sock "$RD"/wayland-*
SEATD_VTBOUND=0 seatd -l debug > /root/input16-seatd.log 2>&1 &
SD=$!
sleep 1
env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 \
    LIBSEAT_BACKEND=seatd SEATD_SOCK=/run/seatd.sock LIBINPUT_LOG_LEVEL=debug \
    weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
    --seat=seat0 --idle-time=0 --debug --log="$WLOG" \
    > /root/input16-weston-stdout.log 2>&1 &
W=$!
sleep 10
SOCKPATH=$(find "$RD" -maxdepth 1 -type s -name 'wayland-*' 2>/dev/null | head -1)
WDISPLAY=$(basename "$SOCKPATH")
log "weston_alive=$([ -d /proc/$W ] && echo yes || echo no) socket=[${SOCKPATH:-missing}]"
grep -aiE "using /dev/dri/card0|Output .* enabled|Failed to find primary|input|libinput|seat0|shadow framebuffer" "$WLOG" \
    | tail -100 | tee -a "$LOG" /dev/console >/dev/null 2>&1

if [ -n "$SOCKPATH" ] && command -v chromium >/dev/null 2>&1; then
    PROFILE=/root/input16-chromium-profile
    rm -rf "$PROFILE" 2>/dev/null
    log "===== G. Chromium normal renderer mode ====="
    env XDG_RUNTIME_DIR="$RD" WAYLAND_DISPLAY="$WDISPLAY" \
        chromium --ozone-platform=wayland --in-process-gpu --disable-gpu-sandbox \
        --no-sandbox --disable-dev-shm-usage --disable-crash-reporter --disable-breakpad \
        --no-first-run --no-default-browser-check --disable-sync \
        --window-size=1280,800 --start-fullscreen --kiosk \
        --disable-features=SegmentationPlatform,OptimizationGuideModelDownloading,OptimizationHints,WebAppProvider,InterestFeedContentSuggestions \
        --enable-logging=stderr --v=1 \
        --vmodule='*wayland*=2,*ozone*=2,*navigation*=2,*render_process*=2' \
        --user-data-dir="$PROFILE" "$PAGE" > /root/input16-chromium.log 2>&1 &
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
    log "[INPUT16_CHROMIUM_EXIT] wait_rc=$rc"
    grep -aE "FileURLLoader|NavigationRequest|renderer|Failed to initialize cpuinfo|missing credentials|wl_seat|wayland_surface|FATAL|ERROR|inotify" \
        /root/input16-chromium.log | tail -100 >> "$LOG" 2>&1
    snapshot_profile "$PROFILE"
else
    log "[INPUT16_CHROMIUM_SKIP] missing Weston socket or Chromium binary"
fi

sleep 15
kill "$W" 2>/dev/null
kill "$SD" 2>/dev/null
log "===== input-seat16 seatd debug tail ====="
tail -n 160 /root/input16-seatd.log | tee -a "$LOG" /dev/console
log "[INPUT16_SUM] socket=${SOCKPATH:-missing}"
sync
