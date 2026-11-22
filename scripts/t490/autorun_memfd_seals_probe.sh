#!/bin/sh
# Run the focused memfd/sealing compatibility probe and preserve its raw rows.
set -u

LOG=/root/memfd-seals-probe.log
: > "$LOG"
echo "[MEMFD_SEALS] START" > /dev/console 2>/dev/null || true

if [ -x /memfd_seals_probe ]; then
    /memfd_seals_probe >> "$LOG" 2>&1
    RC=$?
else
    echo "[MF] probe binary missing: /memfd_seals_probe" >> "$LOG"
    RC=127
fi

cat "$LOG" > /dev/console 2>&1 || true
echo "[MEMFD_SEALS] RC=$RC" > /dev/console 2>/dev/null || true
sync
exit "$RC"
