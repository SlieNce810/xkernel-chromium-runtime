#!/bin/sh
# autorun_weston13.sh —— 阶段3 收尾（二）：外部客户端连上 Weston
#
# weston12 的发现：socket 实际是 **wayland-1**（不是 wayland-0）——
# 之前几轮"没有 socket"是**检查写错了名字**，不是系统问题。
# （另有候选缺口：本内核 procfs 的 /proc/<pid>/{status,wchan,syscall} 返回空。）
#
# 本轮：
#   A. 启动 Weston（无 shim，同 weston11/12 配置）
#   B. **动态发现** socket（find $XDG_RUNTIME_DIR -type s -name 'wayland-*'）
#   C. 用真实外部客户端验证：weston-simple-shm（**不预置 WAYLAND_SOCKET**，走文件 socket）
#      + weston-clickdot / weston-smoke 之一作为第二例
#   D. 若 C 成功，直接试 Chromium（阶段4 的入口）—— 只做"能否连上 + 起进程"的最小验证
LOG=/root/weston13.log
: > "$LOG"
RD=/run/user/0
WLOG=/root/weston13-weston.log

log() {
    echo "[weston13] $*" > /dev/console 2>/dev/null
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
rm -f /run/seatd.sock "$RD"/wayland-* 2>/dev/null
SEATD_VTBOUND=0 seatd -l info > /root/weston13-seatd.log 2>&1 &
SD=$!
sleep 1
log "seatd alive=$([ -d /proc/$SD ] && echo yes || echo no)"

log "===== A. Weston（无 shim）====="
env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 \
    LIBSEAT_BACKEND=seatd SEATD_SOCK=/run/seatd.sock \
    weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
    --seat=seat0 --continue-without-input --idle-time=0 --debug \
    --log="$WLOG" > /root/weston13-stdout.log 2>&1 &
W=$!
sleep 6
log "weston_alive=$([ -d /proc/$W ] && echo yes || echo no)"
grep -aE "using /dev/dri/card0|Output .* enabled|Failed to find primary|shadow framebuffer|video modes" "$WLOG" | sed 's/^/  /' >> "$LOG" 2>&1

log "===== B. 动态发现 socket ====="
SOCKPATH=$(find "$RD" -maxdepth 1 -type s -name 'wayland-*' 2>/dev/null | head -1)
log "socket = [${SOCKPATH:-无}]"
ls -la "$RD" >> "$LOG" 2>&1
if [ -z "$SOCKPATH" ]; then
    log "!! 仍无 socket —— 记录现场后结束"
fi

log "===== C. 外部客户端（走文件 socket，不设 WAYLAND_SOCKET）====="
if [ -n "$SOCKPATH" ]; then
    WDISPLAY=$(basename "$SOCKPATH")
    WDIR=$(dirname "$SOCKPATH")
    log "以 XDG_RUNTIME_DIR=$WDIR WAYLAND_DISPLAY=$WDISPLAY 启动客户端"
    XDG_RUNTIME_DIR="$WDIR" WAYLAND_DISPLAY="$WDISPLAY" \
        run_guard /root/weston13-shm.out 25 weston-simple-shm
    rc=$?
    log "weston-simple-shm rc=$rc（0 或 124=仍在跑为成功；非 0 且很快退出=失败）"
    cat /root/weston13-shm.out >> "$LOG" 2>&1
    [ "$rc" = "0" ] && log "EXTERNAL_CLIENT_OK"
    if [ "$rc" != "0" ]; then
        log "EXTERNAL_CLIENT_FAIL"
    fi
else
    log "EXTERNAL_CLIENT_SKIP（无 socket）"
fi

log "===== D. Chromium 最小连通性（阶段4 入口）====="
if [ -n "$SOCKPATH" ] && command -v chromium >/dev/null 2>&1; then
    WDISPLAY=$(basename "$SOCKPATH")
    WDIR=$(dirname "$SOCKPATH")
    XDG_RUNTIME_DIR="$WDIR" WAYLAND_DISPLAY="$WDISPLAY" \
        run_guard /root/weston13-chromium.out 40 \
        chromium --ozone-platform=wayland --no-sandbox --disable-gpu \
                 --disable-dev-shm-usage --user-data-dir=/root/cr13 \
                 file:///usr/share/html-test/index.html
    log "chromium rc=$?"
    head -20 /root/weston13-chromium.out >> "$LOG" 2>&1
    grep -aE "using /dev/dri/card0|Output .* enabled" "$WLOG" >> "$LOG" 2>&1
else
    log "(跳过 Chromium：无 socket 或未安装)"
fi

log "[WESTON13_SUM] socket=[${SOCKPATH:-无}] weston_alive=$([ -d /proc/$W ] && echo yes || echo no)"

n=0
while [ "$n" -lt 6 ]; do
    sync
    n=$((n + 1))
    sleep 20
done
kill "$W" 2>/dev/null
kill "$SD" 2>/dev/null
log "weston13 收尾"
sync
