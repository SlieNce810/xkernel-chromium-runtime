#!/bin/sh
# autorun_weston2.sh —— Weston 启动参数定位轮（M2 第二轮）
#
# 第一轮（weston1）结论：装包、依赖、seatd、libseat 授权**全部成功**，只差最后一步：
#     [libseat/libseat.c:73] Seat opened with backend 'seatd'
#     [libseat] session control granted
#     ERROR: could not open DRM device 'card0'
#     no drm device found
#     fatal: failed to create compositor backend
#
# 根因分析：Weston 14 的 DRM backend 把 `--drm-device` 的值交给
# `weston_launcher_open()` → libseat `libseat_open_device(seat, path, &fd)`，
# 这里 path 必须是**设备路径**。官方 xk-weston-start 写的是 `--drm-device=card0`，
# 在 Weston 14 + libseat/seatd 组合下不会被拼成 /dev/dri/card0 —— 报错里原样回显
# 'card0' 即为证据（若 Weston 自己拼接，报错会显示拼接后的完整路径）。
#
# 因此本轮按"最可能成功 → 逐步放宽"的顺序试三个方案，每个方案独立日志、独立判定：
#   方案 1  --drm-device=/dev/dri/card0（完整路径）        ← 首选，直击根因
#   方案 2  不给 --drm-device（让 Weston 自行枚举）        ← 若 1 失败，测试枚举通路
#   方案 3  + 环境变体：去掉 --seat / 加 WESTON_LIBSEAT=0  ← 若 2 失败，测 launcher 差异
#
# 先做设备诊断（只读）：/dev/dri 内容、设备号、/dev 挂载类型、/sys/class/drm 是否存在 ——
# 这三项决定了"Weston 有没有可能自己找到设备"，也让失败原因不靠猜。
#
# 注意：本文件会被 t490_round.sh 做过「双下划线包裹的占位符」替换与残留硬校验，
#       正文里不得出现该形式的字符串 —— 注释里也不行。

LOG=/root/weston-round.log
: > "$LOG"
RD=/run/user/0

log() {
    echo "[weston2] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}

# ==================================================== A. 设备诊断（只读）
log "===== A. 图形设备诊断 ===="
log "--- /dev/dri ---"
ls -l /dev/dri/ >> "$LOG" 2>&1
ls -l /dev/dri/ > /dev/console 2>&1
log "--- /dev/input ---"
ls -l /dev/input/ >> "$LOG" 2>&1
log "--- /dev 挂载类型 ---"
grep -a ' /dev ' /proc/self/mounts >> "$LOG" 2>&1 || log "(/proc/self/mounts 无 /dev 行)"
grep -a ' /dev ' /proc/self/mounts > /dev/console 2>&1
log "--- /sys/class 内容（Weston/libudev 若走 sysfs 枚举，这里必须齐全）---"
ls /sys/class/ >> "$LOG" 2>&1
ls /sys/class/ > /dev/console 2>&1
log "--- /sys/class/drm（若有）---"
ls -l /sys/class/drm/ >> "$LOG" 2>&1 || log "  /sys/class/drm 不存在"
ls /sys/class/drm/ > /dev/console 2>&1 || true
log "--- /run/udev/data（我们自己写的假 udev 数据）---"
ls -l /run/udev/data/ >> "$LOG" 2>&1

# ==================================================== 准备
mkdir -p "$RD" 2>/dev/null
chmod 700 "$RD" 2>/dev/null
mkdir -p /tmp/.X11-unix 2>/dev/null
chmod 1777 /tmp/.X11-unix 2>/dev/null
mkdir -p /run/udev/data 2>/dev/null
printf 'E:ID_INPUT=1\nE:ID_INPUT_MOUSE=1\nE:ID_SEAT=seat0\n' > /run/udev/data/c13:1 2>/dev/null
printf 'E:ID_INPUT=1\nE:ID_INPUT_KEYBOARD=1\nE:ID_SEAT=seat0\n' > /run/udev/data/c13:2 2>/dev/null

# seatd（沿用第一轮的成功配置）
if [ ! -S /run/seatd.sock ]; then
    rm -f /run/seatd.sock
    seatd -g root -l debug > /root/seatd.log 2>&1 &
    log "seatd pid=$!"
    sleep 1
fi
[ -S /run/seatd.sock ] && log "seatd socket OK" || log "!! seatd socket 缺失"

# 三个方案共用的收尾判定：等最多 25s，返回 0=成功(进程活+socket在)
wait_weston() {
    wp="$1"
    i=0
    while [ "$i" -lt 125 ]; do
        [ -S "$RD/wayland-0" ] && break
        [ -d /proc/$wp ] || break
        i=$((i + 1))
        sleep 0.2
    done
    if [ -d /proc/$wp ] && [ -S "$RD/wayland-0" ]; then
        return 0
    fi
    return 1
}

# 失败时打印日志尾部（关键：把 weston 自己的日志倒到串口，别让失败原因留在盘上）
dump_fail() {
    wp="$1"; wl="$2"
    log "!! 方案失败：进程存活=$([ -d /proc/$wp ] && echo yes || echo no) socket=$([ -S "$RD/wayland-0" ] && echo yes || echo no)"
    log "--- $wl 尾部 ---"
    tail -30 "$wl" >> "$LOG" 2>&1
    tail -30 "$wl" > /dev/console 2>&1
    [ -d /proc/$wp ] && kill -9 "$wp" 2>/dev/null
    sleep 1
}

cleanup_wayland() {
    rm -f "$RD"/wayland-* "$RD"/wayland-*.lock 2>/dev/null
    sleep 1
}

WINNER=""

# ==================================================== 方案 1：完整路径
log "===== 方案 1: --drm-device=/dev/dri/card0 ===="
cleanup_wayland
rm -f /root/weston-1.log
env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 weston \
    --backend=drm-backend.so --renderer=pixman --drm-device=/dev/dri/card0 \
    --seat=seat0 --continue-without-input --idle-time=0 --xwayland \
    --log=/root/weston-1.log > /root/weston-1-stdout.log 2>&1 &
W1=$!
log "weston(方案1) pid=$W1"
if wait_weston "$W1"; then
    log "SCHEME1_OK pid=$W1"
    WINNER="1"
    echo "SCHEME1_OK" > /dev/console
else
    dump_fail "$W1" /root/weston-1.log
fi

# ==================================================== 方案 2：不给 --drm-device
if [ -z "$WINNER" ]; then
    log "===== 方案 2: 无 --drm-device（让 Weston 自行枚举）===="
    cleanup_wayland
    rm -f /root/weston-2.log
    env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 weston \
        --backend=drm-backend.so --renderer=pixman \
        --seat=seat0 --continue-without-input --idle-time=0 --xwayland \
        --log=/root/weston-2.log > /root/weston-2-stdout.log 2>&1 &
    W2=$!
    log "weston(方案2) pid=$W2"
    if wait_weston "$W2"; then
        log "SCHEME2_OK pid=$W2"
        WINNER="2"
        echo "SCHEME2_OK" > /dev/console
    else
        dump_fail "$W2" /root/weston-2.log
    fi
fi

# ==================================================== 方案 3：launcher 变体
if [ -z "$WINNER" ]; then
    log "===== 方案 3: 完整路径 + 去掉 --seat（测 launcher 差异）===="
    cleanup_wayland
    rm -f /root/weston-3.log
    env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 weston \
        --backend=drm-backend.so --renderer=pixman --drm-device=/dev/dri/card0 \
        --continue-without-input --idle-time=0 \
        --log=/root/weston-3.log > /root/weston-3-stdout.log 2>&1 &
    W3=$!
    log "weston(方案3) pid=$W3"
    if wait_weston "$W3"; then
        log "SCHEME3_OK pid=$W3"
        WINNER="3"
        echo "SCHEME3_OK" > /dev/console
    else
        dump_fail "$W3" /root/weston-3.log
    fi
fi

# ==================================================== 方案 4：libseat builtin 后端
if [ -z "$WINNER" ]; then
    log "===== 方案 4: LIBSEAT_BACKEND=builtin（绕过 seatd，libseat 直接访问设备）===="
    cleanup_wayland
    rm -f /root/weston-4.log
    env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 LIBSEAT_BACKEND=builtin weston \
        --backend=drm-backend.so --renderer=pixman --drm-device=/dev/dri/card0 \
        --seat=seat0 --continue-without-input --idle-time=0 \
        --log=/root/weston-4.log > /root/weston-4-stdout.log 2>&1 &
    W4=$!
    log "weston(方案4) pid=$W4"
    if wait_weston "$W4"; then
        log "SCHEME4_OK pid=$W4"
        WINNER="4"
        echo "SCHEME4_OK" > /dev/console
    else
        dump_fail "$W4" /root/weston-4.log
    fi
fi

# ==================================================== 成功后的客户端与观察
if [ -n "$WINNER" ]; then
    log "===== Weston 起飞（方案 $WINNER）====="
    grep -aE 'Output|Connector|CRTC|enabled|pixman|repaint|mode|error|fatal' \
        /root/weston-$WINNER.log 2>/dev/null | tail -30 >> "$LOG"
    grep -aE 'Output|enabled|fatal' /root/weston-$WINNER.log 2>/dev/null | tail -12 > /dev/console 2>&1

    if command -v weston-simple-shm >/dev/null 2>&1; then
        env XDG_RUNTIME_DIR="$RD" WAYLAND_DISPLAY=wayland-0 \
            weston-simple-shm > /root/simple-shm.log 2>&1 &
        log "weston-simple-shm pid=$!"
    fi

    # 把当前 weston 的日志软链到统一名字，便于 round_assert 回收清单命中
    cp -f /root/weston-$WINNER.log /root/weston.log 2>/dev/null

    n=0
    while [ "$n" -lt 12 ]; do
        ALIVE=no
        for p in $W1 $W2 $W3 $W4; do [ -d /proc/$p ] && ALIVE=yes; done
        SOCK=no; [ -S "$RD/wayland-0" ] && SOCK=yes
        log "+$((n * 30))s weston_alive=$ALIVE socket=$SOCK log_lines=$(wc -l < /root/weston-$WINNER.log 2>/dev/null)"
        sync
        n=$((n + 1))
        sleep 30
    done
else
    log "===== 三方案全部失败（结论收敛见 /root/weston-round.log）====="
    n=0
    while [ "$n" -lt 8 ]; do
        sync
        n=$((n + 1))
        sleep 30
    done
fi

# 把三个方案的日志合并进统一文件名 —— round_assert.sh 的回收清单只登记了
# /root/weston.log，合并后三个方案的原始日志都能被一次性回收，不留在盘上。
{
    echo "===== scheme1 (--drm-device=/dev/dri/card0) ====="
    cat /root/weston-1.log 2>/dev/null
    echo "===== scheme2 (no --drm-device) ====="
    cat /root/weston-2.log 2>/dev/null
    echo "===== scheme3 (full path, no --seat) ====="
    cat /root/weston-3.log 2>/dev/null
    echo "===== scheme4 (LIBSEAT_BACKEND=builtin) ====="
    cat /root/weston-4.log 2>/dev/null
} > /root/weston.log 2>&1

log "autorun_weston2 done winner=[$WINNER]"
sync
sync
