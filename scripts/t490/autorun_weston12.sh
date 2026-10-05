#!/bin/sh
# autorun_weston12.sh —— 阶段3 收尾：定位 Wayland socket + 验证外部客户端可连接
#
# weston11 已证明的事实（本轮的出发点）：
#   · `using /dev/dri/card0`（无 shim）+ `libseat ... backend 'seatd'`
#   · `Output 'Virtual-1' enabled with head(s) Virtual-1`  ← 输出启用（历史首次）
#   · 截图 1280×800 且有内容（灰褐渐变背景），帧间 changed_pixels 86~164（时钟重绘）⇒ 显示链路活的
# 本轮要回答（Chromium 的先决条件）：
#   1. Weston 的 Wayland socket 到底创建在哪？（weston11 里按 $XDG_RUNTIME_DIR/wayland-0 没找到，
#      但 Weston 内置客户端是靠 WAYLAND_SOCKET 传 fd 连上的 —— 外部客户端需要文件 socket）
#   2. 外部客户端（weston-info / weston-simple-shm）能否连上并创建 surface
#   3. 若 Weston 阻塞，阻塞在哪个 syscall（/proc/<pid>/syscall）
LOG=/root/weston12.log
: > "$LOG"
RD=/run/user/0
WLOG=/root/weston12-weston.log

log() {
    echo "[weston12] $*" > /dev/console 2>/dev/null
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

mkdir -p "$RD" 2>/dev/null; chmod 700 "$RD" 2>/dev/null
rm -f /run/seatd.sock "$RD"/wayland-* "$RD"/wayland-*.lock 2>/dev/null
SEATD_VTBOUND=0 seatd -l info > /root/weston12-seatd.log 2>&1 &
SD=$!
sleep 1
log "seatd alive=$([ -d /proc/$SD ] && echo yes || echo no)"

log "===== A. 启动 Weston（无 shim）====="
env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 \
    LIBSEAT_BACKEND=seatd SEATD_SOCK=/run/seatd.sock \
    weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
    --seat=seat0 --continue-without-input --idle-time=0 --debug \
    --log="$WLOG" > /root/weston12-stdout.log 2>&1 &
W=$!
sleep 6

log "===== B. socket 与运行时目录实况 ====="
log "XDG_RUNTIME_DIR=[$RD]  weston_alive=$([ -d /proc/$W ] && echo yes || echo no)"
log "--- ls -la $RD ---"; ls -la "$RD" >> "$LOG" 2>&1
log "--- ls -la /run（前 20）---"; ls -la /run >> "$LOG" 2>&1
log "--- find /run -maxdepth 3 -name 'wayland*' ---"
find /run -maxdepth 3 -name 'wayland*' >> "$LOG" 2>&1
log "--- Weston 的 fd 表（前 25）---"
ls -l /proc/$W/fd 2>/dev/null | head -25 >> "$LOG" 2>&1

log "===== C. Weston 是否阻塞（/proc 事实）====="
log "status: $(grep -E '^State|^Threads' /proc/$W/status 2>/dev/null | tr '\n' ' ')"
log "wchan : $(cat /proc/$W/wchan 2>/dev/null)"
log "syscall: $(cat /proc/$W/syscall 2>/dev/null)"

log "===== D. 外部客户端连接测试 ====="
SOCK=""
for cand in "$RD/wayland-0" /run/wayland-0 /tmp/wayland-0; do
    [ -S "$cand" ] && SOCK="$cand" && break
done
log "找到的 socket: [${SOCK:-无}]"
if command -v weston-info >/dev/null 2>&1; then
    if [ -n "$SOCK" ]; then
        XDG_RUNTIME_DIR=$(dirname "$SOCK") WAYLAND_DISPLAY=$(basename "$SOCK") \
            run_guard /root/weston12-info.out 30 weston-info
    else
        XDG_RUNTIME_DIR="$RD" run_guard /root/weston12-info.out 30 weston-info
    fi
    log "weston-info rc=$?（0 = 外部客户端连接成功）"
    head -12 /root/weston12-info.out >> "$LOG" 2>&1
else
    log "(guest 无 weston-info)"
fi

if [ -n "$SOCK" ]; then
    XDG_RUNTIME_DIR=$(dirname "$SOCK") WAYLAND_DISPLAY=$(basename "$SOCK") \
        run_guard /root/weston12-shm.out 30 weston-simple-shm
    log "weston-simple-shm rc=$?（0/124 = 客户端活着）"
else
    log "!! 未找到 socket ⇒ 外部客户端无法连接（Chromium 同理会失败）"
fi
head -6 /root/weston12-shm.out >> "$LOG" 2>&1

log "--- weston 日志尾部 ---"
tail -12 "$WLOG" >> "$LOG" 2>&1
log "[WESTON12_SUM] socket=[${SOCK:-无}] alive=$([ -d /proc/$W ] && echo yes || echo no)"

kill "$W" 2>/dev/null
kill "$SD" 2>/dev/null
log "weston12 收尾"
sync
