#!/bin/sh
# autorun_r2.sh —— renderer 追击（P3 之后的第二阶段）
#
# 背景
#   P3 修好 prctl(PR_SET_NO_NEW_PRIVS) 后：
#     ✓ 崩溃循环归零（Network service crashed = 0）
#     ✓ zygote / utility / crashpad 首次稳定常驻
#     ✓ **Chromium 浏览器 UI 完整渲染**（标签栏 + 地址栏 + 菜单，见截图）
#     ✗ 内容区仍空白、标签标题仍 "Untitled" → renderer 从未出现，
#       且完整 chromium.log（336 行）里**没有任何** RenderProcessHost / 导航相关日志
#       → 浏览器 11 分钟内从未尝试派生 renderer。
#
# 本轮两段（一次会话拿两个答案）
#   A 段：多进程 + **屏蔽网络**。上一轮浏览器把大量时间耗在 GCM / optimization-guide
#         / 政策拉取的分钟级超时上（`Delaying GCM registration ... for 215716 ms`）。
#         用 --host-resolver-rules 让这些请求瞬间失败，看 renderer 是否随之出现。
#         → 若出现：之前只是"启动被网络拖死"，不是内核缺口。
#   B 段：--single-process。**P3 之前这一档必然 rc=191**（renderer/utility 初始化
#         跑在 browser 进程内，撞上 prctl FATAL——这正是旧结论"single-process 不是退路"
#         的成因）。现在它应当能活；若页面真的渲染出来，则同时证明：
#           ① P3 修复真实有效（独立 A/B）
#           ② 剩下的阻塞只在「zygote 派生 renderer」这一条路上
#
# 另修：上一轮 weston 的 socket 等待循环里 `pgrep -x weston || break` 会因 fork/exec
#       竞态在 0s 就 break，导致误报 `socket=NONE`。本轮改为**只等 socket**。

LOG=/root/r2.log
WATCH=/root/r2-watch.log
: > "$LOG"
: > "$WATCH"

log() {
    echo "[r2] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}
tl() { "$@" 2>&1 | tee -a "$LOG" /dev/console; }

log "start uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)  chromium=$(chromium --version 2>&1 | head -1)"

# ---------------------------------------------------------------- 1. 回归探针
for probe in /nvprobe; do
    if [ -x "$probe" ]; then
        log "----- $probe（P3 回归）-----"
        tl "$probe"
    fi
done

# ---------------------------------------------------------------- 2. udev 伪造
mkdir -p /run/udev/data 2>/dev/null
cat > /run/udev/data/c13:1 <<'EOF'
E:ID_INPUT=1
E:ID_INPUT_KEYBOARD=1
E:ID_SEAT=seat0
EOF

# ---------------------------------------------------------------- 3. weston
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
pkill -x weston 2>/dev/null
pkill -x seatd 2>/dev/null
sleep 1
rm -f /run/seatd.sock /tmp/weston.log /run/user/0/wayland-*
seatd -g root -l debug >/tmp/seatd.log 2>&1 &
sleep 2

if [ -f /usr/local/lib/libseat-shim.so ]; then
    env LD_PRELOAD=/usr/local/lib/libseat-shim.so XDG_RUNTIME_DIR=/run/user/0 WESTON_DISABLE_ATOMIC=1 \
        weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
        --seat=seat0 --continue-without-input --idle-time=0 --socket=wayland-0 \
        --log=/tmp/weston.log >/dev/console 2>&1 &
    # ★ 只等 socket 出现（上一轮的 pgrep 竞态会在 0s 误判）
    i=0
    while [ "$i" -lt 30 ]; do
        [ -n "$(ls /run/user/0 2>/dev/null | grep -E '^wayland-[0-9]+$')" ] && break
        i=$((i + 1)); sleep 1
    done
    WL_SOCK=$(ls /run/user/0 2>/dev/null | grep -E '^wayland-[0-9]+$' | head -n1)
    log "  weston pid=$(pgrep -x weston | tr '\n' ' ') socket=${WL_SOCK:-NONE}（等 ${i}s）"
else
    log "  !! libseat-shim.so 缺失"
fi

export XDG_RUNTIME_DIR=/run/user/0
export WAYLAND_DISPLAY="${WL_SOCK:-wayland-0}"
mkdir -p /tmp/chromium-baseline
log "  WAYLAND_DISPLAY=$WAYLAND_DISPLAY"

# 采样器：每 10s 记一次进程格局（子进程短命，采样要密）
sample() {
    tag="$1"; cpid="$2"; n="$3"
    {
        echo "--- [$tag] +${n}s ---"
        echo "  browser =[$(pgrep -f 'lib/chromium/chromium' | tr '\n' ' ')]"
        echo "  zygote  =[$(pgrep -f 'type=zygote' | tr '\n' ' ')]"
        echo "  gpu     =[$(pgrep -f 'type=gpu' | tr '\n' ' ')]"
        echo "  utility =[$(pgrep -f 'type=utility' | tr '\n' ' ')]"
        echo "  renderer=[$(pgrep -f 'type=renderer' | tr '\n' ' ')]"
        echo "  alive=$([ -d /proc/$cpid ] && echo yes || echo no)"
    } >> "$LOG" 2>&1
}

# ---------------------------------------------------------------- 4. A 段：多进程 + 屏蔽网络
log "===== A 段：多进程 + 屏蔽网络（240s）====="
A_LOG=/root/r2-a.log
: > "$A_LOG"
chromium --ozone-platform=wayland --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --enable-logging=stderr --v=1 \
    --user-data-dir=/tmp/chromium-baseline \
    --in-process-gpu --use-gl=swiftshader --disable-gpu-sandbox \
    --disable-features=Vulkan \
    --no-first-run --no-default-browser-check \
    --disable-component-update --disable-background-networking --disable-sync \
    --disable-extensions --disable-crash-reporter \
    --host-resolver-rules="MAP * ~NOTFOUND" \
    file:///usr/share/html-test/index.html >> "$A_LOG" 2>&1 &
A_PID=$!
log "  A browser pid=$A_PID"
k=0
while [ "$k" -lt 240 ]; do
    [ -d /proc/$A_PID ] || break
    sample A "$A_PID" "$k"
    k=$((k + 10)); sleep 10
done
log "  A 段结束（${k}s）alive=$([ -d /proc/$A_PID ] && echo yes || echo no)"
for pat in 'Network service crashed' 'NO_NEW_PRIVS' 'RenderProcessHost' 'renderer' 'FATAL'; do
    log "  A COUNT [$pat] = $(grep -c "$pat" "$A_LOG" 2>/dev/null)"
done
log "  A renderer 计数=$(pgrep -cf 'type=renderer')"
log "  ==== A 日志前 25 行 ===="; head -25 "$A_LOG" > /dev/console 2>&1
log "  ==== A 日志尾 25 行 ===="; tail -25 "$A_LOG" > /dev/console 2>&1

# ---------------------------------------------------------------- 5. B 段：--single-process
log "===== B 段：--single-process（P3 前必 rc=191）（210s）====="
pkill -f 'lib/chromium/chromium' 2>/dev/null
sleep 3
B_LOG=/root/r2-b.log
: > "$B_LOG"
chromium --ozone-platform=wayland --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --enable-logging=stderr --v=1 \
    --user-data-dir=/tmp/chromium-baseline \
    --single-process --no-zygote --in-process-gpu --use-gl=swiftshader --disable-gpu-sandbox \
    --disable-features=Vulkan \
    --no-first-run --no-default-browser-check \
    --disable-component-update --disable-background-networking --disable-sync \
    --disable-extensions --disable-crash-reporter \
    --host-resolver-rules="MAP * ~NOTFOUND" \
    file:///usr/share/html-test/index.html >> "$B_LOG" 2>&1 &
B_PID=$!
log "  B browser pid=$B_PID"
m=0
while [ "$m" -lt 210 ]; do
    [ -d /proc/$B_PID ] || break
    sample B "$B_PID" "$m"
    m=$((m + 10)); sleep 10
done
if [ -d /proc/$B_PID ]; then
    log "  B 仍在运行（${m}s）✓"
else
    wait "$B_PID"; rc=$?
    log "  B 已退出 rc=$rc（存活约 ${m}s）★ P3 前此处恒为 191"
fi
for pat in 'Network service crashed' 'NO_NEW_PRIVS' 'RenderProcessHost' 'renderer' 'FATAL' 'Untitled'; do
    log "  B COUNT [$pat] = $(grep -c "$pat" "$B_LOG" 2>/dev/null)"
done
log "  ==== B 日志前 25 行 ===="; head -25 "$B_LOG" > /dev/console 2>&1
log "  ==== B 日志尾 40 行 ===="; tail -40 "$B_LOG" > /dev/console 2>&1
log "  ==== B 错误行 ===="
grep -nE "ERROR|FATAL|Failed|Aborted|Unimplemented" "$B_LOG" | head -30 > /dev/console 2>&1

# ---------------------------------------------------------------- 6. watcher
log "===== watcher ====="
n=0
while [ "$n" -lt 60 ]; do
    {
        echo "=== $(date 2>/dev/null) (+$((n * 30))s) ==="
        echo "weston:   $(pgrep -x weston | tr '\n' ' ')"
        echo "browser:  $(pgrep -f 'lib/chromium/chromium' | tr '\n' ' ')"
        echo "renderer: $(pgrep -f 'type=renderer' | tr '\n' ' ')"
    } >> "$WATCH" 2>&1
    sync
    n=$((n + 1))
    sleep 30
done
log "autorun_r2 done"
sync
sync
