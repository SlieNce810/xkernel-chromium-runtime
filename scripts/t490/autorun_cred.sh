#!/bin/sh
# autorun_cred.sh —— G17 验收轮：SCM_CREDENTIALS 在 AF_UNIX 上的收发
#
# 用法：bash t490_round.sh credg17 200 60 autorun_cred.sh credprobe.c
#
# 只做一件事：跑 credprobe，把每个用例的 errno 事实与判定行落盘 + 上串口。
# 与 T490 原生跑同一份 credprobe.c 的结果逐条对照，即为「与 Linux 行为基线
# 的对比」证据（赛题第六节(一)「与 Linux 行为基线的对比分析 5 分」）。

LOG=/root/cred.log
: > "$LOG"
log() {
    echo "[cred] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}

log "start uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
log "guest uid=$(id -u 2>/dev/null) gid=$(id -g 2>/dev/null) kernel=$(uname -r 2>/dev/null)"

# ★ 探针输出不要 `probe | tee`：stdout 变管道后 stdio 转全缓冲，进程若在结束前
#   死掉缓冲区内容全丢。改为「先落文件 → 再倒到串口」。
if [ -x /credprobe ]; then
    OUT=/root/probe-credprobe.out
    log "===== /credprobe ====="
    /credprobe > "$OUT" 2>&1 &
    pp=$!
    j=0
    while [ "$j" -lt 45 ]; do
        [ -d /proc/$pp ] || break
        j=$((j + 1)); sleep 1
    done
    if [ -d /proc/$pp ]; then
        log "  !! credprobe 超过 ${j}s 未返回 → HUNG，kill -9"
        kill -9 "$pp" 2>/dev/null
        sleep 1
        RC="HUNG"
    else
        wait "$pp"; RC=$?
    fi
    log "  credprobe 结果=$RC 输出 $(wc -c < "$OUT" 2>/dev/null) 字节（等待 ${j}s）"
    tr -d '\r' < "$OUT" >> "$LOG"
    cat "$OUT" > /dev/console 2>&1
    log "----- 判定行 -----"
    grep -aE "^\[CRED\] T[0-9]|^\[RESULT\]" "$OUT" | tail -40 > /dev/console 2>&1
else
    log "!! /credprobe 未注入（检查 t490_round.sh 的 probe 参数）"
fi

# 另跑一次原生对照：guest 内没有 gcc，这里只记录 uid，供人工对照 T490 原生结果
log "对照：T490 原生 credprobe（uid=1000）为 pass=7 fail=0 ALL_PASS"

# 保持会话存活，便于 run-session 的周期 screendump
n=0
while [ "$n" -lt 6 ]; do
    { echo "=== $(date 2>/dev/null) (+$((n * 30))s) G17 探针轮 ==="; } >> /root/cred-watch.log 2>&1
    sync
    n=$((n + 1))
    sleep 30
done
log "autorun_cred done"
sync
sync
