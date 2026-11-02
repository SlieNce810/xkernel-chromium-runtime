#!/bin/sh
# Decision-round DRM inventory. It does not start Weston or Chromium.
set -u
LOG=/root/drm-inventory.log
: > "$LOG"
log() { echo "[drm-inventory] $*" | tee -a "$LOG" /dev/console >/dev/null 2>&1 || true; }
log "kernel=$(uname -a)"
log "dri_nodes=$(ls -l /dev/dri 2>&1 || true)"
log "drm_class=$(find /sys/class/drm -maxdepth 2 -type f -o -type l 2>&1 | sort)"
log "drm_card0_device=$(ls -la /sys/class/drm/card0/device 2>&1 || true)"
log "drm_card0_uevent=$(cat /sys/class/drm/card0/uevent 2>&1 || true)"
log "input_nodes=$(ls -l /dev/input 2>&1 || true)"
if [ -x /drmprobe ]; then
    /drmprobe >> "$LOG" 2>&1 || log "drmprobe_rc=$?"
    tail -n 120 "$LOG" > /dev/console 2>&1 || true
else
    log "drmprobe_missing"
fi
if [ -x /usr/bin/udevadm ]; then
    udevadm info --query=all --name=/dev/dri/card0 >> "$LOG" 2>&1 || log "udevadm_card0_rc=$?"
fi
log "DRM_INVENTORY_DONE"
sleep 20
