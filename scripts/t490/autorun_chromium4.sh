#!/bin/sh
# Stage 4 isolation round: recheck SCM_CREDENTIALS, disable crash reporting,
# then compare no-zygote multi-process with single-process Chromium.
# The latter is diagnostic only; final validation still needs normal renderers.

set -u
LOG=/root/cr4.log
WLOG=/root/cr4-weston.log
RD=/run/user/0
PAGE="file:///usr/share/html-test/index.html"
: > "$LOG"

log() {
    echo "[cr4] $*" > /dev/console 2>/dev/null
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

run_case() {
    name="$1"
    profile="$2"
    shift 2
    rm -rf "$profile" 2>/dev/null
    log "===== Chromium case=$name profile=$profile ====="
    env XDG_RUNTIME_DIR="$RD" WAYLAND_DISPLAY="$WDISPLAY" \
        chromium --ozone-platform=wayland --in-process-gpu --disable-gpu-sandbox \
        --no-sandbox --disable-dev-shm-usage --disable-crash-reporter --disable-breakpad \
        --no-first-run --no-default-browser-check --disable-sync \
        --window-size=1280,800 --start-fullscreen --kiosk \
        --disable-features=SegmentationPlatform,OptimizationGuideModelDownloading,OptimizationHints,WebAppProvider,InterestFeedContentSuggestions \
        --enable-logging=stderr --v=1 \
        --user-data-dir="$profile" "$@" "$PAGE" > "/root/cr4-$name-chromium.log" 2>&1 &
    p=$!
    log "CASE_START name=$name pid=$p"

    (
        elapsed=0
        while [ "$elapsed" -lt 130 ] && [ -d "/proc/$p" ]; do
            if [ $((elapsed % 15)) -eq 0 ]; then
                log "CASE_ALIVE name=$name elapsed=${elapsed}s"
                snapshot_profile "$profile"
            fi
            sleep 5
            elapsed=$((elapsed + 5))
        done
        if [ -d "/proc/$p" ]; then
            log "CASE_TIMEOUT name=$name limit=130s; sending SIGTERM"
            kill -TERM "$p" 2>/dev/null
            sleep 10
            kill -KILL "$p" 2>/dev/null
        fi
    ) &
    watch=$!

    wait "$p"
    rc=$?
    kill "$watch" 2>/dev/null
    wait "$watch" 2>/dev/null
    log "[CR4_EXIT] case=$name wait_rc=$rc"
    grep -aE "Failed to initialize cpuinfo|FileURLLoader|missing credentials|inotify|renderer|FATAL|ERROR|wayland_surface|MESA-LOADER" \
        "/root/cr4-$name-chromium.log" | tail -80 >> "$LOG" 2>&1
    snapshot_profile "$profile"
    sleep 8
}

log "===== A. ABI/runtime facts ====="
log "kernel: $(uname -srm)"
for f in possible present online kernel_max; do
    p="/sys/devices/system/cpu/$f"
    log "$p=$(cat "$p" 2>&1)"
done
log "pages: $(sha256sum /usr/share/html-test/index.html /usr/share/html-test/interaction.html /usr/share/html-test/layout.html 2>/dev/null | tr '\n' ';')"

if [ -x /compatprobe ]; then
    log "===== B. 标准兼容探针（含 SOCK_SEQPACKET + SCM_CREDENTIALS）====="
    /compatprobe > /root/cr4-compatprobe.log 2>&1
    cp_rc=$?
    grep -aE '^\[CP\]' /root/cr4-compatprobe.log >> "$LOG" 2>&1
    log "[COMPATPROBE_EXIT] rc=$cp_rc"
else
    log "[COMPATPROBE_MISSING] /compatprobe was not injected"
fi

mkdir -p "$RD" 2>/dev/null
chmod 700 "$RD" 2>/dev/null
rm -f /run/seatd.sock "$RD"/wayland-*
SEATD_VTBOUND=0 seatd -l info > /root/cr4-seatd.log 2>&1 &
SD=$!
sleep 1
log "===== C. Weston（真实 DRM/seatd，无 shim）====="
env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 \
    LIBSEAT_BACKEND=seatd SEATD_SOCK=/run/seatd.sock \
    weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
    --seat=seat0 --continue-without-input --idle-time=0 --debug \
    --log="$WLOG" > /root/cr4-weston-stdout.log 2>&1 &
W=$!
sleep 6
SOCKPATH=$(find "$RD" -maxdepth 1 -type s -name 'wayland-*' 2>/dev/null | head -1)
WDISPLAY=$(basename "$SOCKPATH")
log "weston_alive=$([ -d /proc/$W ] && echo yes || echo no) socket=[$SOCKPATH]"
grep -aE "using /dev/dri/card0|Output .* enabled|shadow framebuffer|input devices" "$WLOG" \
    | sed 's/^/[weston] /' >> "$LOG" 2>&1

if [ -n "$SOCKPATH" ]; then
    run_case nozygote /root/cr4-nozygote-profile --no-zygote
    run_case single /root/cr4-single-profile --single-process --no-zygote
else
    log "[CR4_SKIP] Weston socket missing"
fi

log "===== D. 收尾 ====="
grep -aiE "client|surface|commit|attach|buffer|shell" "$WLOG" | tail -40 >> "$LOG" 2>&1
log "[CR4_SUM] socket=${SOCKPATH:-missing} weston_alive=$([ -d /proc/$W ] && echo yes || echo no)"
kill "$W" 2>/dev/null
kill "$SD" 2>/dev/null
log "cr4 cleanup complete"
sync
