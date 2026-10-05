#!/bin/sh
# autorun_prop3.sh —— 用 ioctl 观测器同时跟踪【探针自己的调用】与【真实 libdrm 的调用】
#
# 为什么这么做（prop2 轮的事实）
#   同一个进程、同一个 fd、同一批 prop_id：
#     - 手写两段式（proptwostage 的 raw ioctl）: call#1/call#2 全部 rc=0
#     - 真实 libdrm `drmModeGetProperty`      : 12/12 失败，**errno=95**（未命中分派表）
#   两者只可能差在**请求值**上 ⇒ 必须把两边实际发出的 req 逐条打出来对照。
#
# 本轮：LD_PRELOAD=/iocspy.so 跑 proptwostage（iocspy 只观测，不改参数/返回值）
LOG=/root/prop3.log
: > "$LOG"

log() {
    echo "[prop3] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}

log "kernel: $(uname -srm)"
log "===== proptwostage + iocspy ====="
if [ -x /proptwostage ] && [ -f /iocspy.so ]; then
    LD_PRELOAD=/iocspy.so /proptwostage > /root/prop3.out 2>&1 &
    p=$!
    j=0
    while [ "$j" -lt 90 ]; do
        [ -d /proc/$p ] || break
        j=$((j + 1)); sleep 1
    done
    if [ -d /proc/$p ]; then
        echo "!! HUNG -> kill -9" >> /root/prop3.out
        kill -9 "$p" 2>/dev/null
    fi

    log "---- 关键行（[STAGE] 判定 + 每个属性的 req/rc）----"
    grep -aE '^\[STAGE' /root/prop3.out >> "$LOG" 2>&1

    log "---- ioctl 请求值分布（去重计数）----"
    grep -aoE 'req=0x[0-9a-f]+ dir=[0-9] size=[0-9]+ type=0x[0-9a-f]+ nr=0x[0-9a-f]+ -> rc=-?[0-9]+' /root/prop3.out \
        | sort | uniq -c | sort -rn >> "$LOG" 2>&1

    log "---- nr=0xa8（GETPROPERTY）的逐条请求 ----"
    grep -a '^\[IOC\]' /root/prop3.out | grep -a 'nr=0xa8' | head -30 >> "$LOG" 2>&1

    grep -aoE 'req=0x[0-9a-f]+ dir=[0-9] size=[0-9]+ type=0x[0-9a-f]+ nr=0x[0-9a-f]+ -> rc=-?[0-9]+' /root/prop3.out \
        | sort | uniq -c | sort -rn | head -12 > /dev/console 2>&1
else
    log "!! proptwostage 或 iocspy.so 缺失"
fi
log "PROP3_DONE"

n=0
while [ "$n" -lt 4 ]; do
    sync
    n=$((n + 1))
    sleep 12
done
log "prop3 收尾"
sync
