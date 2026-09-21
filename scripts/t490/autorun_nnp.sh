#!/bin/sh
# autorun_nnp.sh — P3（prctl PR_SET_NO_NEW_PRIVS）验证轮
#
# 目标
#   ① /nvprobe 直接验证 prctl 语义（不靠 Chromium 日志推断）
#   ② 看 Chromium 子进程是否终于能活下来 → renderer 是否出现、页面是否渲染
#
# 相对 autorun_install.sh 的三处刻意改动（都是上一轮的教训）
#   a. 探针循环加入 /nvprobe —— 固定列表漏加会白跑一轮
#   b. 不再做 A/B 两次启动尝试，直接跑 B 模式（--in-process-gpu，已知能出窗口）
#   c. "某类日志是否消失"一律用**全局 grep 计数**，不用 tail 窗口
#
# 阶段：1 前置校验 2 探针 3 weston 4 Chromium 5 全局计数 6 watcher

LOG=/root/nnp.log
WATCH=/root/nnp-watch.log
CHROME_LOG=/root/chromium.log
: > "$LOG"
: > "$WATCH"

log() {
    echo "[nnp] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}
tl() { "$@" 2>&1 | tee -a "$LOG" /dev/console; }

log "start alpine=$(cat /etc/alpine-release 2>/dev/null) uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
log "df: $(df -h / 2>/dev/null | tail -1)"

# ---------------------------------------------------------------- 1. 前置校验
log "===== 1. 前置校验 ====="
log "  chromium: $(ls -l /usr/lib/chromium/chromium 2>&1 | tr -s ' ')"
log "  version : $(chromium --version 2>&1 | head -1)"
log "  fonts.conf 行数: $(wc -l < /etc/fonts/fonts.conf 2>/dev/null)"
log "  /dev/input: $(ls /dev/input/ 2>&1 | tr '\n' ' ')"

# ---------------------------------------------------------------- 2. 探针
# 注意：这是**固定列表**，新增探针必须同步加进来（t490_round.sh 只负责注入）
log "===== 2. 探针 ====="
for probe in /nvprobe /p2probe /childprobe /evprobe /fdprobe; do
    if [ -x "$probe" ]; then
        log "----- 运行 $probe -----"
        tl "$probe"
        log "----- $probe 判定行 -----"
        grep -E "^\[[A-Z0-9]+\].*=(PASS|FAIL)|^\[RESULT\]|^\[SUMMARY\]|^\[EVMAP\]|^\[EVSUM\]|^\[T[0-9]\]" "$LOG" \
            | tail -25 > /dev/console 2>&1
    else
        log "  跳过（未注入）: $probe"
    fi
done

# ---------------------------------------------------------------- 3. 输入设备 udev 伪造
mkdir -p /run/udev/data 2>/dev/null
cat > /run/udev/data/c13:1 <<'EOF'
E:ID_INPUT=1
E:ID_INPUT_KEYBOARD=1
E:ID_SEAT=seat0
EOF

# ---------------------------------------------------------------- 4. weston
log "===== 3. weston（libseat-shim + 伪造 sysfs + card0）====="
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
log "  seatd pid=$(pgrep -x seatd | tr '\n' ' ')"

WL_SOCK=""
if [ -f /usr/local/lib/libseat-shim.so ]; then
    env LD_PRELOAD=/usr/local/lib/libseat-shim.so XDG_RUNTIME_DIR=/run/user/0 WESTON_DISABLE_ATOMIC=1 \
        weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
        --seat=seat0 --continue-without-input --idle-time=0 --socket=wayland-0 \
        --log=/tmp/weston.log >/dev/console 2>&1 &
    i=0
    while [ "$i" -lt 20 ]; do
        pgrep -x weston >/dev/null 2>&1 || break
        [ -n "$(ls /run/user/0 2>/dev/null | grep -E '^wayland-[0-9]+$')" ] && break
        i=$((i + 1)); sleep 1
    done
    WL_SOCK=$(ls /run/user/0 2>/dev/null | grep -E '^wayland-[0-9]+$' | head -n1)
    log "  weston pid=$(pgrep -x weston | tr '\n' ' ')（等 ${i}s）socket=${WL_SOCK:-NONE}"
    grep -nE "Output 'Virtual-1'|desktop-shell|ERROR|fatal" /tmp/weston.log > /dev/console 2>&1
else
    log "  !! libseat-shim.so 缺失"
fi

# ---------------------------------------------------------------- 5. Chromium
log "===== 4. Chromium（B 模式：--in-process-gpu）====="
export XDG_RUNTIME_DIR=/run/user/0
export WAYLAND_DISPLAY="${WL_SOCK:-wayland-0}"
log "  WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
mkdir -p /tmp/chromium-baseline /root/.config/chromium
: > "$CHROME_LOG"

chromium --ozone-platform=wayland --no-sandbox --disable-gpu --disable-dev-shm-usage \
    --enable-logging=stderr --v=1 \
    --user-data-dir=/tmp/chromium-baseline \
    --in-process-gpu --use-gl=swiftshader --disable-gpu-sandbox \
    --disable-features=Vulkan --disable-background-networking --disable-component-update \
    --no-first-run \
    file:///usr/share/html-test/index.html >> "$CHROME_LOG" 2>&1 &
CPID=$!
log "  browser pid=$CPID"

# 让它跑 200s，期间每 20s 记一次进程格局（子进程可能短命，采样要密）
j=0
while [ "$j" -lt 200 ]; do
    kill -0 "$CPID" 2>/dev/null || break
    {
        echo "=== +${j}s ==="
        echo "browser:  $(pgrep -f 'lib/chromium/chromium' | tr '\n' ' ')"
        echo "zygote:   $(pgrep -f 'type=zygote' | tr '\n' ' ')"
        echo "gpu:      $(pgrep -f 'type=gpu' | tr '\n' ' ')"
        echo "utility:  $(pgrep -f 'type=utility' | tr '\n' ' ')"
        echo "renderer: $(pgrep -f 'type=renderer' | tr '\n' ' ')"
    } >> "$LOG" 2>&1
    j=$((j + 20)); sleep 20
done

if kill -0 "$CPID" 2>/dev/null; then
    log "  browser 仍在运行（${j}s）✓"
    BROWSER_ALIVE=1
else
    wait "$CPID"; rc=$?
    log "  browser 已退出 rc=$rc（存活约 ${j}s）"
    BROWSER_ALIVE=0
fi

# ---------------------------------------------------------------- 6. 全局计数（关键）
# ★ 教训：判断"某类日志是否消失"必须全局 grep -c，绝不能看 tail 窗口。
log "===== 5. 全局计数（不依赖 tail 窗口）====="
log "  chromium.log 总行数: $(wc -l < "$CHROME_LOG" 2>/dev/null)"
for pat in 'Network service crashed' 'NO_NEW_PRIVS' 'pthread_getschedparam failed' \
           'GPU process isn' 'FATAL' 'Aborted' 'landlock_create_ruleset' \
           'Failed to connect to Wayland' 'LaunchProcess'; do
    log "  COUNT [$pat] = $(grep -c "$pat" "$CHROME_LOG" 2>/dev/null)"
done

log "  最终进程格局:"
log "    browser =[$(pgrep -f 'lib/chromium/chromium' | tr '\n' ' ')]"
log "    zygote  =[$(pgrep -f 'type=zygote' | tr '\n' ' ')]"
log "    gpu     =[$(pgrep -f 'type=gpu' | tr '\n' ' ')]"
log "    utility =[$(pgrep -f 'type=utility' | tr '\n' ' ')]"
log "    renderer=[$(pgrep -f 'type=renderer' | tr '\n' ' ')]"
log "  renderer 计数: $(pgrep -cf 'type=renderer')"

log "  ==== chromium.log 前 60 行（子进程早期输出最可能在这里）===="
head -60 "$CHROME_LOG" > /dev/console 2>&1
log "  ==== chromium.log 尾 60 行 ===="
tail -60 "$CHROME_LOG" > /dev/console 2>&1
log "  ==== 错误行 ===="
grep -nE "ERROR|FATAL|Failed|Aborted|Unimplemented|prctl" "$CHROME_LOG" | head -40 > /dev/console 2>&1

# ---------------------------------------------------------------- 7. watcher
log "===== 6. watcher ====="
n=0
while [ "$n" -lt 60 ]; do
    {
        echo "=== $(date 2>/dev/null) uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null) (+$((n * 30))s) ==="
        echo "weston:        $(pgrep -x weston | tr '\n' ' ')"
        echo "desktop-shell: $(pgrep -f weston-desktop-shell | tr '\n' ' ')"
        echo "browser:       $(pgrep -f 'lib/chromium/chromium' | tr '\n' ' ')"
        echo "gpu:           $(pgrep -f 'type=gpu' | tr '\n' ' ')"
        echo "renderer:      $(pgrep -f 'type=renderer' | tr '\n' ' ')"
        echo "crash 计数:    $(grep -c 'Network service crashed' "$CHROME_LOG" 2>/dev/null)"
        ps 2>/dev/null | grep -E 'weston|chromium|seatd' | grep -v grep | head -10
    } >> "$WATCH" 2>&1
    sync
    n=$((n + 1))
    sleep 30
done
log "watcher 结束（$n 轮）"
sync
sync
log "autorun_nnp done"
