#!/bin/sh
# autorun_weston4.sh —— Weston 启动轮（M2 第四轮）：LD_PRELOAD 绕过 libseat 后端
#
# ── 前三轮的收敛路径 ───────────────────────────────────────────────────────
# weston1  --drm-device=card0 缺前缀          → 改完整路径（已修）
# weston2  /run 持久化导致陈旧空壳 socket 骗过门禁 → 永远 rm -f 重启 seatd（已修）
# weston3  完整路径也失败：真 libseat 报 could not open DRM device '/dev/dri/card0'
#          此时 seatd 侧一切正常（seatd started / Seat opened / session control granted）
#          ⇒ 阻塞点已不在"能否连上 seatd"，而在 libseat 的 **设备归属判定**
#             （seatd 靠 libudev/sysfs 枚举设备，本 guest 的 /sys/class 只有 graphics，
#               /sys/class/drm 不存在 ⇒ 枚举不到 card0 ⇒ 拒绝打开）。
#
# ── 本轮方案 ───────────────────────────────────────────────────────────────
# 用 LD_PRELOAD 的 libseat shim 完全绕过 libseat 的后端逻辑：
#     libseat_open_seat  → 返回假 seat，100ms 后延迟触发 enable_seat 回调
#     libseat_open_device→ 直接 open(path)（以 root 身份），不经 seatd
# 该 shim 的关键设计是"延迟回调"：v3 版本曾用同步回调，导致 weston 在内部状态
# 尚未就绪时继续初始化，症状同样是 "could not open DRM device" 且**从未调用 open_device**
# —— 与该症状高度相似，因此本轮同时用 shim 的日志来回答"open_device 到底有没有被调用"。
#
# 双轨设计（本轮同时回答两个问题）：
#   D 段：shim 路径（不启 seatd）—— 主方案
#   E 段：若 D 失败，启 seatd + 真 libseat —— 对照，用于确认"是 libseat 后端问题，
#         还是 DRM 设备本身打不开"
#
# 注意：本文件会被 t490_round.sh 做过「双下划线包裹的占位符」替换与残留硬校验，
#       正文里不得出现该形式的字符串 —— 注释里也不行。

LOG=/root/weston-round.log
: > "$LOG"
RD=/run/user/0
SHIM=/shim/libseat-shim.so

log() {
    echo "[weston4] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}

# ==================================================== A. 解包 shim
log "===== A. 解包 libseat shim（来自 /pkgs.tar.gz）====="
if [ -f /pkgs.tar.gz ]; then
    rm -rf /shim
    mkdir -p /shim
    tar -xzf /pkgs.tar.gz -C /shim 2>>"$LOG"
    ls -l /shim/ >> "$LOG" 2>&1
    ls -l /shim/ > /dev/console 2>&1
    if [ -f "$SHIM" ]; then
        log "shim 就位: $SHIM"
    else
        log "!! shim 解包后不存在（tar 内容或路径不对）"
    fi
else
    log "!! /pkgs.tar.gz 未注入 —— 本轮主方案无法进行（检查 PKG_TARBALL 环境变量）"
fi

# ==================================================== B. 清理运行态（沿用第三轮修正）
mkdir -p "$RD" 2>/dev/null
chmod 700 "$RD" 2>/dev/null
mkdir -p /tmp/.X11-unix 2>/dev/null
chmod 1777 /tmp/.X11-unix 2>/dev/null
mkdir -p /run/udev/data 2>/dev/null
printf 'E:ID_INPUT=1\nE:ID_INPUT_MOUSE=1\nE:ID_SEAT=seat0\n' > /run/udev/data/c13:1 2>/dev/null
printf 'E:ID_INPUT=1\nE:ID_INPUT_KEYBOARD=1\nE:ID_SEAT=seat0\n' > /run/udev/data/c13:2 2>/dev/null

log "===== B. 清理 ==> 陈旧 socket 与 wayland socket ===="
rm -f /run/seatd.sock "$RD"/wayland-* "$RD"/wayland-*.lock 2>/dev/null
log "/run/seatd.sock 存在=$([ -e /run/seatd.sock ] && echo yes || echo no)"

WINNER=""

# ==================================================== D. 主方案：shim（不启 seatd）
if [ -f "$SHIM" ]; then
    log "===== D. 主方案: LD_PRELOAD=shim + --drm-device=/dev/dri/card0（不启 seatd）====="
    rm -f /root/weston-4.log /root/weston-4-stdout.log
    env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 LD_PRELOAD="$SHIM" weston \
        --backend=drm-backend.so --renderer=pixman --drm-device=/dev/dri/card0 \
        --seat=seat0 --continue-without-input --idle-time=0 --xwayland \
        --log=/root/weston-4.log > /root/weston-4-stdout.log 2>&1 &
    W4=$!
    log "weston(shim) pid=$W4"

    i=0
    while [ "$i" -lt 150 ]; do
        [ -S "$RD/wayland-0" ] && break
        [ -d /proc/$W4 ] || break
        i=$((i + 1))
        sleep 0.2
    done

    if [ -d /proc/$W4 ] && [ -S "$RD/wayland-0" ]; then
        WINNER="4"
        log "SCHEME4_OK pid=$W4 socket=$RD/wayland-0（等待 ${i} × 0.2s）"
        echo "SCHEME4_OK" > /dev/console
    else
        log "!! shim 方案失败：进程存活=$([ -d /proc/$W4 ] && echo yes || echo no) socket=$([ -S "$RD/wayland-0" ] && echo yes || echo no)"
        log "--- weston-4.log 尾部（weston 自身）---"
        tail -25 /root/weston-4.log >> "$LOG" 2>&1
        tail -25 /root/weston-4.log > /dev/console 2>&1
        log "--- weston-4-stdout.log 尾部（★ shim 的 [libseat-shim] 日志在这里）---"
        tail -25 /root/weston-4-stdout.log >> "$LOG" 2>&1
        tail -25 /root/weston-4-stdout.log > /dev/console 2>&1
        log "--- shim 是否被加载：看上面有无 [libseat-shim] 前缀 ---"
        [ -d /proc/$W4 ] && kill -9 "$W4" 2>/dev/null
        sleep 1
    fi
fi

# ==================================================== E. 对照：真 libseat + seatd
if [ -z "$WINNER" ]; then
    log "===== E. 对照: 真 libseat + seatd（确认是 libseat 后端问题还是设备问题）====="
    rm -f "$RD"/wayland-* 2>/dev/null
    rm -f /root/seatd.log
    seatd -g root -l debug > /root/seatd.log 2>&1 &
    SEATD=$!
    sleep 2
    log "seatd pid=$SEATD 存活=$([ -d /proc/$SEATD ] && echo yes || echo no)"
    rm -f /root/weston-5.log
    env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 weston \
        --backend=drm-backend.so --renderer=pixman --drm-device=/dev/dri/card0 \
        --seat=seat0 --continue-without-input --idle-time=0 \
        --log=/root/weston-5.log > /root/weston-5-stdout.log 2>&1 &
    W5=$!
    log "weston(真libseat) pid=$W5"
    i=0
    while [ "$i" -lt 100 ]; do
        [ -S "$RD/wayland-0" ] && break
        [ -d /proc/$W5 ] || break
        i=$((i + 1))
        sleep 0.2
    done
    if [ -d /proc/$W5 ] && [ -S "$RD/wayland-0" ]; then
        WINNER="5"
        log "SCHEME5_OK pid=$W5"
    else
        log "!! 对照也失败（则问题在 DRM 设备侧，不在 libseat）"
        tail -25 /root/weston-5.log >> "$LOG" 2>&1
        tail -25 /root/weston-5.log > /dev/console 2>&1
        log "--- seatd.log 尾部（看它是否收到并拒绝了 open_device 请求）---"
        tail -25 /root/seatd.log >> "$LOG" 2>&1
        tail -25 /root/seatd.log > /dev/console 2>&1
        [ -d /proc/$W5 ] && kill -9 "$W5" 2>/dev/null
    fi
fi

# ==================================================== F. 成功后的观察与客户端
if [ -n "$WINNER" ]; then
    log "===== Weston 起飞（方案 $WINNER）====="
    grep -aE 'Output|Connector|CRTC|enabled|pixman|mode |repaint|fatal|error|DRM' \
        /root/weston-$WINNER.log >> "$LOG" 2>&1
    grep -aE 'Output|enabled|fatal|CRTC|mode' /root/weston-$WINNER.log > /dev/console 2>&1

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
        ALIVE=no
        [ -n "$W4" ] && [ -d /proc/$W4 ] && ALIVE=yes
        [ -n "$W5" ] && [ -d /proc/$W5 ] && ALIVE=yes
        SOCK=no; [ -S "$RD/wayland-0" ] && SOCK=yes
        log "+$((n * 30))s weston_alive=$ALIVE socket=$SOCK lines=$(wc -l < /root/weston-$WINNER.log 2>/dev/null)"
        sync
        n=$((n + 1))
        sleep 30
    done
else
    log "===== 全部方案失败，保持会话存活供取证 ====="
    n=0
    while [ "$n" -lt 8 ]; do
        sync
        n=$((n + 1))
        sleep 30
    done
fi

# 合并日志到统一名（回收清单登记的是 /root/weston.log）
{
    echo "===== weston-4.log (LD_PRELOAD=libseat-shim) ====="
    cat /root/weston-4.log 2>/dev/null
    echo "===== weston-4-stdout.log (shim 日志) ====="
    cat /root/weston-4-stdout.log 2>/dev/null
    echo "===== weston-5.log (real libseat + seatd) ====="
    cat /root/weston-5.log 2>/dev/null
} > /root/weston.log 2>&1

log "autorun_weston4 done winner=[$WINNER]"
sync
sync
