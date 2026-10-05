#!/bin/sh
# autorun_std3.sh —— 阶段 2：真实 libudev + 真实 seatd/libseat 验证（**全程无 shim**）
#
# 判据（对应放行条件 G2）
#   A. 内核 sysfs 投射自证：/sys/class/drm/card0/{dev,uevent,subsystem} 与 /sys/dev/char/226:0
#   B. 真实 libudev（eudev 1.6.3）按子系统+sysname 查询、枚举、取 devnode/devnum
#   C. 真实 seatd 启动（SEATD_VTBOUND=0，seatd 官方单 seat 配置）
#   D. 真实 libseat 经 seatd 拿到可用的 DRM FD（SCM_RIGHTS 传递 + 能跑 ioctl）
#
# 本轮**不加载任何 LD_PRELOAD shim**（对照轮：此前 weston6/7/8 靠双 shim 才能 open 设备）。

LOG=/root/std3.log
: > "$LOG"

log() {
    echo "[std3] $*" > /dev/console 2>/dev/null
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

log "===== A. 内核 sysfs 投射自证 ====="
log "LD_PRELOAD=[${LD_PRELOAD:-<空>}]（本轮不得有任何 shim）"
log "/sys/class       : $(ls /sys/class 2>/dev/null | tr '\n' ' ')"
log "/sys/class/drm   : $(ls /sys/class/drm 2>/dev/null | tr '\n' ' ')"
log "/sys/class/drm/card0 : $(ls /sys/class/drm/card0 2>/dev/null | tr '\n' ' ')"
log "card0/dev   = [$(cat /sys/class/drm/card0/dev 2>/dev/null | tr -d '\n')]"
log "card0/uevent= [$(cat /sys/class/drm/card0/uevent 2>/dev/null | tr '\n' '|')]"
log "card0/subsystem -> $(readlink /sys/class/drm/card0/subsystem 2>/dev/null)"
log "/sys/dev/char    : $(ls /sys/dev/char 2>/dev/null | tr '\n' ' ')"
log "/sys/dev/char/226:0 -> $(readlink /sys/dev/char/226:0 2>/dev/null)"

log "===== B. 真实 libudev（无 shim）====="
if [ -x /udevprobe ]; then
    run_guard /root/std3-udevprobe.out 120 /udevprobe
    log "udevprobe rc=$?"
    grep -aE '^\[UDEV\]|^\[UDEV_EXIT\]' /root/std3-udevprobe.out | sed 's/^/  /' >> "$LOG" 2>&1
else
    log "!! /udevprobe 未注入"
fi

log "===== C. 真实 seatd 启动（SEATD_VTBOUND=0）====="
rm -f /run/seatd.sock 2>/dev/null
mkdir -p /run 2>/dev/null
SEATD_VTBOUND=0 seatd -l debug > /root/std3-seatd.log 2>&1 &
SP=$!
sleep 2
log "seatd pid=$SP alive=$([ -d /proc/$SP ] && echo yes || echo no) socket=$([ -S /run/seatd.sock ] && echo yes || echo no)"
log "seatd -h: $(seatd -h 2>&1 | tr '\n' ' ' | cut -c1-150)"
head -12 /root/std3-seatd.log >> "$LOG" 2>&1

log "===== D. 真实 libseat → seatd → DRM FD ====="
if [ -x /seatprobe ]; then
    LIBSEAT_BACKEND=seatd SEATD_SOCK=/run/seatd.sock \
        run_guard /root/std3-seatprobe.out 90 /seatprobe
    log "seatprobe rc=$?"
    grep -aE '^\[SEAT\]|^\[SEAT_EXIT\]' /root/std3-seatprobe.out | sed 's/^/  /' >> "$LOG" 2>&1
else
    log "!! /seatprobe 未注入"
fi

log "===== E. 汇总（机器行）====="
for f in /root/std3-udevprobe.out /root/std3-seatprobe.out; do
    [ -f "$f" ] || continue
    log "--- $f ---"
    grep -aE '^\[UDEV_EXIT\]|^\[SEAT_EXIT\]' "$f" >> "$LOG" 2>&1
done
log "STD3_DONE"

# 让 seatd 再活一会儿（供观察），然后收尾
n=0
while [ "$n" -lt 4 ]; do
    sync
    n=$((n + 1))
    sleep 15
done
kill "$SP" 2>/dev/null
log "std3 收尾（seatd 已停）"
sync
