#!/bin/sh
# autorun_std1.sh —— 阶段 1.2：在当前内核上取得「标准客户端失败」的 before 证据
#
# 三条互相独立的证据链（同一轮、同一镜像、同一内核）：
#   B. /drmplaneprobe   静态、**标准 32B 布局**的手写 ioctl → 预期 GETPLANE_FAIL
#   C. /drmstdprobe     动态、guest 自带 libdrm 2.4.124 的标准调用 → 预期 STD_FAIL
#   D. LD_PRELOAD=/iocspy.so /drmstdprobe → 直接记录 libdrm 发出的**真实请求值**
#      （预期 req=0xc02064b6 size=32；内核若只认 0xc03064b6 则必然 errno=95）
#
# 为什么三条都要：B 证明"内核接受的编码"，C 证明"标准客户端的编码能否通过"，
# D 把"libdrm 到底发了什么"从源码推断变成运行期事实 —— 缺任何一条都无法排除
# 「探针与内核同错」这类假绿（report/31→32 的教训）。
#
# 注意：本文件正文不得出现双下划线包裹的占位符（t490_round.sh 会做残留硬校验）。

LOG=/root/std1.log
: > "$LOG"

log() {
    echo "[std1] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}

# 带看门狗的运行：$1=输出文件 $2=秒上限 $3..=命令
#   本 guest 无 pkill 语义保证，统一用 /proc/<pid> 判存活 + kill -9。
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

log "===== A. 环境自证 ====="
log "kernel: $(uname -srm 2>/dev/null)"
log "dri: $(ls /dev/dri 2>/dev/null | tr '\n' ' ')"
if [ -f /lib/ld-musl-aarch64.so.1 ]; then
    log "ld-musl-aarch64.so.1: OK"
else
    log "!! 缺 /lib/ld-musl-aarch64.so.1 —— 动态探针无法运行"
fi
ls -l /usr/lib/libdrm.so.2* >> "$LOG" 2>&1

log "===== B. 手写 ioctl 探针（标准 32B 布局，静态）====="
if [ -x /drmplaneprobe ]; then
    run_guard /root/std1-planeprobe.out 90 /drmplaneprobe
    log "drmplaneprobe rc=$?"
    grep -aE '^\[PROBE_ABI\]|^\[PRES\]|^\[PLANE\] GETPLANE|^\[PLANESUM\]|^\[PROBE_EXIT\]' \
        /root/std1-planeprobe.out >> "$LOG" 2>&1
else
    log "!! /drmplaneprobe 未注入"
fi

log "===== C. 标准 libdrm 客户端（动态链接 guest 的 libdrm）====="
if [ -x /drmstdprobe ]; then
    run_guard /root/std2-drmstdprobe.out 120 /drmstdprobe
    log "drmstdprobe rc=$?"
    sed 's/^/  /' /root/std2-drmstdprobe.out >> "$LOG" 2>&1
else
    log "!! /drmstdprobe 未注入"
fi

log "===== D. 同一调用 + ioctl 观测器（LD_PRELOAD=iocspy.so）====="
if [ -f /iocspy.so ] && [ -x /drmstdprobe ]; then
    run_guard /root/std3-iocspy.out 120 env LD_PRELOAD=/iocspy.so /drmstdprobe
    log "iocspy+drmstdprobe rc=$?"
    grep -aE '^\[IOC\]|^\[STD\]|^\[STD_EXIT\]' /root/std3-iocspy.out | sed 's/^/  /' >> "$LOG" 2>&1
else
    log "!! /iocspy.so 或 /drmstdprobe 缺失"
fi

log "===== E. 汇总（机器行）====="
for f in /root/std1-planeprobe.out /root/std2-drmstdprobe.out /root/std3-iocspy.out; do
    [ -f "$f" ] || continue
    log "--- $f ---"
    grep -aE '^\[PROBE_EXIT\]|^\[STD_EXIT\]|^\[PROBE_ABI\]|^\[PLANESUM\]' "$f" >> "$LOG" 2>&1
done
log "STD1_DONE winner=none（本轮只取证，不启动 Weston）"

n=0
while [ "$n" -lt 4 ]; do
    sync
    n=$((n + 1))
    sleep 15
done
log "std1 收尾（保持会话存活供 screendump）"
sync
