#!/bin/sh
# autorun_weston3.sh —— Weston 启动修复轮（M2 第三轮）
#
# ── 前两轮的失败原因（各修掉一层）──────────────────────────────────────────
# weston1：装包/依赖/seatd/libseat 授权**全部 OK**，失败于 `--drm-device=card0`
#          （Weston 14 需要完整路径，报错原样回显 'card0' 即证据）
# weston2：参数改对了，但踩到**新坑**：
#          x-kernel guest 的 `/run` 是**持久化**的（不是 tmpfs）——weston1 轮遗留的
#          `/run/seatd.sock`（0 字节 socket 文件）被 `cp` 固化进 agentos-weston.img；
#          autorun 用 `[ ! -S /run/seatd.sock ]` 决定"是否需要启动 seatd"时被这个
#          空壳文件骗过，**跳过了启动** ⇒ libseat 报
#              Could not connect to socket /run/seatd.sock: Connection refused
#          注意是 Connection refused 而不是 No such file —— 这正好指向"文件在、监听者不在"。
#
# ── 本轮修正（三处，都是判据层面的修正）──────────────────────────────────
# 1. **永远** `rm -f` 陈旧 socket 并重启 seatd —— 不用"文件是否存在"当判据。
#    判据改为「seatd 进程存活 → 由 weston 实际连接成功」这条功能链。
#    （M2 纪律：**未验证的门禁比没门禁更危险** —— 空壳 socket 就是典型的假门禁。）
# 2. `--drm-device=/dev/dri/card0`（完整路径）为主方案。
# 3. 备选方案只在主方案失败时跑，避免上次"四方案全跑但根因在别处"的浪费。
#
# ── 本轮顺带采集的事实（只读，不改变系统）────────────────────────────────
# /run 残留物清单（证明持久化）、/dev/input 现状（G6 缺口）、/sys/class 现状。
#
# 注意：本文件会被 t490_round.sh 做过「双下划线包裹的占位符」替换与残留硬校验，
#       正文里不得出现该形式的字符串 —— 注释里也不行。

LOG=/root/weston-round.log
: > "$LOG"
RD=/run/user/0

log() {
    echo "[weston3] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}

# ==================================================== A. 残留物勘查（只读）
log "===== A. /run 残留物勘查（本轮根因的现场）====="
log "--- /run 顶层 ---"
ls -la /run/ >> "$LOG" 2>&1
log "--- /run/seatd.sock（若存在即为固化残留）---"
ls -l /run/seatd.sock >> "$LOG" 2>&1 || log "  (不存在)"
log "--- /run/user/0 ---"
ls -la "$RD" >> "$LOG" 2>&1
ls -l /run/seatd.sock > /dev/console 2>&1 || true
log "--- /dev/input（G6 缺口取样）---"
ls -la /dev/input/ >> "$LOG" 2>&1
log "--- /dev/dri ---"
ls -l /dev/dri/ >> "$LOG" 2>&1
ls -l /dev/dri/ > /dev/console 2>&1
log "--- 现存 seatd 进程（应无：QEMU 每轮重启，进程不跨轮）---"
(ps 2>/dev/null | grep -w seatd | grep -v grep) >> "$LOG" 2>&1 || log "  (无)"

# ==================================================== B. 准备（含清理）
mkdir -p "$RD" 2>/dev/null
chmod 700 "$RD" 2>/dev/null
mkdir -p /tmp/.X11-unix 2>/dev/null
chmod 1777 /tmp/.X11-unix 2>/dev/null
mkdir -p /run/udev/data 2>/dev/null
printf 'E:ID_INPUT=1\nE:ID_INPUT_MOUSE=1\nE:ID_SEAT=seat0\n' > /run/udev/data/c13:1 2>/dev/null
printf 'E:ID_INPUT=1\nE:ID_INPUT_KEYBOARD=1\nE:ID_SEAT=seat0\n' > /run/udev/data/c13:2 2>/dev/null

# ★ 关键修正 1：清掉可能固化的陈旧 socket（判据不能用"文件存在"）
log "===== B. 清理陈旧运行态 ===="
rm -f /run/seatd.sock "$RD"/wayland-* "$RD"/wayland-*.lock 2>/dev/null
log "清理后 /run/seatd.sock 存在=$([ -e /run/seatd.sock ] && echo yes || echo no)"

# ==================================================== C. 启动 seatd（永远启动 + 功能判据）
log "===== C. 启动 seatd ===="
rm -f /root/seatd.log
seatd -g root -l debug > /root/seatd.log 2>&1 &
SEATD=$!
log "seatd pid=$SEATD"
sleep 2
SEATD_ALIVE=no
[ -d /proc/$SEATD ] && SEATD_ALIVE=yes
log "seatd 进程存活=$SEATD_ALIVE socket 文件=$([ -S /run/seatd.sock ] && echo yes || echo no)"
log "--- seatd.log ---"
tail -12 /root/seatd.log >> "$LOG" 2>&1
tail -12 /root/seatd.log > /dev/console 2>&1
if [ "$SEATD_ALIVE" != "yes" ]; then
    log "!! seatd 立刻退出 —— 这是本轮唯一的阻塞点，后面必定失败，先修这里"
fi

# ==================================================== D. 主方案：完整路径
log "===== D. 主方案: --drm-device=/dev/dri/card0 ===="
rm -f /root/weston-1.log
env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 weston \
    --backend=drm-backend.so --renderer=pixman --drm-device=/dev/dri/card0 \
    --seat=seat0 --continue-without-input --idle-time=0 --xwayland \
    --log=/root/weston-1.log > /root/weston-1-stdout.log 2>&1 &
W1=$!
log "weston pid=$W1"

i=0
while [ "$i" -lt 150 ]; do
    [ -S "$RD/wayland-0" ] && break
    [ -d /proc/$W1 ] || break
    i=$((i + 1))
    sleep 0.2
done

WINNER=""
if [ -d /proc/$W1 ] && [ -S "$RD/wayland-0" ]; then
    WINNER="1"
    log "SCHEME1_OK pid=$W1 socket=$RD/wayland-0（等待 ${i} × 0.2s）"
    echo "SCHEME1_OK" > /dev/console
else
    log "!! 主方案失败：进程存活=$([ -d /proc/$W1 ] && echo yes || echo no) socket=$([ -S "$RD/wayland-0" ] && echo yes || echo no)"
    log "--- weston-1.log 尾部 ---"
    tail -30 /root/weston-1.log >> "$LOG" 2>&1
    tail -30 /root/weston-1.log > /dev/console 2>&1
    [ -d /proc/$W1 ] && kill -9 "$W1" 2>/dev/null
    sleep 1
fi

# ==================================================== E. 备选（仅主方案失败时才跑）
if [ -z "$WINNER" ]; then
    log "===== E. 备选: 不带 --drm-device（让 Weston 自行探测）====="
    rm -f /root/weston-2.log "$RD"/wayland-* 2>/dev/null
    env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 weston \
        --backend=drm-backend.so --renderer=pixman \
        --seat=seat0 --continue-without-input --idle-time=0 \
        --log=/root/weston-2.log > /root/weston-2-stdout.log 2>&1 &
    W2=$!
    log "weston(备选) pid=$W2"
    i=0
    while [ "$i" -lt 100 ]; do
        [ -S "$RD/wayland-0" ] && break
        [ -d /proc/$W2 ] || break
        i=$((i + 1))
        sleep 0.2
    done
    if [ -d /proc/$W2 ] && [ -S "$RD/wayland-0" ]; then
        WINNER="2"
        log "SCHEME2_OK pid=$W2"
    else
        log "!! 备选也失败"
        tail -30 /root/weston-2.log >> "$LOG" 2>&1
        tail -30 /root/weston-2.log > /dev/console 2>&1
        [ -d /proc/$W2 ] && kill -9 "$W2" 2>/dev/null
    fi
fi

# ==================================================== F. 成功后的观察
if [ -n "$WINNER" ]; then
    log "===== Weston 起飞（方案 $WINNER）====="
    log "--- weston-$WINNER.log 关键行（Output/模式/CRTC）---"
    grep -aE 'Output|Connector|CRTC|enabled|pixman|mode |repaint|DRM|fatal|error' \
        /root/weston-$WINNER.log >> "$LOG" 2>&1
    grep -aE 'Output|enabled|fatal|CRTC' /root/weston-$WINNER.log > /dev/console 2>&1

    if command -v weston-simple-shm >/dev/null 2>&1; then
        env XDG_RUNTIME_DIR="$RD" WAYLAND_DISPLAY=wayland-0 \
            weston-simple-shm > /root/simple-shm.log 2>&1 &
        log "weston-simple-shm pid=$!"
        sleep 2
        log "simple-shm 存活=$([ -d /proc/$! ] && echo yes || echo no) 输出："
        head -5 /root/simple-shm.log >> "$LOG" 2>&1
    fi

    n=0
    while [ "$n" -lt 12 ]; do
        ALIVE=no
        [ -d /proc/$W1 ] && ALIVE=yes
        [ -n "$W2" ] && [ -d /proc/$W2 ] && ALIVE=yes
        SOCK=no; [ -S "$RD/wayland-0" ] && SOCK=yes
        log "+$((n * 30))s weston_alive=$ALIVE socket=$SOCK lines=$(wc -l < /root/weston-$WINNER.log 2>/dev/null)"
        sync
        n=$((n + 1))
        sleep 30
    done
else
    log "===== 主方案与备选均失败，保持会话存活供取证 ====="
    n=0
    while [ "$n" -lt 8 ]; do
        sync
        n=$((n + 1))
        sleep 30
    done
fi

# 统一日志名（round_assert 回收清单登记的是 /root/weston.log）
{
    echo "===== weston-1.log (--drm-device=/dev/dri/card0) ====="
    cat /root/weston-1.log 2>/dev/null
    echo "===== weston-2.log (no --drm-device) ====="
    cat /root/weston-2.log 2>/dev/null
} > /root/weston.log 2>&1

log "autorun_weston3 done winner=[$WINNER]"
sync
sync
