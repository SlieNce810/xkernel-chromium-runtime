#!/bin/sh
# Run focused inotify/timerfd, SCM_RIGHTS short-read, and procfs memory probes.

set -u
LOG=/root/compat-memory-bundle.log
: > "$LOG"
OVERALL_RC=0

log() {
    line="[COMPAT_BUNDLE] $*"
    echo "$line" >> "$LOG"
    echo "$line" > /dev/console 2>/dev/null || true
}

run_probe() {
    name=$1
    binary=$2
    shift 2
    log "START name=$name bin=$binary args=$* uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
    if [ ! -x "$binary" ]; then
        log "MISSING name=$name bin=$binary"
        OVERALL_RC=1
        return
    fi
    "$binary" "$@" >> "$LOG" 2>&1
    rc=$?
    log "END name=$name rc=$rc"
    [ "$rc" -eq 0 ] || OVERALL_RC=1
}

run_probe inotify_timerfd /compatprobe --inotify-timerfd
run_probe scm_rights_shortread /compatprobe --scm-rights-shortread
run_probe procfs_memory /procfs_memory_probe
log "RESULT overall_rc=$OVERALL_RC"
sync
cat "$LOG" > /dev/console 2>&1

n=0
while [ "$n" -lt 8 ]; do
    log "hold tick=$n uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
    sync
    n=$((n + 1))
    sleep 30
done
sync
exit "$OVERALL_RC"
