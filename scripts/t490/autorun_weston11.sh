#!/bin/sh
# autorun_weston11.sh —— 撤销两处误修后的关键验证轮
#
# 本轮之前刚发生的事实（都在证据里）：
#   1. weston_sim 证明：Weston 视角 **每个属性都读不到名字** ⇒ plane->type=COUNT ⇒ 静默丢弃
#   2. proptwostage + iocspy 证明：真实 libdrm 的 drmModeGetProperty 发 **nr=0xAA(size=64)**，
#      而内核（p2「缺口A修复」后）只认 **0xA8** ⇒ errno=95
#   3. uapi 头文件逐行核对：0xA8=ATTACHMODE(deprecated)、0xAA=GETPROPERTY、0xAC=GETPROPBLOB
#      ⇒ **HEAD 原始值才是对的**，p2 的替换是误修（与缺口 D 同类）
#   4. p2_revert.sh + p3_revert.sh 已执行 ⇒ card0.rs 与 HEAD **逐字节一致**
#
# 本轮的判据（顺序不可颠倒：先探针、后 Weston）
#   A. weston_sim：应给出 `dropped_by_weston=0` / `verdict=SIM_OK`
#   B. 真 Weston（无 shim + 真实 sysfs + 真实 seatd）：
#        L1 设备发现 → L2 plane 关卡（这句必须消失）→ L3 output → L4 客户端绘制
#
# 仍带 `--continue-without-input`：输入（evdev/libinput）属阶段 3 后半段，尚未打通。
LOG=/root/weston11.log
: > "$LOG"
RD=/run/user/0
WLOG=/root/weston11-weston.log

log() {
    echo "[weston11] $*" > /dev/console 2>/dev/null
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

log "===== A. weston_sim（复现 Weston 的 plane 创建）====="
if [ -x /weston_sim ]; then
    run_guard /root/weston11-sim.out 120 /weston_sim
    log "weston_sim rc=$?"
    grep -aE '^\[SIM\] (driver|drmModeGetPlane OK|drmModeObjectGetProperties OK|type 属性)|^\[SIM_SUM\]|^\[PROBE_EXIT\]' \
        /root/weston11-sim.out | sed 's/^/  /' >> "$LOG" 2>&1
    grep -aE '^\[SIM_SUM\]|^\[PROBE_EXIT\]' /root/weston11-sim.out > /dev/console 2>&1
else
    log "!! /weston_sim 未注入"
fi

log "===== B. 真 Weston（无 shim）====="
log "LD_PRELOAD=[${LD_PRELOAD:-<空>}]"
mkdir -p "$RD" 2>/dev/null; chmod 700 "$RD" 2>/dev/null
rm -f /run/seatd.sock "$RD"/wayland-* "$RD"/wayland-*.lock 2>/dev/null
SEATD_VTBOUND=0 seatd -l info > /root/weston11-seatd.log 2>&1 &
SD=$!
sleep 1
log "seatd alive=$([ -d /proc/$SD ] && echo yes || echo no) socket=$([ -S /run/seatd.sock ] && echo yes || echo no)"

env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 \
    LIBSEAT_BACKEND=seatd SEATD_SOCK=/run/seatd.sock \
    weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
    --seat=seat0 --continue-without-input --idle-time=0 --debug \
    --log="$WLOG" > /root/weston11-stdout.log 2>&1 &
W=$!
i=0
while [ "$i" -lt 250 ]; do
    [ -S "$RD/wayland-0" ] && break
    [ -d /proc/$W ] || break
    i=$((i + 1)); sleep 0.2
done

ALIVE=no; [ -d /proc/$W ] && ALIVE=yes
SOCK=no;  [ -S "$RD/wayland-0" ] && SOCK=yes
log "启动后：weston_alive=$ALIVE wayland_socket=$SOCK（等待 ${i}×0.2s）"

L1=no; L2=none; L3=no
grep -aq "using /dev/dri/card0" "$WLOG" && L1=yes
grep -aq "Failed to find primary plane" "$WLOG" && L2=FAIL || L2=PASS
grep -aqE "Output .* enabled|repaint|VSync|modeset|scanout" "$WLOG" && L3=yes
log "分层判据：L1=$L1  L2(plane 关卡)=$L2  L3(output)=$L3"

log "--- weston 日志全文（本轮很短，全收）---"
cat "$WLOG" >> "$LOG" 2>&1
tail -30 "$WLOG" > /dev/console 2>&1

L4=no
if [ "$L1" = "yes" ] && command -v weston-simple-shm >/dev/null 2>&1; then
    env XDG_RUNTIME_DIR="$RD" WAYLAND_DISPLAY=wayland-0 \
        weston-simple-shm > /root/weston11-simple-shm.log 2>&1 &
    SH=$!
    sleep 3
    ALIVE2=no; [ -d /proc/$SH ] && ALIVE2=yes
    log "weston-simple-shm pid=$SH 存活=$ALIVE2"
    head -6 /root/weston11-simple-shm.log >> "$LOG" 2>&1
    [ "$ALIVE2" = "yes" ] && L4=yes
    grep -aiE "client|commit|release|buffer" "$WLOG" | tail -10 >> "$LOG" 2>&1
fi

log "[WESTON11_SUM] L1=$L1 L2=$L2 L3=$L3 L4=$L4 alive=$ALIVE verdict=DIAG"

n=0
while [ "$n" -lt 10 ]; do
    A=no; [ -d /proc/$W ] && A=yes
    S=no; [ -S "$RD/wayland-0" ] && S=yes
    log "+$((n * 30))s weston_alive=$A socket=$S log_lines=$(wc -l < "$WLOG" 2>/dev/null)"
    sync
    n=$((n + 1))
    sleep 30
done

kill "$SD" 2>/dev/null
log "weston11 收尾（seatd 已停）"
sync
