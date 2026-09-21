#!/bin/sh
# autorun_p1.sh — T490 · P1（stream SCM_RIGHTS）验收专用 guest 总控
#
# 为什么不用 autorun_v5.sh
# -----------------------
# autorun_v5.sh 是**多路线对照**脚本（shim / seatd / builtin / headless / strace 轮着试），
# 而且 T490 上的副本与本仓库副本已经不同步（T490 副本多了 builtin-abspath / headless，
# 却没能走到 shim 路线）。做因果判定时多路线反而有害——本轮只跑**一条**已知可用路线：
#
#     libseat-shim(LD_PRELOAD) + 伪造 sysfs + --drm-device=card0
#
# 这是 v16 首次把 compositor 拉起来的组合。要看的就是它能走多远：
# 补丁前卡在 `wl_shm.create_pool` 的 `file descriptor expected`，补丁后应能越过。
#
# 阶段
#   0  伪造 sysfs（/sys 是 memfs ramfs，运行时可写）
#   1  fdprobe：SCM_RIGHTS 跨进程 fd 传递判定
#   2  /run/user/0 + /tmp/.X11-unix 权限
#   3  seatd 干净重启
#   4  weston（单一路线）
#   5  界标提取（create_pool / desktop-shell / Virtual-1 / Quitting）
#   6  watcher 每 30s 快照 → /root/weston-watch.log
#
# 日志双写：/dev/console（串口实时）+ /root/autorun.log（ext4 持久，可 debugfs 只读窥视）

LOG=/root/autorun.log
WATCH=/root/weston-watch.log
: > "$LOG"
: > "$WATCH"

log() {
    echo "[p1] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}

log "start (p1-fdpass)  kernel=$(uname -r 2>/dev/null)  arch=$(uname -m 2>/dev/null)"
cat /proc/uptime > /dev/console 2>&1

# ---------------------------------------------------------------- 0. 伪造 sysfs
# libdrm 的 faux 总线分支要 readlink(subsystem) 末段为 /faux；
# libudev 无 daemon 时 fallback 直接读 sysfs，所以给出 dev/uevent/subsystem 三元组。
fake_sysfs() {
    mkdir -p /sys/dev/char/226:0/device 2>/dev/null
    ln -sf ../../faux /sys/dev/char/226:0/device/subsystem 2>/dev/null
    mkdir -p /sys/devices/simpledrm /sys/bus/faux 2>/dev/null
    mkdir -p /sys/class/drm/card0 2>/dev/null
    printf 'MAJOR=226\nMINOR=0\nDEVNAME=dri/card0\nSUBSYSTEM=drm\nDEVTYPE=drm_minor\n' \
        > /sys/class/drm/card0/uevent 2>/dev/null
    printf '226:0\n' > /sys/class/drm/card0/dev 2>/dev/null
    ln -sf ../../bus/faux /sys/class/drm/card0/subsystem 2>/dev/null
    printf 'drm 1.1.0 simpledrm 1.0.0\n' > /sys/class/drm/version 2>/dev/null
}
fake_sysfs
log "sysfs 伪造: card0/dev=$(cat /sys/class/drm/card0/dev 2>&1) subsystem=$(readlink /sys/class/drm/card0/subsystem 2>&1)"

log "===== 设备节点 ====="
ls -l /dev/dri/ /dev/fb0 /dev/input/ > /dev/console 2>&1
ls -l /dev/dri/ /dev/fb0 /dev/input/ >> "$LOG" 2>&1

# ---------------------------------------------------------------- 1. fdprobe
log "===== fdprobe: AF_UNIX SCM_RIGHTS 跨进程 fd 传递 ====="
if [ -x /fdprobe ]; then
    /fdprobe > /dev/console 2>&1
    /fdprobe >> "$LOG" 2>&1
    log "fdprobe 判定行:"
    grep -E "^\[T[0-9]\] T1_fd_count|^\[T[0-9]\] VERDICT|^\[RESULT\]|^\[SUMMARY\]" "$LOG" > /dev/console 2>&1
else
    log "fdprobe NOT FOUND"
fi

# ---------------------------------------------------------------- 2. 运行目录
mkdir -p /run/user/0 /tmp/.X11-unix 2>/dev/null
chmod 700 /run/user/0 2>/dev/null
chmod 1777 /tmp/.X11-unix 2>/dev/null
log "runtime dir: $(ls -ld /run/user/0 /tmp/.X11-unix 2>&1 | tr '\n' '|')"

# ---------------------------------------------------------------- 3. seatd
pkill -x weston 2>/dev/null
pkill -x seatd 2>/dev/null
sleep 1
rm -f /run/seatd.sock /tmp/weston.log /run/user/0/wayland-*
seatd -g root -l debug >/tmp/seatd.log 2>&1 &
sleep 2
log "seatd pid=$(pgrep -x seatd | head -n1) socket=$([ -S /run/seatd.sock ] && echo yes || echo no)"

# ---------------------------------------------------------------- 4. weston（单一路线）
if [ ! -f /usr/local/lib/libseat-shim.so ]; then
    log "!! /usr/local/lib/libseat-shim.so 缺失 —— 本路线无法成立，终止"
else
    log "===== weston: libseat-shim + 伪造 sysfs + --drm-device=card0 ====="
    env LD_PRELOAD=/usr/local/lib/libseat-shim.so XDG_RUNTIME_DIR=/run/user/0 WESTON_DISABLE_ATOMIC=1 \
        weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
        --seat=seat0 --continue-without-input --idle-time=0 \
        --log=/tmp/weston.log >/dev/console 2>&1 &

    i=0
    while [ "$i" -lt 15 ]; do
        [ -S /run/user/0/wayland-0 ] && break
        pgrep -x weston >/dev/null 2>&1 || break
        i=$((i + 1))
        sleep 1
    done

    if [ -S /run/user/0/wayland-0 ]; then
        log "weston UP: wayland-0 就位（${i}s），weston pid=$(pgrep -x weston | tr '\n' ' ')"
    else
        log "weston 未起来（${i}s）：日志尾部 ——"
        tail -n 30 /tmp/weston.log > /dev/console 2>&1
        tail -n 30 /tmp/weston.log >> "$LOG" 2>&1
    fi

    # ---------- 5. 关键界标 ----------
    log "===== weston.log 界标 ====="
    grep -nE "Output |Virtual-1|create_pool|file descriptor|desktop-shell|Quitting|cannot run|ERROR|fatal|Fontconfig" \
        /tmp/weston.log > /dev/console 2>&1
    grep -nE "Output |Virtual-1|create_pool|file descriptor|desktop-shell|Quitting|cannot run|ERROR|fatal|Fontconfig" \
        /tmp/weston.log >> "$LOG" 2>&1

    log "===== 进程快照 ====="
    ps 2>/dev/null | grep -E 'weston|seatd' | grep -v grep > /dev/console 2>&1
    ps 2>/dev/null | grep -E 'weston|seatd' | grep -v grep >> "$LOG" 2>&1
fi

# ---------------------------------------------------------------- 6. watcher
log "进入 watcher（每 30s 写 $WATCH）"
n=0
while [ "$n" -lt 40 ]; do
    {
        echo "=== $(date 2>/dev/null)  uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)  (+$((n * 30))s) ==="
        echo "weston:        $(pgrep -x weston | tr '\n' ' ')"
        echo "seatd:         $(pgrep -x seatd | tr '\n' ' ')"
        echo "desktop-shell: $(pgrep -f weston-desktop-shell | tr '\n' ' ')"
        echo "Xwayland:      $(pgrep -x Xwayland | tr '\n' ' ')"
        echo "chromium:      $(pgrep -x chromium | tr '\n' ' ')"
        echo "wayland-0:     $([ -S /run/user/0/wayland-0 ] && echo yes || echo no)"
        ps 2>/dev/null | grep -E 'weston|seatd|chromium|Xwayland' | grep -v grep
    } >> "$WATCH" 2>&1
    n=$((n + 1))
    sleep 30
done

log "watcher 结束（$n 轮）"
sync
sync
log "p1 autorun done"
