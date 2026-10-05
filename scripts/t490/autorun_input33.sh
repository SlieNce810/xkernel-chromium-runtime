#!/bin/sh
# Bounded retry of the input-seat round. udevadm info hung in input-seat, so all
# udev operations below have a watchdog and libudev is queried before Weston.

set -u
LOG=/root/input33.log
WLOG=/root/input33-weston.log
RD=/run/user/0
PAGE="file:///usr/share/html-test/index.html"
: > "$LOG"

log() {
    echo "[input33] $*" > /dev/console 2>/dev/null
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
    log "runtime overlay extraction complete"
fi
if [ -s /root/chromium-swiftshader.apk ] && \
   [ -s /usr/lib/chromium/libvk_swiftshader.so ] && \
   [ -s /usr/lib/chromium/vk_swiftshader_icd.json ]; then
    sha256sum /root/chromium-swiftshader.apk /usr/lib/chromium/libvk_swiftshader.so \
        /usr/lib/chromium/vk_swiftshader_icd.json | tee -a "$LOG" /dev/console
    log "[SWIFTSHADER_PAYLOAD] official apk and extracted files present"
    cat /usr/lib/chromium/vk_swiftshader_icd.json | tee -a "$LOG" /dev/console
else
    log "[SWIFTSHADER_PAYLOAD_MISSING] package or payload file is absent/empty"
fi
if [ -x /p33_pi_mutex ]; then
    /p33_pi_mutex > /root/input33-pi-mutex.log 2>&1
    pi_rc=$?
    cat /root/input33-pi-mutex.log >> "$LOG" 2>&1
    cat /root/input33-pi-mutex.log > /dev/console 2>&1
    log "[PTHREAD_PI_PROBE_EXIT] rc=$pi_rc"
else
    log "[PTHREAD_PI_PROBE_MISSING] /p33_pi_mutex"
fi

log "===== B. pathname AF_UNIX SOCK_SEQPACKET control probe ====="
if [ -x /seqpacketprobe ]; then
    /seqpacketprobe > /root/input33-seqpacket.log 2>&1
    seq_rc=$?
    cat /root/input33-seqpacket.log >> "$LOG"
    log "[SEQPACKETPROBE_EXIT] rc=$seq_rc"
else
    log "[SEQPACKETPROBE_MISSING] /seqpacketprobe was not injected"
fi

log "===== B2. AF_UNIX automatic SO_PASSCRED probe ====="
if [ -x /passcredprobe ]; then
    /passcredprobe > /root/input33-passcredprobe.log 2>&1
    passcred_rc=$?
    cat /root/input33-passcredprobe.log >> "$LOG" 2>&1
    cat /root/input33-passcredprobe.log > /dev/console 2>&1
    log "[PASSCREDPROBE_EXIT] rc=$passcred_rc"
else
    log "[PASSCREDPROBE_MISSING] /passcredprobe was not injected"
fi
log "===== C. standard eudev service and coldplug ====="
mkdir -p /run/udev/data /run/user/0 2>/dev/null
chmod 700 /run/user/0 2>/dev/null
udevd --debug > /root/input33-udevd.log 2>&1 &
UDEV=$!
sleep 1
log "udevd_foreground_pid=$UDEV alive=$([ -d /proc/$UDEV ] && echo yes || echo no)"
tail -n 50 /root/input33-udevd.log >> "$LOG" 2>&1
log "udevd_start_pid=$UDEV"
sleep 1
log "===== probe kernel KOBJECT_UEVENT delivery to NETLINK group 1 ====="
run_guard /root/input33-ueventprobe.log 25 /ueventprobe2
uevent_rc=$?
cat /root/input33-ueventprobe.log >> "$LOG" 2>&1
cat /root/input33-ueventprobe.log > /dev/console 2>&1
log "[UEVENTPROBE_EXIT] rc=$uevent_rc"
run_guard /root/input33-trigger.log 15 udevadm trigger --action=add --subsystem-match=input
trigger_rc=$?
log "udevadm_trigger_rc=$trigger_rc"
cat /root/input33-trigger.log >> "$LOG" 2>&1
cat /root/input33-trigger.log > /dev/console 2>&1
run_guard /root/input33-settle.log 15 udevadm settle --timeout=8
settle_rc=$?
log "udevadm_settle_rc=$settle_rc"
cat /root/input33-settle.log >> "$LOG" 2>&1
cat /root/input33-settle.log > /dev/console 2>&1
log "udevd processes:"
ps w | grep "[u]devd" | tee -a "$LOG" /dev/console
log "udevd debug tail:"
tail -n 100 /root/input33-udevd.log | tee -a "$LOG" /dev/console

if [ -x /udevinitprobe ]; then
    /udevinitprobe > /root/input33-udevinitprobe.log 2>&1
    udevinit_rc=$?
    cat /root/input33-udevinitprobe.log >> "$LOG" 2>&1
    cat /root/input33-udevinitprobe.log > /dev/console 2>&1
    log "[UDEVINITPROBE_EXIT] rc=$udevinit_rc"
else
    log "[UDEVINITPROBE_MISSING] /udevinitprobe was not injected"
fi
if [ -x /statprobe ]; then
    /statprobe > /root/input33-statprobe.log 2>&1
    statprobe_rc=$?
    cat /root/input33-statprobe.log >> "$LOG" 2>&1
    cat /root/input33-statprobe.log > /dev/console 2>&1
    log "[STATPROBE_EXIT] rc=$statprobe_rc"
else
    log "[STATPROBE_MISSING] /statprobe was not injected"
fi
log "sysfs dev/char links:"
for d in 13:64 13:65; do
    log "/sys/dev/char/$d -> $(readlink /sys/dev/char/$d 2>&1) dev=$(cat /sys/dev/char/$d/dev 2>&1)"
done
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
run_guard /root/input33-udevprobe.log 20 /inputudevprobe
udevprobe_rc=$?
cat /root/input33-udevprobe.log >> "$LOG" 2>&1
cat /root/input33-udevprobe.log > /dev/console 2>&1
log "[INPUT_UDEVPROBE_EXIT] rc=$udevprobe_rc"

log "===== E. actual evdev node capabilities ====="
ls -l /dev/input/ >> "$LOG" 2>&1
run_guard /root/input33-evprobe.log 20 /evprobe
ev_rc=$?
cat /root/input33-evprobe.log >> "$LOG" 2>&1
cat /root/input33-evprobe.log > /dev/console 2>&1
log "[EVPROBE_EXIT] rc=$ev_rc"

log "===== F. Weston DRM + libinput; input is required ====="
rm -f /run/seatd.sock "$RD"/wayland-*
SEATD_VTBOUND=0 seatd -l info > /root/input33-seatd.log 2>&1 &
SD=$!
sleep 1
if [ -x /usr/bin/seatprobe ]; then
    /usr/bin/seatprobe > /root/input33-seatprobe.log 2>&1
    seatprobe_rc=$?
    cat /root/input33-seatprobe.log >> "$LOG" 2>&1
    cat /root/input33-seatprobe.log > /dev/console 2>&1
    log "[SEATPROBE_EXIT] rc=$seatprobe_rc"
else
    log "[SEATPROBE_MISSING] /usr/bin/seatprobe"
fi
if [ -x /usr/bin/libinputprobe ]; then
    /usr/bin/libinputprobe > /root/input33-libinputprobe.log 2>&1
    libinput_rc=$?
    cat /root/input33-libinputprobe.log >> "$LOG" 2>&1
    cat /root/input33-libinputprobe.log > /dev/console 2>&1
    log "[LIBINPUTPROBE_EXIT] rc=$libinput_rc"
else
    log "[LIBINPUTPROBE_MISSING] /usr/bin/libinputprobe"
fi
env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 \
    LIBSEAT_BACKEND=seatd SEATD_SOCK=/run/seatd.sock WESTON_LIBINPUT_LOG_PRIORITY=debug \
    weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
    --seat=seat0 --idle-time=0 --debug --log="$WLOG" \
    > /root/input33-weston-stdout.log 2>&1 &
W=$!
sleep 10
SOCKPATH=$(find "$RD" -maxdepth 1 -type s -name 'wayland-*' 2>/dev/null | head -1)
WDISPLAY=$(basename "$SOCKPATH")
log "weston_alive=$([ -d /proc/$W ] && echo yes || echo no) socket=[${SOCKPATH:-missing}]"
grep -aiE "using /dev/dri/card0|Output .* enabled|Failed to find primary|input|libinput|seat0|shadow framebuffer" "$WLOG" \
    | tail -100 | tee -a "$LOG" /dev/console >/dev/null 2>&1

if [ -n "$SOCKPATH" ] && command -v chromium >/dev/null 2>&1; then
    PROFILE=/root/input33-chromium-profile
    rm -rf "$PROFILE" 2>/dev/null
    log "===== G. Chromium normal renderer mode ====="
    env XDG_RUNTIME_DIR="$RD" WAYLAND_DISPLAY="$WDISPLAY" \
        VK_ICD_FILENAMES=/usr/lib/chromium/vk_swiftshader_icd.json \
        /usr/lib/chromium/chromium --ozone-platform=wayland --use-gl=angle --use-angle=vulkan --in-process-gpu \
        --no-sandbox --disable-dev-shm-usage --disable-crash-reporter --disable-breakpad \
        --no-first-run --no-default-browser-check --disable-sync \
        --window-size=1280,800 --start-fullscreen --kiosk \
        --disable-features=SegmentationPlatform,OptimizationGuideModelDownloading,OptimizationHints,WebAppProvider,InterestFeedContentSuggestions \
        --enable-logging=stderr --v=1 \
        --vmodule='*wayland*=2,*ozone*=2,*navigation*=2,*render_process*=2' \
        --user-data-dir="$PROFILE" "$PAGE" > /root/input33-chromium.log 2>&1 &
    C=$!
    log "chromium pid=$C"
    (
        elapsed=0
        while [ "$elapsed" -lt 210 ] && [ -d "/proc/$C" ]; do
            if [ $((elapsed % 15)) -eq 0 ]; then
                log "chromium_alive elapsed=${elapsed}s"
                snapshot_profile "$PROFILE"
            fi
            sleep 5
            elapsed=$((elapsed + 5))
        done
        if [ -d "/proc/$C" ]; then
            log "chromium watchdog timeout=210s; sending SIGTERM"
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
    log "[INPUT33_CHROMIUM_EXIT] wait_rc=$rc"
    log "[CHROMIUM_LOG_TAIL_BEGIN]"
    tail -n 120 /root/input33-chromium.log >> "$LOG" 2>&1
    log "[CHROMIUM_LOG_TAIL_END]"
    ps w | grep "[c]hromium" | tee -a "$LOG" /dev/console
    snapshot_profile "$PROFILE"
else
    log "[INPUT33_CHROMIUM_SKIP] missing Weston socket or Chromium binary"
fi

sleep 15
kill "$W" 2>/dev/null
kill "$SD" 2>/dev/null
log "===== H. Chromium headless page/render diagnostic ====="
run_guard /root/input33-headless.log 90 env VK_ICD_FILENAMES=/usr/lib/chromium/vk_swiftshader_icd.json /usr/lib/chromium/chromium --headless --use-gl=angle --use-angle=vulkan --in-process-gpu --no-sandbox --disable-dev-shm-usage --disable-crash-reporter --disable-breakpad --no-first-run --window-size=1280,800 --user-data-dir=/root/input33-headless-profile --screenshot=/root/input33-headless.png --dump-dom "$PAGE"
headless_rc=$?
log "[INPUT33_HEADLESS_EXIT] rc=$headless_rc"
if [ -s /root/input33-headless.png ]; then
    ls -l /root/input33-headless.png | tee -a "$LOG" /dev/console
    sha256sum /root/input33-headless.png | tee -a "$LOG" /dev/console
else
    log "[HEADLESS_SCREENSHOT_MISSING] /root/input33-headless.png"
fi
tail -n 80 /root/input33-headless.log | tee -a "$LOG" /dev/console
log "[INPUT33_SUM] socket=${SOCKPATH:-missing}"
sync
