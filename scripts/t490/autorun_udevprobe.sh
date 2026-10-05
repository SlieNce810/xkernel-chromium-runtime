#!/bin/sh
set -u
LOG=/root/udevprobe.log
: > "$LOG"
echo "[udevprobe] start" >> "$LOG"
mkdir -p /run/udev/data /run/user/0 /tmp/.X11-unix 2>/dev/null || true
if command -v udevd >/dev/null 2>&1; then
    echo "[udevprobe] udevd=$(command -v udevd)" >> "$LOG"
    udevd --debug >> /root/udevd-probe.log 2>&1 &
    UDEV_PID=$!
    echo "[udevprobe] pid=$UDEV_PID" >> "$LOG"
    sleep 1
    udevadm trigger --action=add --subsystem-match=input >> /root/udevadm-trigger-probe.log 2>&1 || echo "[udevprobe] trigger_rc=$?" >> "$LOG"
    udevadm settle --timeout=8 >> /root/udevadm-settle-probe.log 2>&1 || echo "[udevprobe] settle_rc=$?" >> "$LOG"
else
    echo "[udevprobe] udevd missing" >> "$LOG"
fi
ls -la /dev/input /sys/class/input >> "$LOG" 2>&1 || true
cat /root/udevd-probe.log /root/udevadm-trigger-probe.log /root/udevadm-settle-probe.log >> "$LOG" 2>&1 || true
cat "$LOG" > /dev/console 2>&1
