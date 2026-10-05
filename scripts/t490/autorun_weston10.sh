#!/bin/sh
# autorun_weston10.sh —— 定位「plane 在哪一步被丢弃」：模拟探针 + 全量 ioctl 跟踪
#
# 背景：weston9（无 shim）已经把链路推到
#     Seat opened with backend 'seatd' → using /dev/dri/card0 → head found
#     → Failed to find primary plane for output Virtual-1
# 而 Weston 在这个失败点上有**多条静默路径**（create_sprites() 两处裸 continue、
# drm_plane_create() 两条不打日志的 goto），日志看不到"哪一步丢的"。
#
# 本轮两件互相印证的事：
#   A. /weston_sim —— 用真实 libdrm 在 Weston 的位置上把它的每一步***原样跑一遍***，
#      逐步打印判读（属性名/枚举值/blob 迭代/重复修饰符）⇒ 直接给出"被丢弃的那一步"
#   B. 用**只观测、不改行为**的 LD_PRELOAD 跟踪器（iocspy，不伪造任何数据）
#      抓 Weston 自己的 DRM ioctl 序列 ⇒ 与 A 的结论对照
#
# 注意：iocspy 不是 shim —— 它只把请求值与返回值打成一行日志，不修改任何参数/返回值。
LOG=/root/weston10.log
: > "$LOG"
RD=/run/user/0

log() {
    echo "[weston10] $*" > /dev/console 2>/dev/null
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

log "===== A. weston_sim：复现 Weston 的 plane 创建逻辑 ====="
if [ -x /weston_sim ]; then
    run_guard /root/weston10-sim.out 120 /weston_sim
    log "weston_sim rc=$?"
    grep -aE '^\[SIM' /root/weston10-sim.out | sed 's/^/  /' >> "$LOG" 2>&1
    # 关键结论行同时打上 console，便于快速判读
    grep -aE '^\[SIM_SUM\]|^\[PROBE_EXIT\]' /root/weston10-sim.out > /dev/console 2>&1
else
    log "!! /weston_sim 未注入"
fi

log "===== B. 带 ioctl 跟踪跑一轮 Weston（只观测）====="
mkdir -p "$RD" 2>/dev/null; chmod 700 "$RD" 2>/dev/null
rm -f /run/seatd.sock "$RD"/wayland-* "$RD"/wayland-*.lock 2>/dev/null
SEATD_VTBOUND=0 seatd -l info > /root/weston10-seatd.log 2>&1 &
SD=$!
sleep 1
log "seatd alive=$([ -d /proc/$SD ] && echo yes || echo no) socket=$([ -S /run/seatd.sock ] && echo yes || echo no)"

if [ -f /iocspy.so ] && command -v weston >/dev/null 2>&1; then
    env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 \
        LIBSEAT_BACKEND=seatd SEATD_SOCK=/run/seatd.sock \
        LD_PRELOAD=/iocspy.so \
        weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
        --seat=seat0 --continue-without-input --idle-time=0 --debug \
        --log=/root/weston10-weston.log > /root/weston10-iocspy.log 2>&1 &
    W=$!
    i=0
    while [ "$i" -lt 100 ]; do
        [ -S "$RD/wayland-0" ] && break
        [ -d /proc/$W ] || break
        i=$((i + 1)); sleep 0.2
    done
    sleep 3
    log "weston alive=$([ -d /proc/$W ] && echo yes || echo no)"
    log "--- weston 日志尾部 ---"
    tail -18 /root/weston10-weston.log >> "$LOG" 2>&1
    log "--- ioctl 跟踪（DRM 请求序列；最后 30 条）---"
    grep -a '^\[IOC\]' /root/weston10-iocspy.log | tail -30 >> "$LOG" 2>&1
    log "--- ioctl 跟踪里失败的请求 ---"
    grep -a '^\[IOC\]' /root/weston10-iocspy.log | grep -a 'rc=-1' >> "$LOG" 2>&1
    grep -a '^\[IOC\]' /root/weston10-iocspy.log | grep -a 'rc=-1' | tail -12 > /dev/console 2>&1
    kill "$W" 2>/dev/null
else
    log "!! /iocspy.so 或 weston 缺失，跳过 B"
fi

[ -d /proc/$SD ] && kill "$SD" 2>/dev/null
log "[WESTON10_SUM] sim=done iocspy=done"
log "weston10 收尾"
sync
