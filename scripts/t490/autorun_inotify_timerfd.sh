#!/bin/sh
# Focused inotify/timerfd compatibility round; run the same static probe on Linux and x-kernel.

set -u
LOG=/root/inotify-timerfd-probe.log
: > "$LOG"

if [ ! -x /compatprobe ]; then
    echo "[COMPAT] missing /compatprobe" > /dev/console 2>/dev/null
else
    /compatprobe --inotify-timerfd > "$LOG" 2>&1
    rc=$?
    cat "$LOG" > /dev/console 2>&1
    echo "[COMPAT] inotify_timerfd_rc=$rc" > /dev/console 2>/dev/null
fi

sync
n=0
while [ "$n" -lt 8 ]; do
    echo "[COMPAT] hold tick=$n uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)" > /dev/console 2>/dev/null
    sync
    n=$((n + 1))
    sleep 30
done
sync
