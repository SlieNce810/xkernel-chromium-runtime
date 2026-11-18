#!/bin/sh
# Focused procfs memory-accounting probe for Linux and x-kernel.

set -u
LOG=/root/procfs-memory-probe.log
: > "$LOG"

if [ ! -x /procfs_memory_probe ]; then
    echo "[MEMPROBE] missing /procfs_memory_probe" > /dev/console 2>/dev/null
else
    /procfs_memory_probe > "$LOG" 2>&1
    rc=$?
    cat "$LOG" > /dev/console 2>&1
    echo "[MEMPROBE] rc=$rc" > /dev/console 2>/dev/null
fi

sync
n=0
while [ "$n" -lt 8 ]; do
    echo "[MEMPROBE] hold tick=$n uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)" > /dev/console 2>/dev/null
    sync
    n=$((n + 1))
    sleep 30
done
sync
