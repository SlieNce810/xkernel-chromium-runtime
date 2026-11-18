#!/bin/sh
# Focused AF_UNIX stream SCM_RIGHTS first-byte short-read compatibility round.

set -u
LOG=/root/scm-rights-shortread.log
: > "$LOG"

if [ ! -x /compatprobe ]; then
    echo "[COMPAT] missing /compatprobe" > /dev/console 2>/dev/null
else
    /compatprobe --scm-rights-shortread > "$LOG" 2>&1
    rc=$?
    cat "$LOG" > /dev/console 2>&1
    echo "[COMPAT] scm_rights_shortread_rc=$rc" > /dev/console 2>/dev/null
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
