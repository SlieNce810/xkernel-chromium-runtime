#!/bin/sh
# autorun_chromium2.sh —— 阶段4：换掉"GPU 子进程不可用即自杀"的死路
#
# cr1 轮的结论（机器证据）
#   FATAL:content/browser/gpu/gpu_data_manager_impl_private.cc:415] GPU process isn't usable. Goodbye.
#   —— GPU 子进程连续 6 次 "launch failed: error_code=1002" 后 Chromium 主动 FATAL 退出（存活约 50s）。
#   注意：这与 `--disable-gpu` 并不矛盾 —— Ozone/Wayland 下它仍会为 display compositor 起 GPU 进程。
#
# 本轮策略
#   1. 用 `--in-process-gpu` 让 GPU/display-compositor 代码跑在**浏览器进程内**（不引入 --single-process，
#      renderer 仍是独立进程，符合验收对多进程的要求）
#   2. 同时采集 GPU 子进程失败的**可判读事实**（退出码/信号/日志），为"是否值得当内核缺口修"留判据
#   3. 观察 Weston 日志是否出现客户端 surface/commit（= 窗口真的映射了）
LOG=/root/cr2.log
: > "$LOG"
RD=/run/user/0
WLOG=/root/cr2-weston.log
PAGE="file:///usr/share/html-test/index.html"

log() {
    echo "[cr2] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}

mkdir -p "$RD" 2>/dev/null; chmod 700 "$RD" 2>/dev/null
rm -rf /root/cr2-profile 2>/dev/null
rm -f /run/seatd.sock "$RD"/wayland-* 2>/dev/null
SEATD_VTBOUND=0 seatd -l info > /root/cr2-seatd.log 2>&1 &
SD=$!
sleep 1

log "===== A. Weston（无 shim）====="
env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 \
    LIBSEAT_BACKEND=seatd SEATD_SOCK=/run/seatd.sock \
    weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
    --seat=seat0 --continue-without-input --idle-time=0 --debug \
    --log="$WLOG" > /root/cr2-weston-stdout.log 2>&1 &
W=$!
sleep 6
SOCKPATH=$(find "$RD" -maxdepth 1 -type s -name 'wayland-*' 2>/dev/null | head -1)
WDIR=$(dirname "$SOCKPATH"); WDISPLAY=$(basename "$SOCKPATH")
log "weston_alive=$([ -d /proc/$W ] && echo yes || echo no) socket=[$SOCKPATH]"

log "===== B. Chromium（--in-process-gpu）====="
env XDG_RUNTIME_DIR="$WDIR" WAYLAND_DISPLAY="$WDISPLAY" \
    chromium --ozone-platform=wayland --in-process-gpu --disable-gpu-sandbox \
    --no-sandbox --disable-dev-shm-usage \
    --user-data-dir=/root/cr2-profile \
    --no-first-run --no-default-browser-check --disable-sync \
    --window-size=1280,800 --start-fullscreen --kiosk \
    --enable-logging=stderr \
    "$PAGE" > /root/cr2-chromium.log 2>&1 &
C=$!
log "chromium pid=$C"

n=0
while [ "$n" -lt 20 ]; do
    A=no; [ -d /proc/$C ] && A=yes
    W_LINES=$(grep -ac . "$WLOG" 2>/dev/null)
    log "  +$((n * 15))s chromium_alive=$A weston_log_lines=$W_LINES"
    sync
    n=$((n + 1))
    sleep 15
done

C_ALIVE=no; [ -d /proc/$C ] && C_ALIVE=yes
log "===== C. 分层事实 ====="
log "chromium_alive=$C_ALIVE"
log "--- Weston 日志尾部（是否出现客户端 surface/commit）---"
tail -25 "$WLOG" >> "$LOG" 2>&1
log "--- Weston 里 client/surface 相关行 ---"
grep -aiE "client|surface|commit|attach|release|buffer|shell" "$WLOG" | tail -20 >> "$LOG" 2>&1
log "--- Chromium 关键行（末尾 25）---"
tail -25 /root/cr2-chromium.log >> "$LOG" 2>&1
log "--- 是否再出现 GPU FATAL ---"
grep -acE "GPU process isn't usable" /root/cr2-chromium.log 2>/dev/null >> "$LOG" 2>&1
log "--- 导航/渲染相关 ---"
grep -aiE "FileURLLoader|navigation|DidStart|DidFinish|commit|renderer|TaskManager" /root/cr2-chromium.log | tail -15 >> "$LOG" 2>&1

log "[CR2_SUM] chromium_alive=$C_ALIVE weston_alive=$([ -d /proc/$W ] && echo yes || echo no) socket=$SOCKPATH"

log "--- 收尾前保持 60s 供 screendump ---"
sleep 60
kill "$C" 2>/dev/null
kill "$W" 2>/dev/null
kill "$SD" 2>/dev/null
log "chromium2 收尾"
sync
