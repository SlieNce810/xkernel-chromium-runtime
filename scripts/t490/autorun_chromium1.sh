#!/bin/sh
# autorun_chromium1.sh —— 阶段 4：让 Chromium 显示官方首页（无 shim 全链路）
#
# 前置事实（本轮之前已各自独立验证）
#   · 内核：GETPLANE/GETPROPERTY 均为 uapi 编号（report/32、report/33）⇒ 标准 libdrm 全通
#   · 设备发现：内核 sysfs 投射 ⇒ 真实 libudev 通过（std3 轮）
#   · 会话：真实 seatd + libseat 拿到可用 DRM FD（std3 轮）
#   · 显示：Weston 无 shim 启用输出（1280×800）并在重绘（weston11 轮）
#   · 客户端：外部 Wayland 客户端可经文件 socket 连上（weston13 轮）
#
# 本轮要拿到的东西（阶段4 放行条件）
#   A. 环境自证（字体/库/入口页/内核指纹）
#   B. Chromium 在 Weston 会话里起来并**映射窗口**（Weston 日志出现 client surface/commit）
#   C. QEMU screendump 出现**官方首页内容**（由宿主侧像素判据给出）
#   D. 失败时留下可判读的分层事实（导航/渲染/绘制到哪一层）
LOG=/root/cr1.log
: > "$LOG"
RD=/run/user/0
WLOG=/root/cr1-weston.log
PAGE="file:///usr/share/html-test/index.html"

log() {
    echo "[cr1] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}

run_guard() {
    out="$1"; lim="$2"; shift 2
    "$@" > "$out" 2>&1 &
    p=$!
    j=0
    while [ "$j" -lt "$lim" ]; do
        [ -d /proc/$p ] || break
        j=$((j + 1)); sleep 1
    done
    if [ -d /proc/$p ]; then
        echo "!! HUNG ${lim}s -> kill -9" >> "$out"
        kill -9 "$p" 2>/dev/null
        return 124
    fi
    wait "$p" 2>/dev/null
    return $?
}

log "===== A. 环境自证 ====="
log "kernel: $(uname -srm)"
log "入口页: $PAGE"
ls -la /usr/share/html-test/ >> "$LOG" 2>&1
log "字体目录: $(ls /usr/share/fonts 2>/dev/null | head -5 | tr '\n' ' ')"
if command -v fc-list >/dev/null 2>&1; then
    log "fc-list 数量: $(fc-list 2>/dev/null | wc -l)"
    fc-list 2>/dev/null | head -3 >> "$LOG" 2>&1
else
    log "(无 fc-list)"
fi
chromium --version 2>/dev/null | head -1 >> "$LOG" 2>&1

mkdir -p "$RD" 2>/dev/null; chmod 700 "$RD" 2>/dev/null
rm -rf /root/cr1-profile 2>/dev/null
rm -f /run/seatd.sock "$RD"/wayland-* 2>/dev/null
SEATD_VTBOUND=0 seatd -l info > /root/cr1-seatd.log 2>&1 &
SD=$!
sleep 1

log "===== B. Weston（无 shim）====="
env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 \
    LIBSEAT_BACKEND=seatd SEATD_SOCK=/run/seatd.sock \
    weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
    --seat=seat0 --continue-without-input --idle-time=0 --debug \
    --log="$WLOG" > /root/cr1-weston-stdout.log 2>&1 &
W=$!
sleep 6
SOCKPATH=$(find "$RD" -maxdepth 1 -type s -name 'wayland-*' 2>/dev/null | head -1)
WDIR=$(dirname "$SOCKPATH"); WDISPLAY=$(basename "$SOCKPATH")
log "weston_alive=$([ -d /proc/$W ] && echo yes || echo no)  socket=[$SOCKPATH]"
grep -aE "using /dev/dri/card0|Output .* enabled|shadow framebuffer" "$WLOG" | sed 's/^/  /' >> "$LOG" 2>&1

log "===== C. Chromium（Wayland/Ozone，软件渲染，kiosk）====="
if [ -n "$SOCKPATH" ] && command -v chromium >/dev/null 2>&1; then
    env XDG_RUNTIME_DIR="$WDIR" WAYLAND_DISPLAY="$WDISPLAY" \
        chromium --ozone-platform=wayland --no-sandbox --disable-gpu \
        --disable-dev-shm-usage --disable-gpu-compositing \
        --user-data-dir=/root/cr1-profile \
        --no-first-run --no-default-browser-check --disable-sync \
        --window-size=1280,800 --start-fullscreen --kiosk \
        --enable-logging=stderr \
        "$PAGE" > /root/cr1-chromium.log 2>&1 &
    C=$!
    log "chromium pid=$C"

    n=0
    while [ "$n" -lt 16 ]; do
        A=no; [ -d /proc/$C ] && A=yes
        log "  +$((n * 15))s chromium_alive=$A（Weston: $(grep -ac . "$WLOG") 行）"
        sync
        n=$((n + 1))
        sleep 15
    done

    log "===== D. 分层事实 ====="
    log "--- Weston 日志里与 client/surface/commit 相关的行 ---"
    grep -aiE "client|surface|commit|release|buffer|attach|map" "$WLOG" | tail -30 >> "$LOG" 2>&1
    log "--- Chromium 日志关键行 ---"
    grep -aiE "wayland|ozone|gl_|renderer|GPU|navigation|FileURL|surface|window|Failed|ERROR" /root/cr1-chromium.log \
        | tail -40 >> "$LOG" 2>&1
    log "--- Chromium 进程类型直方图（是否有 renderer/gpu 子进程）---"
    grep -aoE "type=[a-z_-]+|type=\(browser/none\)" /root/cr1-chromium.log 2>/dev/null | sort | uniq -c | sort -rn >> "$LOG" 2>&1

    log "--- 收尾前 screendump 前先让画面稳定 30s ---"
    sleep 30
    C_ALIVE=no; [ -d /proc/$C ] && C_ALIVE=yes
    log "[CR1_SUM] weston_alive=$([ -d /proc/$W ] && echo yes || echo no) chromium_alive=$C_ALIVE socket=$SOCKPATH"
    kill "$C" 2>/dev/null
else
    log "!! 跳过 Chromium（socket 缺失或未安装）"
    log "[CR1_SUM] skipped"
fi

kill "$W" 2>/dev/null
kill "$SD" 2>/dev/null
log "chromium1 收尾"
sync
