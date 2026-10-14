#!/bin/sh
# POSIX guest payload: the Alpine image does not require Bash.
set -u
trap '' PIPE
LOG=/root/submission-gaps.log
: > "$LOG"
echo "[SUBMISSION_GAPS] start" > /dev/console
for name in submission_gap_probe compatprobe sandboxipcprobe fdprobe seqpacketprobe evprobe; do
    if [ ! -x "/$name" ]; then
        echo "[SUBMISSION_GAPS] NOT_INJECTED=$name" >> "$LOG"
        continue
    fi
    out="/root/submission-gap-$name.out"
    "/$name" > "$out" 2>&1 &
    probe_pid=$!
    elapsed=0
    while [ "$elapsed" -lt 45 ] && [ -d "/proc/$probe_pid" ]; do
        sleep 1
        elapsed=$((elapsed + 1))
    done
    if [ -d "/proc/$probe_pid" ]; then
        kill -9 "$probe_pid" 2>/dev/null || true
        wait "$probe_pid" 2>/dev/null || true
        result=TIMEOUT
    else
        wait "$probe_pid"
        result=$?
    fi
    printf '[SUBMISSION_GAPS] probe=%s exit=%s\n' "$name" "$result" >> "$LOG"
    cat "$out" >> "$LOG"
    cat "$out" > /dev/console
    printf '[SUBMISSION_GAPS] probe=%s exit=%s\n' "$name" "$result" > /dev/console
    sync
done
echo "[SUBMISSION_GAPS] END" >> "$LOG"
cat "$LOG" > /dev/console
sync
