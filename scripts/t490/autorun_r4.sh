#!/bin/sh
# autorun_r4.sh —— 兼容性体检轮（为 renderer 阻塞找"下一层缺口"）
#
# 已知（r2/r3 实测）
#   ① P3 之后子进程能 exec 了；C 段标准多进程下 GPU 子进程仍崩：
#        GPU process exited unexpectedly: exit_code=48896   ← 48896 = 191<<8
#      即子进程**在自己的 main() 里以 191 静默退出**（无任何 ERROR 行、内核无 panic/OOM）
#   ② D 段（--in-process-gpu + --disable-features=SegmentationPlatform,…）**导航真的开始了**：
#        FileURLLoader::Start: file:///usr/share/html-test/index.html
#      这是 nnp 轮从未出现过的行 → 浏览器随后约 60s 时以 191 退出
#   ③ crashpad 报 `crashpad/util/linux/socket.cc:177 missing credentials` → 疑 SO_PEERCRED
#
# 本轮做两件事
#   A. `/compatprobe` 逐项体检 Chromium/Mojo/crashpad 依赖但 x-kernel 未必实现的接口
#      （SO_PEERCRED / SEQPACKET / SO_SNDBUF / MSG_NOSIGNAL / memfd_create / shm_open /
#        eventfd / timerfd / epoll / signalfd / getrandom / madvise / PDEATHSIG / fd 继承）
#      —— 用 errno 登记缺口，不靠猜
#   B. 复跑 D 段配置（200s，每 10s 采样）：确认"导航开始"可复现，并尽量在 191 退出前截到画面

LOG=/root/r4.log
: > "$LOG"
log() {
    echo "[r4] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}
tl() { "$@" 2>&1 | tee -a "$LOG" /dev/console; }
psnode() { pgrep -f "type=$1" | tr '\n' ' '; }

log "start uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null) chromium=$(chromium --version 2>&1 | head -1)"

# ---------------------------------------------------------------- A. 探针
for p in /compatprobe /nvprobe; do
    if [ -x "$p" ]; then
        log "===== 探针 $p ====="
        tl "$p"
        log "----- $p 判定行 -----"
        grep -aE "^\[CP\]|^\[CPSUM\]|^\[NV\]|^\[RESULT\]" "$LOG" | tail -40 > /dev/console 2>&1
    fi
done

# ---------------------------------------------------------------- B. weston
log "===== weston ====="
mkdir -p /run/udev/data /sys/dev/char/226:0/device /sys/devices/simpledrm /sys/bus/faux 2>/dev/null
cat > /run/udev/data/c13:1 <<'EOF'
E:ID_INPUT=1
E:ID_INPUT_KEYBOARD=1
E:ID_SEAT=seat0
EOF
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

# ---------------------------------------------------------------- C. 复跑 D 段配置
log "===== Chromium（D 段配置复跑：--in-process-gpu + disable-features）====="
CL=/root/r4-chrome.log
: > "$CL"
chromium --ozone-platform=wayland --no-sandbox --disable-dev-shm-usage \
    --enable-logging=stderr --v=1 --user-data-dir=/tmp/chromium-baseline \
    --in-process-gpu --use-gl=swiftshader --disable-gpu-sandbox \
    --disable-features=Vulkan,SegmentationPlatform,OptimizationGuideModelDownloading,OptimizationHints,WebAppProvider,InterestFeedContentSuggestions \
    --no-first-run --no-default-browser-check --disable-component-update \
    --disable-background-networking --disable-sync --disable-extensions --disable-crash-reporter \
    file:///usr/share/html-test/index.html >> "$CL" 2>&1 &
CP=$!
log "  browser pid=$CP"
k=0
while [ "$k" -lt 200 ]; do
    [ -d /proc/$CP ] || break
    {
        echo "--- +${k}s browser=[$CP] zygote=[$(psnode zygote)] gpu=[$(psnode gpu)] utility=[$(psnode utility)] renderer=[$(psnode renderer)]"
    } >> "$LOG" 2>&1
    k=$((k + 10)); sleep 10
done
if [ -d /proc/$CP ]; then
    log "  仍在运行（${k}s）✓ renderer=[$(psnode renderer)]"
else
    wait "$CP"; rc=$?
    log "  已退出 rc=$rc（存活约 ${k}s）"
fi
for pat in 'Network service crashed' 'NO_NEW_PRIVS' 'RenderProcessHost' 'type=renderer' 'renderer' 'GPU process isn' 'FATAL' 'Unimplemented'; do
    log "  COUNT [$pat] = $(grep -c "$pat" "$CL" 2>/dev/null)"
done
log "  ==== 导航/加载关键行 ===="
grep -nE "FileURLLoader|Navigation|navigation|DidStart|Commit|BindInterface" "$CL" | head -20 > /dev/console 2>&1
log "  ==== 尾 30 行 ===="; tail -30 "$CL" > /dev/console 2>&1
log "  ==== 错误行 ===="; grep -nE "ERROR|FATAL|Failed|Aborted" "$CL" | head -25 > /dev/console 2>&1

log "===== watcher ====="
n=0
while [ "$n" -lt 30 ]; do
    { echo "=== $(date 2>/dev/null) (+$((n * 30))s) weston=$(pgrep -x weston | tr '\n' ' ') browser=$(pgrep -f 'lib/chromium/chromium' | tr '\n' ' ') renderer=[$(psnode renderer)] ==="; } >> /root/r4-watch.log 2>&1
    sync; n=$((n + 1)); sleep 30
done
log "autorun_r4 done"; sync; sync
