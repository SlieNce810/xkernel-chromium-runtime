#!/bin/sh
# 基础任务最小闭环：Weston DRM/pixman + Chromium Wayland + 本地 HTML。
# 只使用软件路径；两种 Chromium 参数顺序依次尝试，便于在 TCG 下取证。

LOG=/root/basic-render.log
: > "$LOG"
log() {
    echo "[basic] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}

log "start chromium=$(chromium --version 2>&1 | head -1)"

# Weston DRM backend 依赖的最小运行时 sysfs/udev 视图。
mkdir -p /run/udev/data /run/user/0 /tmp/.X11-unix \
    /sys/dev/char/226:0/device /sys/devices/simpledrm /sys/bus/faux /sys/class/drm/card0 2>/dev/null
printf 'E:ID_INPUT=1\nE:ID_INPUT_KEYBOARD=1\nE:ID_SEAT=seat0\n' > /run/udev/data/c13:1
ln -sf ../../faux /sys/dev/char/226:0/device/subsystem 2>/dev/null
printf 'MAJOR=226\nMINOR=0\nDEVNAME=dri/card0\nSUBSYSTEM=drm\nDEVTYPE=drm_minor\n' > /sys/class/drm/card0/uevent 2>/dev/null
printf '226:0\n' > /sys/class/drm/card0/dev 2>/dev/null
ln -sf ../../bus/faux /sys/class/drm/card0/subsystem 2>/dev/null
printf 'drm 1.1.0 simpledrm 1.0.0\n' > /sys/class/drm/version 2>/dev/null
chmod 700 /run/user/0; chmod 1777 /tmp/.X11-unix

pkill -x chromium 2>/dev/null
pkill -x weston 2>/dev/null
pkill -x seatd 2>/dev/null
rm -f /run/seatd.sock /run/user/0/wayland-* /tmp/weston.log
seatd -g root -l debug >/tmp/seatd.log 2>&1 &
sleep 2

env LD_PRELOAD=/usr/local/lib/libseat-shim.so \
    XDG_RUNTIME_DIR=/run/user/0 WESTON_DISABLE_ATOMIC=1 \
    weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
    --seat=seat0 --continue-without-input --idle-time=0 --socket=wayland-0 \
    --log=/tmp/weston.log >/dev/console 2>&1 &

i=0
while [ "$i" -lt 30 ]; do
    [ -S /run/user/0/wayland-0 ] && break
    i=$((i + 1)); sleep 1
done
if [ ! -S /run/user/0/wayland-0 ]; then
    log "weston FAILED after ${i}s"
    tail -30 /tmp/weston.log >> "$LOG" 2>&1
    exit 20
fi
log "weston UP socket=wayland-0 after ${i}s"

export XDG_RUNTIME_DIR=/run/user/0
export WAYLAND_DISPLAY=wayland-0
mkdir -p /tmp/chromium-basic

run_browser() {
    tag="$1"; shift
    out="/root/basic-${tag}.log"
    : > "$out"
    data_dir="/tmp/chromium-basic-${tag}"
    rm -rf "$data_dir"
    if [ "$tag" = "single" ]; then
        # 对照路径：renderer/viz 都并入 browser，专门判断多进程创建是否是
        # 空白页的唯一阻塞；不使用 --in-process-gpu 与前一候选混淆。
        GPU_ARGS="--disable-gpu --single-process --no-zygote"
    else
        GPU_ARGS="--disable-gpu --in-process-gpu --use-gl=angle --use-angle=swiftshader"
    fi
    log "launch ${tag}: chromium ${GPU_ARGS} $* file:///usr/share/html-test/index.html"
    chromium --ozone-platform=wayland --no-sandbox --disable-dev-shm-usage \
        --enable-logging=stderr --v=1 --user-data-dir="$data_dir" \
        $GPU_ARGS \
        --disable-features=Vulkan,SegmentationPlatform,OptimizationGuideModelDownloading,OptimizationHints,WebAppProvider,InterestFeedContentSuggestions,AudioServiceOutOfProcess,AudioServiceSandbox \
        --no-first-run --no-default-browser-check --disable-component-update \
        --disable-background-networking --disable-sync --disable-extensions \
        --disable-crash-reporter --disable-breakpad --disable-crashpad \
        --mute-audio --disable-audio-output \
        "$@" \
        file:///usr/share/html-test/index.html >> "$out" 2>&1 &
    p=$!
    log "${tag} pid=$p"
    t=0
    while [ "$t" -lt 90 ] && [ -d "/proc/$p" ]; do
        if grep -q 'FileURLLoader::Start' "$out" 2>/dev/null; then
            log "${tag} navigation-start at ${t}s"
            # Keep the browser alive long enough for an external screendump.
            sleep 35
            break
        fi
        t=$((t + 5)); sleep 5
    done
    if [ -d "/proc/$p" ]; then
        log "${tag} alive; renderer=[$(pgrep -f 'type=renderer' | tr '\n' ' ')]"
        kill "$p" 2>/dev/null
        sleep 3
    else
        wait "$p"; rc=$?
        log "${tag} exited rc=$rc after ${t}s"
    fi
    grep -nE 'FileURLLoader|ERROR|FATAL|GPU process|Exiting GPU' "$out" | tail -40 >> "$LOG" 2>&1
}

# First try the corrected ANGLE/SwiftShader selection, then always run the
# single-process comparison so that a blank multi-process page is not mistaken
# for a working basic-task result.
run_browser angle
run_browser single

log "done"
sync
