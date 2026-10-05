#!/bin/sh
# autorun_weston7.sh —— Weston 启动轮（M2 第七轮）：修复 GetPlane 结构体后验证
#
# ── 上一轮（planeprobe）的结论 ─────────────────────────────────────────────
# 属性面全部正常（12 个属性名正确、type=1(PRIMARY)、IN_FORMATS blob 可读），
# 但：
#     [PLANE] GETPLANE rc=-1 errno=95        ← 未命中分派表
#     [PRES]  GETPLANERESOURCES rc=0         ← 相邻编号却是通的
# 根因：内核 `DrmModeGetPlane` 少了 mainline uapi 的 crtc_x/crtc_y/x/y 四个 u32
#       ⇒ sizeof 32 而非 48 ⇒ iowr 把 size 编进 ioctl 号 ⇒ 与 libdrm 不匹配。
# ⇒ Weston 逐个 drmModeGetPlane() 失败 ⇒ plane_list 为空 ⇒ "Failed to find primary plane"。
# 修复见 p3_apply.sh（补字段 + handle 置 0）。
#
# ── 本轮做两件事（先只读自检，再启动）────────────────────────────────────
#   C 段：跑 /drmplaneprobe 复检 —— 期望 GETPLANE rc=0、possible_crtcs=0x1、crtc_id=16
#   D 段：双 shim + weston 启动 —— 期望越过 plane 关卡，走到 output enable / 首帧
#
# 注意：本文件会被 t490_round.sh 做过「双下划线包裹的占位符」替换与残留硬校验，
#       正文里不得出现该形式的字符串 —— 注释里也不行。

LOG=/root/weston-round.log
: > "$LOG"
RD=/run/user/0
SEAT_SHIM=/shim/libseat-shim.so
UDEV_SHIM=/shim/libudev-shim.so

log() {
    echo "[weston7] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}

# ==================================================== A. 解包 shims
log "===== A. 解包 shims ===="
if [ -f /pkgs.tar.gz ]; then
    rm -rf /shim; mkdir -p /shim
    tar -xzf /pkgs.tar.gz -C /shim 2>>"$LOG"
    ls -l /shim/ > /dev/console 2>&1
    [ -f "$SEAT_SHIM" ] && log "seat shim OK" || log "!! 缺 seat shim"
    [ -f "$UDEV_SHIM" ] && log "udev shim OK" || log "!! 缺 udev shim"
else
    log "!! /pkgs.tar.gz 未注入"
fi

# ==================================================== B. 清理运行态
mkdir -p "$RD" 2>/dev/null; chmod 700 "$RD" 2>/dev/null
mkdir -p /tmp/.X11-unix 2>/dev/null; chmod 1777 /tmp/.X11-unix 2>/dev/null
mkdir -p /run/udev/data 2>/dev/null
printf 'E:ID_INPUT=1\nE:ID_INPUT_MOUSE=1\nE:ID_SEAT=seat0\n' > /run/udev/data/c13:1 2>/dev/null
printf 'E:ID_INPUT=1\nE:ID_INPUT_KEYBOARD=1\nE:ID_SEAT=seat0\n' > /run/udev/data/c13:2 2>/dev/null
log "===== B. 清理 ===="
rm -f /run/seatd.sock "$RD"/wayland-* "$RD"/wayland-*.lock 2>/dev/null

# ==================================================== C. plane 复检（只读）
log "===== C. plane 复检（GETPLANE 应 rc=0）===="
if [ -x /drmplaneprobe ]; then
    /drmplaneprobe > /root/plane2.out 2>&1 &
    pp=$!
    j=0
    while [ "$j" -lt 90 ]; do
        [ -d /proc/$pp ] || break
        j=$((j + 1)); sleep 1
    done
    [ -d /proc/$pp ] && { log "!! 探针 HUNG"; kill -9 "$pp" 2>/dev/null; }
    cat /root/plane2.out >> "$LOG"
    grep -aE '^\[CAP\]|^\[PLANE\]|^\[PLANESUM\]' /root/plane2.out | tail -20 > /dev/console 2>&1
    grep -a 'PLANESUM' /root/plane2.out >> "$LOG" 2>/dev/null
    log "plane 复检完成（详见 console 上的 [PLANE]/[PLANESUM] 行）"
else
    log "!! /drmplaneprobe 未注入"
fi

# ==================================================== D. 启动 weston（双 shim）
WINNER=""
log "===== D. 启动 weston（双 shim）===="
rm -f /root/weston-7.log /root/weston-7-stdout.log
env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 \
    LD_PRELOAD="$SEAT_SHIM $UDEV_SHIM" \
    weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
    --seat=seat0 --continue-without-input --idle-time=0 --debug \
    --log=/root/weston-7.log > /root/weston-7-stdout.log 2>&1 &
W7=$!
log "weston pid=$W7"

i=0
while [ "$i" -lt 150 ]; do
    [ -S "$RD/wayland-0" ] && break
    [ -d /proc/$W7 ] || break
    i=$((i + 1))
    sleep 0.2
done

if [ -d /proc/$W7 ] && [ -S "$RD/wayland-0" ]; then
    WINNER="7"
    log "SCHEME7_OK pid=$W7 socket=$RD/wayland-0（等待 ${i} × 0.2s）"
    echo "SCHEME7_OK" > /dev/console
else
    log "!! 失败：进程存活=$([ -d /proc/$W7 ] && echo yes || echo no) socket=$([ -S "$RD/wayland-0" ] && echo yes || echo no)"
fi

log "--- weston-7.log 尾部（成功时会打 Output/CRTC/mode/repaint）---"
tail -40 /root/weston-7.log >> "$LOG" 2>&1
tail -40 /root/weston-7.log > /dev/console 2>&1
log "--- weston-7.log 里与 output/plane/CRTC 相关的全部行 ---"
grep -aiE 'plane|output|head|crtc|mode |enabled|repaint|fatal|error' /root/weston-7.log \
    >> "$LOG" 2>&1
grep -aiE 'plane|output .* enabled|fatal|Error' /root/weston-7.log | tail -20 > /dev/console 2>&1

# ==================================================== E. 成功后的客户端与观察
if [ -n "$WINNER" ]; then
    log "===== Weston 起飞 ===="
    if command -v weston-simple-shm >/dev/null 2>&1; then
        env XDG_RUNTIME_DIR="$RD" WAYLAND_DISPLAY=wayland-0 \
            weston-simple-shm > /root/simple-shm.log 2>&1 &
        SHPID=$!
        log "weston-simple-shm pid=$SHPID"
        sleep 2
        log "simple-shm 存活=$([ -d /proc/$SHPID ] && echo yes || echo no)"
        head -8 /root/simple-shm.log >> "$LOG" 2>&1
    fi
    n=0
    while [ "$n" -lt 12 ]; do
        ALIVE=no; [ -d /proc/$W7 ] && ALIVE=yes
        SOCK=no;  [ -S "$RD/wayland-0" ] && SOCK=yes
        log "+$((n * 30))s weston_alive=$ALIVE socket=$SOCK lines=$(wc -l < /root/weston-7.log 2>/dev/null)"
        sync
        n=$((n + 1))
        sleep 30
    done
else
    log "===== 失败：保持会话存活供 screendump 取证 ====="
    n=0
    while [ "$n" -lt 8 ]; do
        sync
        n=$((n + 1))
        sleep 30
    done
fi

{
    echo "===== weston-7.log ====="
    cat /root/weston-7.log 2>/dev/null
    echo "===== weston-7-stdout.log (shim) ====="
    cat /root/weston-7-stdout.log 2>/dev/null
    echo "===== plane2.out ====="
    cat /root/plane2.out 2>/dev/null
} > /root/weston.log 2>&1

log "autorun_weston7 done winner=[$WINNER]"
sync
sync
