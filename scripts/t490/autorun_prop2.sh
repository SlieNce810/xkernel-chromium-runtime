#!/bin/sh
# autorun_prop2.sh —— 只看一件事：GETPROPERTY 两段式在哪一段、以什么 errno 失败
# （weston10 轮已定位到"libdrm 的 drmModeGetProperty 对 12 个属性全部失败"，
#   本轮的 proptwostage 把它拆成 call#1 / call#2 逐段判定，并对照真实 libdrm）
LOG=/root/prop2.log
: > "$LOG"

log() {
    echo "[prop2] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}

log "kernel: $(uname -srm)"
log "===== proptwostage ====="
if [ -x /proptwostage ]; then
    /proptwostage > /root/prop2.out 2>&1 &
    p=$!
    j=0
    while [ "$j" -lt 90 ]; do
        [ -d /proc/$p ] || break
        j=$((j + 1)); sleep 1
    done
    if [ -d /proc/$p ]; then
        echo "!! HUNG -> kill -9" >> /root/prop2.out
        kill -9 "$p" 2>/dev/null
    fi
    cat /root/prop2.out >> "$LOG" 2>&1
    grep -aE '^\[STAGE_SUM\]|^\[PROBE_EXIT\]|libdrm 结果' /root/prop2.out > /dev/console 2>&1
else
    log "!! /proptwostage 未注入"
fi
log "PROP2_DONE"

n=0
while [ "$n" -lt 4 ]; do
    sync
    n=$((n + 1))
    sleep 12
done
log "prop2 收尾"
sync
