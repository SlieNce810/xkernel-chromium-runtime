#!/bin/sh
# autorun_r3.sh —— renderer 追击第三轮（换两个假设）
#
# r2 轮的结论（先记录，免得重复走）
#   A 段（多进程 + --host-resolver-rules 屏蔽网络，240s）：
#     crash=0 / NO_NEW_PRIVS=0 / FATAL=0  ← P3 稳定
#     但 renderer 与 RenderProcessHost 计数**仍为 0**
#     → **"启动被注定失败的联网任务拖住"这个假设不成立**（至少不充分）
#   B 段（--single-process）：仍 rc=191、存活 50s，且 FATAL/prctl 计数为 0
#     → 我此前把 rc=191 归因于 P3 那条 prctl 是**过度归因**，已更正
#
# 本轮两个新假设
#   C 段：**去掉 `--in-process-gpu`，回到标准多进程**。
#         补丁前这一档必然 `GPU process isn't usable. Goodbye.`(rc=191)；
#         P3 之后 GPU 子进程应当能活。若 C 段能起 renderer，则说明
#         `--in-process-gpu` 本身就是 renderer 路径的干扰项（它只为绕开 GPU 子进程之死而加）。
#         同时用 `--disable-features=…` 砍掉拖慢启动的 SegmentationPlatform /
#         OptimizationGuide / WebAppProvider，让启动尽快走到导航那一步。
#   D 段：保留 `--in-process-gpu`（与 nnp 轮同 GPU 模式），**只改特性开关**，
#         作为 C 段的对照——用于区分"是 GPU 模式的问题"还是"是启动特性的问题"。
#
# 采样每 10s，单独记录 gpu / renderer，两次都统计全局 COUNT。

LOG=/root/r3.log
: > "$LOG"
log() {
    echo "[r3] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}
tl() { "$@" 2>&1 | tee -a "$LOG" /dev/console; }

log "start uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null) chromium=$(chromium --version 2>&1 | head -1)"

for p in /nvprobe; do [ -x "$p" ] && { log "----- $p -----"; tl "$p"; }; done

mkdir -p /run/udev/data 2>/dev/null
cat > /run/udev/data/c13:1 <<'EOF'
E:ID_INPUT=1
E:ID_INPUT_KEYBOARD=1
E:ID_SEAT=seat0
EOF

# ---------------------------------------------------------------- weston
log "===== weston ====="
mkdir -p /sys/dev/char/226:0/device /sys/devices/simpledrm /sys/bus/faux 2>/dev/null
ln -sf ../../faux /sys/dev/char/226:0/device/subsystem 2>/dev/null
mkdir -p /sys/class/drm/card0 2>/dev/null
printf 'MAJOR=226\nMINOR=0\nDEVNAME=dri/card0\nSUBSYSTEM=drm\nDEVTYPE=drm_minor\n' > /sys/class/drm/card0/uevent 2>/dev/null
printf '226:0\n' > /sys/class/drm/card0/dev 2>/dev/null
ln -sf ../../bus/faux /sys/class/drm/card0/subsystem 2>/dev/null
printf 'drm 1.1.0 simpledrm 1.0.0\n' > /sys/class/drm/version 2>/dev/null
mkdir -p /run/user/0 /tmp/.X11-unix 2>/dev/null
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
    log "  weston pid=$(pgrep -x weston | tr '\n' ' ') socket=${WL_SOCK:-NONE}（等 ${i}s）"
fi
export XDG_RUNTIME_DIR=/run/user/0
export WAYLAND_DISPLAY="${WL_SOCK:-wayland-0}"
mkdir -p /tmp/chromium-baseline

# 公共参数：砍掉拖慢启动的特性
# ★ 这里**故意不放** `--host-resolver-rules="MAP * ~NOTFOUND"`：
#   ① r2 轮已证明屏蔽网络并不能让 renderer 出现，不是关键变量；
#   ② 它的值含空格，放进变量后再 `$COMMON` 展开会被词分割成三个 argv（踩过）。
COMMON="--ozone-platform=wayland --no-sandbox --disable-dev-shm-usage
 --enable-logging=stderr --v=1 --user-data-dir=/tmp/chromium-baseline
 --disable-features=Vulkan,SegmentationPlatform,OptimizationGuideModelDownloading,OptimizationHints,WebAppProvider,InterestFeedContentSuggestions
 --no-first-run --no-default-browser-check --disable-component-update
 --disable-background-networking --disable-sync --disable-extensions --disable-crash-reporter
 file:///usr/share/html-test/index.html"

sample() {
    t="$1"; c="$2"; n="$3"
    {
        echo "--- [$t] +${n}s ---"
        echo "  browser =[$(pgrep -f 'lib/chromium/chromium' | tr '\n' ' ')]"
        echo "  zygote  =[$(pgrep -f 'type=zygote' | tr '\n' ' ')]"
        echo "  gpu     =[$(pgrep -f 'type=gpu' | tr '\n' ' ')]"
        echo "  utility =[$(pgrep -f 'type=utility' | tr '\n' ' ')]"
        echo "  renderer=[$(pgrep -f 'type=renderer' | tr '\n' ' ')]"
        echo "  alive=$([ -d /proc/$c ] && echo yes || echo no)"
    } >> "$LOG" 2>&1
}

run_leg() {
    tag="$1"; secs="$2"; shift 2
    L=/root/r3-$tag.log
    : > "$L"
    log "===== $tag 段（${secs}s）: $* ====="
    # shellcheck disable=SC2086
    chromium $COMMON $* >> "$L" 2>&1 &
    P=$!
    log "  $tag browser pid=$P"
    k=0
    while [ "$k" -lt "$secs" ]; do
        [ -d /proc/$P ] || break
        sample "$tag" "$P" "$k"
        k=$((k + 10)); sleep 10
    done
    if [ -d /proc/$P ]; then
        log "  $tag 仍在运行（${k}s）✓  gpu=[$(pgrep -f 'type=gpu' | tr '\n' ' ')] renderer=[$(pgrep -f 'type=renderer' | tr '\n' ' ')]"
    else
        wait "$P"; rc=$?
        log "  $tag 已退出 rc=$rc（存活约 ${k}s）  ★ 补丁前「无 --in-process-gpu」此处应为 191"
    fi
    for pat in 'Network service crashed' 'NO_NEW_PRIVS' 'RenderProcessHost' 'renderer' 'GPU process isn' 'FATAL' 'Untitled'; do
        log "  $tag COUNT [$pat] = $(grep -c "$pat" "$L" 2>/dev/null)"
    done
    log "  ==== $tag 前 20 行 ===="; head -20 "$L" > /dev/console 2>&1
    log "  ==== $tag 尾 30 行 ===="; tail -30 "$L" > /dev/console 2>&1
    log "  ==== $tag 错误行 ===="
    grep -nE "ERROR|FATAL|Failed|Aborted" "$L" | head -25 > /dev/console 2>&1
    pkill -f 'lib/chromium/chromium' 2>/dev/null
    sleep 3
}

# C 段：标准多进程（不带 --in-process-gpu）
run_leg C 240 --use-gl=swiftshader --disable-gpu-sandbox
# D 段：带 --in-process-gpu（对照，只差 GPU 模式）
run_leg D 240 --in-process-gpu --use-gl=swiftshader --disable-gpu-sandbox

log "===== watcher ====="
n=0
while [ "$n" -lt 40 ]; do
    { echo "=== $(date 2>/dev/null) (+$((n * 30))s) weston=$(pgrep -x weston | tr '\n' ' ') browser=$(pgrep -f 'lib/chromium/chromium' | tr '\n' ' ') renderer=$(pgrep -f 'type=renderer' | tr '\n' ' ') ==="; } >> /root/r3-watch.log 2>&1
    sync; n=$((n + 1)); sleep 30
done
log "autorun_r3 done"; sync; sync
