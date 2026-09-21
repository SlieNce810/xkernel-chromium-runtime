#!/bin/sh
# autorun.sh v4 — guest 侧总控
#   日志双通道：/dev/console（串口实时可见）+ /root/autorun.log（ext4 持久化，重启可提取）
#   由 /etc/profile.d/99-autostart.sh 后台拉起
LOG=/root/autorun.log
: > "$LOG"
log() {
    echo "[autorun] $*" > /dev/console 2>/dev/null
    echo "[$(date 2>/dev/null)] $*" >> "$LOG"
}
log "start (v4)"

# ---- 0. 设备节点诊断 + card0 缺失时 mknod 兜底 ----
log "===== /dev listing ====="
ls -l /dev/ >> "$LOG" 2>&1
ls -l /dev/dri/ >> "$LOG" 2>&1
ls -l /dev/input/ >> "$LOG" 2>&1
if [ -e /dev/dri/card0 ]; then
    log "/dev/dri/card0 EXISTS"
else
    mkdir -p /dev/dri
    if mknod /dev/dri/card0 c 226 0 2>> "$LOG"; then
        log "mknod card0 OK (fallback)"
    else
        log "mknod card0 FAILED"
    fi
fi

# ---- 1. bootstrap（幂等：开 community 源 + apk update + Weston 全家桶已装则秒过）----
sh /root/bootstrap.sh >> "$LOG" 2>&1
log "bootstrap rc=$?"
sync
log "sync done (weston packages flushed to disk)"

# ---- 2. Weston：先官方 DRM 路线，失败再 fbdev 兜底 ----
i=0
while [ "$i" -lt 30 ] && [ ! -S /run/user/0/wayland-0 ]; do
    if ! pgrep -x weston >/dev/null 2>&1; then
        log "weston attempt $((i + 1)) (DRM, via xk-weston-start)"
        XK_WESTON_CLIENT=none /usr/local/bin/xk-weston-start >> "$LOG" 2>&1
        log "xk-weston-start rc=$? (weston.log tail follows)"
        tail -n 25 /tmp/weston.log >> "$LOG" 2>/dev/null
        tail -n 25 /tmp/weston.log
    fi
    [ -S /run/user/0/wayland-0 ] && break
    i=$((i + 1))
    sleep 2
done

if [ ! -S /run/user/0/wayland-0 ]; then
    log "DRM route failed after retries; trying fbdev backend fallback"
    command -v weston-backend-fbdev >/dev/null 2>&1 || apk add --no-cache weston-backend-fbdev >> "$LOG" 2>&1
    pkill -x weston 2>/dev/null
    sleep 1
    mkdir -p /run/user/0
    env XDG_RUNTIME_DIR=/run/user/0 WESTON_DISABLE_ATOMIC=1 weston \
        --backend=fbdev-backend.so --renderer=pixman --fbdev-device=/dev/fb0 \
        --continue-without-input --idle-time=0 --log=/tmp/weston-fbdev.log >> "$LOG" 2>&1 &
    j=0
    while [ "$j" -lt 30 ] && [ ! -S /run/user/0/wayland-0 ]; do
        pgrep -x weston >/dev/null 2>&1 || { log "fbdev weston died"; break; }
        j=$((j + 1))
        sleep 2
    done
fi

if [ -S /run/user/0/wayland-0 ]; then
    log "weston UP (wayland socket ready)"
    touch /tmp/stage-weston-up
    ps >> "$LOG" 2>/dev/null
else
    log "weston FAILED on both routes; persisting weston logs"
    touch /tmp/stage-weston-failed
    cp /tmp/weston.log /root/weston-drm.log 2>/dev/null
    cp /tmp/weston-fbdev.log /root/weston-fbdev.log 2>/dev/null
    log "===== weston-drm.log tail ====="
    tail -n 40 /root/weston-drm.log > /dev/console 2>/dev/null
    tail -n 40 /root/weston-drm.log >> "$LOG" 2>/dev/null
    log "===== weston-fbdev.log tail ====="
    tail -n 40 /root/weston-fbdev.log > /dev/console 2>/dev/null
    tail -n 40 /root/weston-fbdev.log >> "$LOG" 2>/dev/null
    sync
fi

# ---- 3. Chromium 安装（缓存复用；TCG 下可能 20-60 分钟）----
if ! command -v chromium >/dev/null 2>&1; then
    log "installing chromium (background, may take long under TCG)"
    apk add chromium chromium-swiftshader font-noto-cjk >> "$LOG" 2>&1
    log "chromium install rc=$?"
fi
touch /tmp/stage-chromium-done

# ---- 4. Chromium 启动（wayland 起来才启动）----
if command -v chromium >/dev/null 2>&1; then
    if [ -S /run/user/0/wayland-0 ]; then
        log "launching chromium (ozone/wayland)"
        env XDG_RUNTIME_DIR=/run/user/0 WAYLAND_DISPLAY=wayland-0 \
            chromium --ozone-platform=wayland --no-sandbox --disable-gpu \
                --disable-dev-shm-usage --no-first-run --no-default-browser-check \
                --window-size=800,560 file:///root/index.html >/tmp/chromium.log 2>&1 &
        log "chromium launched"
    else
        log "chromium NOT launched (no wayland socket)"
    fi
else
    log "chromium binary missing after install"
fi
log "all done"
