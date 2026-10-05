#!/bin/sh
# autorun_weston9.sh —— 阶段 3 首试：**完全无 shim** 的标准 Weston
#
# 与 weston6/7/8 的关键差异（每一条都是本轮之前刚建立的新事实）
#   1. 不再 LD_PRELOAD libudev / libseat shim ——
#        设备发现走内核投射的 `/sys/class/drm/**`（std3 轮 udevprobe=UDEV_OK）
#        设备打开走真实 seatd 的 SCM_RIGHTS FD 传递（std3 轮 seatprobe=SEAT_OK）
#   2. 内核 `DrmModeGetPlane` 已回退为标准 32 字节（std1→std2 闭环），
#      标准 libdrm 的 `drmModeGetPlane` 可用（std2 轮 STD_OK）
#   3. seatd 由本轮显式启动（SEATD_VTBOUND=0，官方单 seat 配置）
#
# 分层判据（**不用**"进程存在 / socket 存在"这类弱判据）
#   L1 设备发现 : weston 日志出现 "using /dev/dri/card0"
#   L2 plane 关卡: 是否出现 "Failed to find primary plane"（出现 ⇒ 未越过）
#   L3 output    : 出现 "Output ... enabled" / "repaint" / "VSync" / "modeset"
#   L4 客户端绘制: weston-simple-shm 存活，且 weston 日志出现 client commit/release
# 结论以机器行输出：`[WESTON_SUM] L1=.. L2=.. L3=.. L4=.. verdict=..`
#
# 说明：本轮仍带 `--continue-without-input` —— 那是**输入**尚未打通（阶段 3 后半段）
# 的临时手段，验收轮必须去掉（报告里逐轮标注）。
LOG=/root/weston9.log
: > "$LOG"
RD=/run/user/0
WLOG=/root/weston9-weston.log

log() {
    echo "[weston9] $*" > /dev/console 2>/dev/null
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

# ==================================================== A. 前提自证
log "===== A. 前提（无 shim + 内核投射 + seatd）====="
log "LD_PRELOAD=[${LD_PRELOAD:-<空>}]  （本轮必须为空；shim 已拆）"
log "/sys/class/drm      : $(ls /sys/class/drm 2>/dev/null | tr '\n' ' ')"
log "card0/uevent        : $(cat /sys/class/drm/card0/uevent 2>/dev/null | tr '\n' '|')"

mkdir -p "$RD" 2>/dev/null; chmod 700 "$RD" 2>/dev/null
rm -f /run/seatd.sock "$RD"/wayland-* "$RD"/wayland-*.lock 2>/dev/null

SEATD_VTBOUND=0 seatd -l info > /root/weston9-seatd.log 2>&1 &
SD=$!
sleep 1
log "seatd pid=$SD alive=$([ -d /proc/$SD ] && echo yes || echo no) socket=$([ -S /run/seatd.sock ] && echo yes || echo no)"

# ==================================================== B. 启动标准 Weston（无 shim）
log "===== B. 启动 Weston（无 shim，真实 libudev/libseat）====="
env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 \
    LIBSEAT_BACKEND=seatd SEATD_SOCK=/run/seatd.sock \
    weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
    --seat=seat0 --continue-without-input --idle-time=0 --debug \
    --log="$WLOG" > /root/weston9-stdout.log 2>&1 &
W9=$!
log "weston pid=$W9"

i=0
while [ "$i" -lt 200 ]; do
    [ -S "$RD/wayland-0" ] && break
    [ -d /proc/$W9 ] || break
    i=$((i + 1)); sleep 0.2
done

ALIVE=no; [ -d /proc/$W9 ] && ALIVE=yes
SOCK=no;  [ -S "$RD/wayland-0" ] && SOCK=yes
log "启动后：weston_alive=$ALIVE wayland_socket=$SOCK（等待 ${i}×0.2s）"
log "--- weston 日志尾部 ---"
tail -25 "$WLOG" >> "$LOG" 2>&1
tail -25 "$WLOG" > /dev/console 2>&1

# ==================================================== C. 分层判据（从日志读事实）
L1=no; L2=no; L3=no; L4=no
grep -aq "using /dev/dri/card0" "$WLOG" && L1=yes
grep -aq "Failed to find primary plane" "$WLOG" && L2=FAIL || L2=PASS
grep -aqE "Output .* enabled|repaint|VSync|modeset|scanout" "$WLOG" && L3=yes
log "分层判据：L1(设备发现)=$L1  L2(plane 关卡)=$L2  L3(output)=$L3"

log "--- 与 plane/output 相关的全部行 ---"
grep -aiE "plane|output|head|crtc|mode|enabled|repaint|fatal|error|failed" "$WLOG" >> "$LOG" 2>&1
grep -aiE "plane|output .* enabled|fatal|error|failed" "$WLOG" | tail -20 > /dev/console 2>&1

# ==================================================== D. 客户端绘制（若 Weston 活着）
if [ "$L1" = "yes" ]; then
    if command -v weston-simple-shm >/dev/null 2>&1; then
        env XDG_RUNTIME_DIR="$RD" WAYLAND_DISPLAY=wayland-0 \
            weston-simple-shm > /root/weston9-simple-shm.log 2>&1 &
        SH=$!
        sleep 3
        log "weston-simple-shm pid=$SH 存活=$([ -d /proc/$SH ] && echo yes || echo no)"
        head -6 /root/weston9-simple-shm.log >> "$LOG" 2>&1
        [ -d /proc/$SH ] && L4=yes
    fi
    grep -aiE "client|commit|release|buffer" "$WLOG" | tail -12 >> "$LOG" 2>&1
fi

log "[WESTON_SUM] L1=$L1 L2=$L2 L3=$L3 L4=$L4 verdict=DIAG"

# ==================================================== E. 观察窗（供 screendump 取证）
n=0
while [ "$n" -lt 12 ]; do
    A=no; [ -d /proc/$W9 ] && A=yes
    S=no; [ -S "$RD/wayland-0" ] && S=yes
    log "+$((n * 30))s weston_alive=$A socket=$S log_lines=$(wc -l < "$WLOG" 2>/dev/null)"
    sync
    n=$((n + 1))
    sleep 30
done

kill "$SD" 2>/dev/null
log "weston9 收尾（seatd 已停）"
sync
