#!/bin/sh
# autorun_probe.sh —— 纯探针轮（不起 weston / 不起 Chromium，只要 errno 事实）
#
# 用途：补丁/探针迭代时的快速回路。guest 启动后直接跑探针并汇总判定行，
#       几秒内即可出结果，避免为此开一整轮 700s 会话。
#
# 用法：bash t490_round.sh <tag> 200 60 autorun_probe.sh compatprobe.c nvprobe.c

LOG=/root/probe.log
: > "$LOG"
log() {
    echo "[pr] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}
tl() { "$@" 2>&1 | tee -a "$LOG" /dev/console; }

log "start uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"

# ★ 探针输出不要 `probe | tee`：stdout 变管道后 stdio 转**全缓冲**，
#   进程若在结束前死掉，缓冲区内容全丢（r5 轮 compatprobe 的输出就是这样丢的）。
#   改为「导到独立文件 → 再把文件倒到串口」，并配合探针自身 setvbuf(_IONBF)。
for p in /hangprobe /memprobe /compatprobe /nvprobe /p2probe /evprobe; do
    if [ -x "$p" ]; then
        n=$(basename "$p")
        OUT=/root/probe-$n.out
        log "===== 探针 $p ====="
        # ★ 后台跑 + 有界等待：探针若卡住，autorun 不能跟着永远等下去
        "$p" > "$OUT" 2>&1 &
        pp=$!
        j=0
        while [ "$j" -lt 45 ]; do
            [ -d /proc/$pp ] || break
            j=$((j + 1)); sleep 1
        done
        if [ -d /proc/$pp ]; then
            log "  !! $p 超过 ${j}s 未返回 → 判定 HUNG，kill -9"
            kill -9 "$pp" 2>/dev/null
            sleep 1
            RC="HUNG"
        else
            wait "$pp"; RC=$?
        fi
        log "  $p 结果=$RC 输出 $(wc -c < "$OUT" 2>/dev/null) 字节（等待 ${j}s）"
        tr -d '\r' < "$OUT" >> "$LOG"
        cat "$OUT" > /dev/console 2>&1
        log "----- $p 判定行 -----"
        grep -aE "^\[HP\]|^\[MP\]|^\[MPSUM\]|^\[CP\]|^\[CPSUM\]|^\[NV\] T[0-9]|^\[SCHED\]|^\[NETLINK\]|^\[EVSUM\]|^\[EVMAP\]|^\[RESULT\]" "$OUT" | tail -80 > /dev/console 2>&1
    else
        log "  跳过（未注入）: $p"
    fi
done

log "===== 汇总（只看判定行）====="
grep -aE "STEP_OK|ALL_STEPS_REACHED|PASS|FAIL|^\[MPSUM\]|^\[CPSUM\]|^\[RESULT\]" "$LOG" | tail -80 > /dev/console 2>&1

# 保持会话存活，便于 run-session 的周期 screendump 与后续 watcher（本模式不需要）
n=0
while [ "$n" -lt 8 ]; do
    { echo "=== $(date 2>/dev/null) (+$((n * 30))s) 探针轮 ==="; } >> /root/probe-watch.log 2>&1
    sync
    n=$((n + 1))
    sleep 30
done
log "autorun_probe done"
sync
sync
