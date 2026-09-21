#!/bin/sh
# autorun v5 (T490) — guest 侧总控
#   日志双通道：/dev/console（串口实时）+ /root/autorun.log（ext4 持久化）
#   本轮新增：
#     * drmprobe 探针（open/ioctl errno 定位）
#     * seatd 每轮清理（避免残留污染）→ 会话 6 的形态 B 失败
#     * weston 依次尝试 card0 简写 / 绝对路径
#     * headless backend 对照组（隔离"weston 本体"与"DRM backend"）
#     * sync && sleep 10 && sync 纪律
LOG=/root/autorun.log
: > "$LOG"
log() {
    echo "[autorun] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}
dump2() {   # 命令输出同时进串口和持久日志
    "$@" > /dev/console 2>&1
    "$@" >> "$LOG" 2>&1
}

log "start (v12-T490)"

# ---------- 0. 运行时伪造 sysfs（libdrm 设备枚举 + libudev 设备查询依赖）----------
fake_sysfs() {
    # --- libdrm faux 总线分支：readlink(subsystem) 末段匹配 "/faux" 即 DRM_BUS_FAUX ---
    mkdir -p /sys/dev/char/226:0/device 2>/dev/null
    ln -sf ../../faux /sys/dev/char/226:0/device/subsystem 2>/dev/null
    # realpath 解析目标目录真实存在（保险）
    mkdir -p /sys/devices/simpledrm /sys/bus/faux 2>/dev/null
    # --- libudev：/sys/class/drm/card0（uevent/dev/subsystem/device）---
    mkdir -p /sys/class/drm/card0 2>/dev/null
    printf 'MAJOR=226\nMINOR=0\nDEVNAME=dri/card0\nSUBSYSTEM=drm\nDEVTYPE=drm_minor\n' \
        > /sys/class/drm/card0/uevent 2>/dev/null
    printf '226:0\n' > /sys/class/drm/card0/dev 2>/dev/null
    ln -sf ../../bus/faux /sys/class/drm/card0/subsystem 2>/dev/null
    printf 'drm 1.1.0 simpledrm 1.0.0\n' > /sys/class/drm/version 2>/dev/null
}
fake_sysfs
if [ -e /sys/class/drm/card0/uevent ]; then
    log "sysfs 伪造 OK: uevent/dev/subsystem 就位"
    log "  uevent 内容: $(cat /sys/class/drm/card0/uevent 2>/dev/null | tr '\n' ' ')"
    log "  readlink subsystem: $(readlink /sys/dev/char/226:0/device/subsystem 2>&1)"
    log "  realpath 诊断: $(realpath /sys/dev/char/226:0/device 2>&1)"
    log "  ls /sys/dev/char/226:0/: $(ls /sys/dev/char/226:0/ 2>&1 | tr '\n' ' ')"
else
    log "sysfs 伪造失败（/sys 不可写？）"
fi

# ---------- 0. 设备与节点诊断 ----------
log "===== /dev/dri | /dev/fb0 | /dev/input ====="
ls -l /dev/dri/ /dev/fb0 /dev/input/ > /dev/console 2>&1
ls -l /dev/dri/ /dev/fb0 /dev/input/ >> "$LOG" 2>&1
log "===== /proc/devices (drm/misc/fb) ====="
grep -iE 'drm|misc|fb' /proc/devices > /dev/console 2>&1
grep -iE 'drm|misc|fb' /proc/devices >> "$LOG" 2>&1
log "===== drmprobe: open/ioctl errno ====="
if [ -x /drmprobe ]; then
    /drmprobe > /dev/console 2>&1
    /drmprobe >> "$LOG" 2>&1
else
    log "drmprobe NOT FOUND"
fi

# ---------- 1. bootstrap：包已装则跳过（避免 apk 依赖求解在 TCG 下卡 CPU）----------
if command -v weston >/dev/null 2>&1 && [ -x /usr/lib/libweston-14/drm-backend.so ]; then
    log "weston 已安装，跳过 bootstrap（本镜像已预装）"
else
    sh /root/bootstrap.sh >> "$LOG" 2>&1
    log "bootstrap rc=$?"
fi
sync; sleep 5; sync
log "sync done (after bootstrap)"

# ---------- 2. VT 修复 + seatd 干净重启 + udev 伪造 ----------
# 实测根因：seatd 代理打开 DRM 设备前必须绑定 VT（open("/dev/tty0")）。
# x-kernel 无 4:0 驱动（mknod 出节点 open 得 ENXIO），故改为符号链接到已存在的 tty 设备。
if [ ! -e /dev/tty0 ]; then
    log "构造 /dev/tty0 -> /dev/tty（符号链接，mknod 的 4:0 在 x-kernel 无驱动）"
    ln -sf /dev/tty /dev/tty0 2>>"$LOG" && log "  link OK" || log "  link FAILED"
    [ -e /dev/tty0 ] || { ln -sf /dev/console /dev/tty0; log "  fallback link -> /dev/console"; }
fi
ls -l /dev/tty0 > /dev/console 2>&1
ls -l /dev/tty  > /dev/console 2>&1
ls -l /dev/tty0 >> "$LOG" 2>&1

pkill -x seatd 2>/dev/null
rm -f /run/seatd.sock
sleep 1
mkdir -p /run/user/0 /tmp/.X11-unix /run/udev/data
chmod 700 /run/user/0
chmod 1777 /tmp/.X11-unix
printf 'E:ID_INPUT=1\nE:ID_INPUT_KEYBOARD=1\nE:ID_SEAT=seat0\n' > /run/udev/data/c13:1
printf 'E:ID_INPUT=1\nE:ID_INPUT_MOUSE=1\nE:ID_SEAT=seat0\n'    > /run/udev/data/c13:2
seatd -g root -l debug > /tmp/seatd.log 2>&1 &
sleep 3
log "seatd pid=$(pgrep -x seatd | head -n1) socket=$([ -S /run/seatd.sock ] && echo yes || echo no)"

# ---------- 3. weston 三轮尝试：seatd+card0 → seatd+绝对路径 → builtin(绕过 seatd) ----------
WESTON_UP=0
try_weston() {
    # $1=描述 $2=设备写法 $3=额外 env（可空）
    pgrep -x weston >/dev/null 2>&1 && { pkill -x weston; sleep 2; }
    rm -f /run/user/0/wayland-* /tmp/weston.log
    log "--- weston try: $1 (dev=$2 env=$3) ---"
    if [ -n "$3" ]; then
        env $3 XDG_RUNTIME_DIR=/run/user/0 WESTON_DISABLE_ATOMIC=1 weston \
            --backend=drm-backend.so --renderer=pixman --drm-device="$2" \
            --seat=seat0 --continue-without-input --idle-time=0 \
            --log=/tmp/weston.log >/dev/console 2>&1 &
    else
        env XDG_RUNTIME_DIR=/run/user/0 WESTON_DISABLE_ATOMIC=1 weston \
            --backend=drm-backend.so --renderer=pixman --drm-device="$2" \
            --seat=seat0 --continue-without-input --idle-time=0 \
            --log=/tmp/weston.log >/dev/console 2>&1 &
    fi
    i=0
    while [ "$i" -lt 10 ]; do
        [ -S /run/user/0/wayland-0 ] && { WESTON_UP=1; break; }
        pgrep -x weston >/dev/null 2>&1 || break
        i=$((i + 1)); sleep 1
    done
    if [ "$WESTON_UP" = "1" ]; then
        log "weston UP via $1"
    else
        log "  -> failed. weston.log tail:"
        tail -n 18 /tmp/weston.log > /dev/console 2>&1
        tail -n 18 /tmp/weston.log >> "$LOG" 2>&1
        cp /tmp/weston.log "/root/weston-fail-$1.log" 2>/dev/null
    fi
}

# 尝试 1（主攻）：LD_PRELOAD shim（seat 层）+ 伪造 sysfs（udev 层）+ card0 简写
# ★ 关键：udev_device_new_from_subsystem_sysname(udev, "drm", name) 的 name 必须是
#   sysfs 名（card0），不能带 /dev/dri 前缀（v13-v15 教训：绝对路径 → syspath 拼接失败）
if [ "$WESTON_UP" != "1" ] && [ -f /usr/local/lib/libseat-shim.so ]; then
    log "===== 尝试 1（主攻）：libseat-shim + 伪造 sysfs + card0 简写 ====="
    log "sysfs 伪造检查: $(ls -l /sys/class/drm/card0/dev 2>&1 | tr -s ' ')"
    try_weston "shim-card0" "card0" "LD_PRELOAD=/usr/local/lib/libseat-shim.so"
fi

# 尝试 2/3：seatd 路线（已知受 VT 限制，保留作对照）
[ "$WESTON_UP" = "1" ] || try_weston "seatd-card0" "card0" ""
[ "$WESTON_UP" = "1" ] || try_weston "seatd-abspath" "/dev/dri/card0" ""

# 尝试 4：shim + strace —— 抓 weston 的 syscall 轨迹，定位设备发现路径
if [ "$WESTON_UP" != "1" ] && [ -x /usr/bin/strace ] && [ -f /usr/local/lib/libseat-shim.so ]; then
    log "===== 尝试 4：shim + strace（syscall 轨迹）====="
    pkill -x weston 2>/dev/null; sleep 1
    rm -f /run/user/0/wayland-* /tmp/weston.strace
    env LD_PRELOAD=/usr/local/lib/libseat-shim.so XDG_RUNTIME_DIR=/run/user/0 WESTON_DISABLE_ATOMIC=1 \
        strace -f -o /tmp/weston.strace -e trace=openat,open,connect,readlink,access \
        weston --backend=drm-backend.so --renderer=pixman --drm-device=/dev/dri/card0 \
        --seat=seat0 --continue-without-input --idle-time=0 \
        --log=/tmp/weston.log >/dev/console 2>&1 &
    i=0
    while [ "$i" -lt 12 ]; do
        [ -S /run/user/0/wayland-0 ] && { WESTON_UP=1; break; }
        i=$((i + 1)); sleep 1
    done
    [ "$WESTON_UP" = "1" ] || pkill -x weston 2>/dev/null
    log "----- strace: card0/drm/sys 相关行 -----"
    grep -aE "card0|/drm|sys/|/dri" /tmp/weston.strace 2>/dev/null | tail -40 > /dev/console
    grep -aE "card0|/drm|sys/|/dri" /tmp/weston.strace 2>/dev/null | tail -40 >> "$LOG"
    log "----- strace 尾部 15 行 -----"
    tail -15 /tmp/weston.strace > /dev/console 2>/dev/null
    tail -15 /tmp/weston.strace >> "$LOG" 2>/dev/null
fi

# 附：seatd 日志（若 seatd 侧拒绝/报错，这里是证据）
if [ -f /tmp/seatd.log ]; then
    log "===== seatd.log tail ====="
    tail -n 15 /tmp/seatd.log > /dev/console 2>&1
    tail -n 15 /tmp/seatd.log >> "$LOG" 2>&1
fi

# ---------- 4. 对照组：headless backend（隔离 weston 本体 vs DRM backend）----------
if [ "$WESTON_UP" != "1" ] && [ -f /usr/lib/libweston-14/headless-backend.so ]; then
    log "===== headless 对照组 ====="
    pkill -x weston 2>/dev/null; sleep 1
    rm -f /run/user/0/wayland-*
    env XDG_RUNTIME_DIR=/run/user/0 weston \
        --backend=headless-backend.so --renderer=pixman --width=800 --height=560 \
        --idle-time=0 --log=/tmp/weston-headless.log >/dev/console 2>&1 &
    j=0
    while [ "$j" -lt 10 ]; do
        [ -S /run/user/0/wayland-0 ] && break
        j=$((j + 1)); sleep 1
    done
    if [ -S /run/user/0/wayland-0 ]; then
        log "headless weston UP -> weston 本体与 wayland socket 逻辑正常，问题局限在 DRM backend"
    else
        log "headless weston FAILED -> 问题在 weston/seat 集成层，而非 DRM 设备本身"
        tail -n 20 /tmp/weston-headless.log > /dev/console 2>&1
    fi
fi

if [ -S /run/user/0/wayland-0 ]; then
    touch /tmp/stage-weston-up
    log "weston socket ready (mode=$([ "$WESTON_UP" = "1" ] && echo DRM || echo HEADLESS))"
else
    touch /tmp/stage-weston-failed
    log "weston NOT up on any route"
fi

# ---------- 5. Chromium 安装（仅当存在标记文件 /root/install-chromium 时；避免 TCG 下 solver 卡顿）----------
if [ -f /root/install-chromium ]; then
    log "installing/repairing chromium（标记文件存在）"
    apk add chromium chromium-swiftshader font-noto-cjk >> "$LOG" 2>&1
    log "chromium install rc=$?"
    sync; sleep 20; sync
    log "sync done (after chromium) size=$(ls -l /usr/lib/chromium/chromium 2>/dev/null | awk '{print $5}')"
else
    log "跳过 chromium 安装（未放置 /root/install-chromium 标记）"
    log "现状: $(ls -l /usr/lib/chromium/chromium 2>/dev/null | awk '{print $5}') bytes"
fi
touch /tmp/stage-chromium-done

# ---------- 6. Chromium 启动（wayland socket 存在即尝试）----------
if [ -S /run/user/0/wayland-0 ]; then
    log "launching chromium (--ozone-platform=wayland)"
    env XDG_RUNTIME_DIR=/run/user/0 WAYLAND_DISPLAY=wayland-0 \
        chromium --ozone-platform=wayland --no-sandbox --disable-gpu \
            --disable-dev-shm-usage --no-first-run --no-default-browser-check \
            --window-size=800,560 file:///root/index.html >/root/chromium.log 2>&1 &
    sleep 15
    log "chromium proc: $(pgrep -f 'chromium' | head -n3 | tr '\n' ' ')"
else
    log "chromium NOT launched (no wayland socket)"
fi
sync
log "all done"
