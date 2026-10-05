#!/bin/sh
# Chromium stage 4 diagnostic after kernel-backed CPU sysfs projection.
# This run intentionally keeps the cr2 browser flags unchanged so the CPU
# discovery change is the only runtime variable; it records the real exit code.

LOG=/root/cr3.log
WLOG=/root/cr3-weston.log
PAGE="file:///usr/share/html-test/index.html"
RD=/run/user/0
: > "$LOG"

log() {
    echo "[cr3] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}

snapshot_chromium() {
    for d in /proc/[0-9]*; do
        [ -r "$d/cmdline" ] || continue
        cmd=$(tr '\000' ' ' < "$d/cmdline" 2>/dev/null)
        case "$cmd" in
            *"cr3-profile"*)
                pid=${d##*/}
                log "PROC pid=$pid cmd=$cmd"
                ;;
        esac
    done
}

log "===== A. 环境与内核投射 ====="
log "kernel: $(uname -srm)"
for f in possible present online kernel_max; do
    p="/sys/devices/system/cpu/$f"
    if [ -r "$p" ]; then
        log "$p=$(cat "$p" 2>&1)"
    else
        log "MISSING $p"
    fi
done
log "cpuinfo: $(grep -c '^processor' /proc/cpuinfo 2>/dev/null) processors"
log "page hashes: $(sha256sum /usr/share/html-test/index.html /usr/share/html-test/interaction.html /usr/share/html-test/layout.html 2>/dev/null | tr '\n' ';')"
chromium --version 2>&1 | head -1 >> "$LOG"

mkdir -p "$RD" 2>/dev/null
chmod 700 "$RD" 2>/dev/null
rm -f /run/seatd.sock "$RD"/wayland-*
SEATD_VTBOUND=0 seatd -l info > /root/cr3-seatd.log 2>&1 &
SD=$!
sleep 1

log "===== B. Weston（真实 DRM + seatd，无输入降级）====="
env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 \
    LIBSEAT_BACKEND=seatd SEATD_SOCK=/run/seatd.sock \
    weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
    --seat=seat0 --continue-without-input --idle-time=0 --debug \
    --log="$WLOG" > /root/cr3-weston-stdout.log 2>&1 &
W=$!
sleep 6
SOCKPATH=$(find "$RD" -maxdepth 1 -type s -name 'wayland-*' 2>/dev/null | head -1)
WDIR=$(dirname "$SOCKPATH")
WDISPLAY=$(basename "$SOCKPATH")
log "weston_alive=$([ -d /proc/$W ] && echo yes || echo no) socket=[$SOCKPATH]"
grep -aE "using /dev/dri/card0|Output .* enabled|shadow framebuffer|input devices" "$WLOG" \
    | sed 's/^/[weston] /' >> "$LOG" 2>&1

if [ -z "$SOCKPATH" ] || ! command -v chromium >/dev/null 2>&1; then
    log "[CR3_SUM] skipped socket=${SOCKPATH:-missing} chromium=$(command -v chromium 2>/dev/null)"
else
    rm -rf /root/cr3-profile 2>/dev/null
    log "===== C. Chromium 启动（参数与 cr2 相同）====="
    env XDG_RUNTIME_DIR="$WDIR" WAYLAND_DISPLAY="$WDISPLAY" \
        chromium --ozone-platform=wayland --in-process-gpu --disable-gpu-sandbox \
        --no-sandbox --disable-dev-shm-usage \
        --user-data-dir=/root/cr3-profile \
        --no-first-run --no-default-browser-check --disable-sync \
        --window-size=1280,800 --start-fullscreen --kiosk \
        --enable-logging=stderr \
        "$PAGE" > /root/cr3-chromium.log 2>&1 &
    C=$!
    log "chromium pid=$C"

    (
        elapsed=0
        while [ "$elapsed" -lt 180 ] && [ -d "/proc/$C" ]; do
            if [ $((elapsed % 15)) -eq 0 ]; then
                log "elapsed=${elapsed}s browser_pid_alive=yes"
                snapshot_chromium
            fi
            sleep 5
            elapsed=$((elapsed + 5))
        done
        if [ -d "/proc/$C" ]; then
            log "WATCHDOG timeout=180s; sending SIGTERM to browser pid=$C"
            kill -TERM "$C" 2>/dev/null
            sleep 10
            kill -KILL "$C" 2>/dev/null
        fi
    ) &
    WATCH=$!

    wait "$C"
    RC=$?
    kill "$WATCH" 2>/dev/null
    wait "$WATCH" 2>/dev/null
    log "[CR3_EXIT] chromium_wait_rc=$RC"
    snapshot_chromium
    log "--- chromium decisive lines ---"
    grep -aE "Failed to initialize cpuinfo|FileURLLoader|missing credentials|inotify|renderer|FATAL|ERROR|wayland_surface" \
        /root/cr3-chromium.log | tail -80 >> "$LOG" 2>&1
    log "--- Weston client lines ---"
    grep -aiE "client|surface|commit|attach|buffer|shell" "$WLOG" | tail -40 >> "$LOG" 2>&1
    log "[CR3_SUM] chromium_wait_rc=$RC weston_alive=$([ -d /proc/$W ] && echo yes || echo no) socket=$SOCKPATH"
fi

sleep 20
kill "$W" 2>/dev/null
kill "$SD" 2>/dev/null
log "cr3 cleanup complete"
sync
