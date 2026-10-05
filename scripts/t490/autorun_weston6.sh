#!/bin/sh
# autorun_weston6.sh —— Weston 启动轮（M2 第六轮）：**双 shim 打通最后一公里**
#
# ── 前五轮的收敛 ──────────────────────────────────────────────────────────
# weston1  官方 --drm-device=card0 缺 /dev/dri/ 前缀
# weston2  guest /run 持久化 ⇒ 陈旧空壳 socket 骗过门禁（skip 启 seatd）
# weston3  完整路径仍失败（此时误以为问题在 seatd 的设备归属判定）
# weston4  libseat shim 缺 3 个符号 ⇒ LD_PRELOAD 静默回退 ⇒ open_device 从未被调用
# weston5  符号补齐后仍失败 ⇒ ★ 读 weston 14 源码定位到真正根因：
#
#     libweston/backend-drm/drm.c:3697  open_specific_drm_device()
#         udev_device = udev_device_new_from_subsystem_sysname(b->udev, "drm", name);
#         if (!udev_device) { weston_log("ERROR: could not open DRM device '%s'\n", name); ... }
#
#     Weston 14 **不直接 open 设备**：它先让 libudev 去 /sys/class/drm/<name>/ 查设备，
#     查不到就报"打不开设备"并 return —— 所以 libseat/open() 永远不会被调用。
#     本 guest 的 /sys/class 只有 graphics，没有 drm ⇒ 必然失败。
#
# ── 本轮方案 ─────────────────────────────────────────────────────────────
# 两个 LD_PRELOAD shim 一起上：
#   libseat-shim.so —— open_seat 给假 seat；open_device 直接 open(path)
#   libudev-shim.so —— 假 udev 对象：按 subsystem+sysname 命中 drm，
#                       get_devnode→/dev/dri/card0、get_sysnum→"0"、get_devnum→226,0
# 于是 weston 能走到：drm_device_is_kms → weston_launcher_open → libseat shim
#                    → open("/dev/dri/card0") → 内核 DRM（属性面已修）
#
# 本轮**去掉 --xwayland**（减少变量；Xwayland 留到 Weston 自身出画面之后再加）。
# --drm-device 用 sysname 形态 "card0"（Weston 的 udev 查询按 sysname 走）。
#
# 注意：本文件会被 t490_round.sh 做过「双下划线包裹的占位符」替换与残留硬校验，
#       正文里不得出现该形式的字符串 —— 注释里也不行。

LOG=/root/weston-round.log
: > "$LOG"
RD=/run/user/0
SEAT_SHIM=/shim/libseat-shim.so
UDEV_SHIM=/shim/libudev-shim.so

log() {
    echo "[weston6] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}

# ==================================================== A. 解包双 shim
log "===== A. 解包 shims（/pkgs.tar.gz）====="
if [ -f /pkgs.tar.gz ]; then
    rm -rf /shim
    mkdir -p /shim
    tar -xzf /pkgs.tar.gz -C /shim 2>>"$LOG"
    ls -l /shim/ >> "$LOG" 2>&1
    ls -l /shim/ > /dev/console 2>&1
    [ -f "$SEAT_SHIM" ] && log "seat shim OK: $SEAT_SHIM" || log "!! 缺 $SEAT_SHIM"
    [ -f "$UDEV_SHIM" ] && log "udev shim OK: $UDEV_SHIM" || log "!! 缺 $UDEV_SHIM"
else
    log "!! /pkgs.tar.gz 未注入（检查 PKG_TARBALL 环境变量）"
fi

# ==================================================== B. 运行态清理（沿用第三轮修正）
mkdir -p "$RD" 2>/dev/null
chmod 700 "$RD" 2>/dev/null
mkdir -p /tmp/.X11-unix 2>/dev/null
chmod 1777 /tmp/.X11-unix 2>/dev/null
mkdir -p /run/udev/data 2>/dev/null
printf 'E:ID_INPUT=1\nE:ID_INPUT_MOUSE=1\nE:ID_SEAT=seat0\n' > /run/udev/data/c13:1 2>/dev/null
printf 'E:ID_INPUT=1\nE:ID_INPUT_KEYBOARD=1\nE:ID_SEAT=seat0\n' > /run/udev/data/c13:2 2>/dev/null

log "===== B. 清理陈旧运行态 ===="
rm -f /run/seatd.sock "$RD"/wayland-* "$RD"/wayland-*.lock 2>/dev/null
log "/run/seatd.sock 存在=$([ -e /run/seatd.sock ] && echo yes || echo no)"

# ==================================================== C. 主方案：双 shim
WINNER=""
log "===== C. 主方案: LD_PRELOAD=(libseat + libudev) 双 shim ===="
log "LD_PRELOAD=$SEAT_SHIM $UDEV_SHIM"
rm -f /root/weston-6.log /root/weston-6-stdout.log

env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 \
    LD_PRELOAD="$SEAT_SHIM $UDEV_SHIM" \
    weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
    --seat=seat0 --continue-without-input --idle-time=0 \
    --log=/root/weston-6.log > /root/weston-6-stdout.log 2>&1 &
W6=$!
log "weston pid=$W6"

i=0
while [ "$i" -lt 150 ]; do
    [ -S "$RD/wayland-0" ] && break
    [ -d /proc/$W6 ] || break
    i=$((i + 1))
    sleep 0.2
done

if [ -d /proc/$W6 ] && [ -S "$RD/wayland-0" ]; then
    WINNER="6"
    log "SCHEME6_OK pid=$W6 socket=$RD/wayland-0（等待 ${i} × 0.2s）"
    echo "SCHEME6_OK" > /dev/console
else
    log "!! 双 shim 方案失败：进程存活=$([ -d /proc/$W6 ] && echo yes || echo no) socket=$([ -S "$RD/wayland-0" ] && echo yes || echo no)"
fi

# 无论成败都打印两侧日志（失败时是诊断；成功时是"走到哪一步"的证据）
log "--- weston-6.log 尾部（weston 自身，成功时会打 Output/CRTC/mode）---"
tail -35 /root/weston-6.log >> "$LOG" 2>&1
tail -35 /root/weston-6.log > /dev/console 2>&1
log "--- weston-6-stdout.log 尾部（★ 两个 shim 的日志都在这里）---"
tail -35 /root/weston-6-stdout.log >> "$LOG" 2>&1
tail -35 /root/weston-6-stdout.log > /dev/console 2>&1

# ==================================================== D. 成功后的客户端与观察
if [ -n "$WINNER" ]; then
    log "===== Weston 起飞：关键日志行 ===="
    grep -aE 'Output|Connector|CRTC|enabled|pixman|mode |repaint|DRM|fatal|error' \
        /root/weston-6.log >> "$LOG" 2>&1
    grep -aE 'Output|enabled|fatal|CRTC|mode|using /dev' /root/weston-6.log > /dev/console 2>&1

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
        ALIVE=no; [ -d /proc/$W6 ] && ALIVE=yes
        SOCK=no;  [ -S "$RD/wayland-0" ] && SOCK=yes
        log "+$((n * 30))s weston_alive=$ALIVE socket=$SOCK lines=$(wc -l < /root/weston-6.log 2>/dev/null)"
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

# 统一日志名（回收清单登记的是 /root/weston.log）
{
    echo "===== weston-6.log ====="
    cat /root/weston-6.log 2>/dev/null
    echo "===== weston-6-stdout.log (shim 日志) ====="
    cat /root/weston-6-stdout.log 2>/dev/null
} > /root/weston.log 2>&1

log "autorun_weston6 done winner=[$WINNER]"
sync
sync
