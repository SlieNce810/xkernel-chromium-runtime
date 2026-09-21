#!/bin/sh
# autorun_p4.sh —— P4（madvise）验证轮
#
# 验证目标
#   1. 探针：`madvise(HOLE)` 由 ENOMEM(12) → 0；`MADV_NORMAL/WILLNEED/FREE` 由 EINVAL(22) → 0；
#      同时确认 `madvise(misaligned)` 仍是 EINVAL（负对照不能被"放水"）、`DONTNEED` 仍正常。
#   2. 行为：跑**标准多进程**（不带 `--in-process-gpu`）。
#      r3-C 段的结论是"GPU 子进程能 exec 了、但 10~13 s 后静默 exit 191"。
#      如果那次静默退出确实由 madvise 失败引起，本轮的 GPU 子进程就应当能活下来，
#      浏览器也不再因 `GPU process isn't usable` 而 rc=191。
#      —— 若仍死，则说明 madvise 不是它的死因，需要继续查（不许把"修了别的 bug"当成功）。

LOG=/root/p4.log
: > "$LOG"
log() {
    echo "[p4] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}
psn() { pgrep -f "type=$1" | tr '\n' ' '; }

log "start uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"

# ---------------------------------------------------------------- 1. 探针
for p in /hangprobe /compatprobe /nvprobe /p2probe; do
    [ -x "$p" ] || { log "  跳过（未注入）: $p"; continue; }
    n=$(basename "$p"); OUT=/root/probe-$n.out
    log "===== 探针 $p ====="
    "$p" > "$OUT" 2>&1 &
    pp=$!; j=0
    while [ "$j" -lt 45 ]; do [ -d /proc/$pp ] || break; j=$((j + 1)); sleep 1; done
    if [ -d /proc/$pp ]; then log "  !! $p 超时 ${j}s → HUNG，kill"; kill -9 "$pp" 2>/dev/null; RC=HUNG;
    else wait "$pp"; RC=$?; fi
    log "  $p 结果=$RC（等待 ${j}s）"
    tr -d '\r' < "$OUT" >> "$LOG"
    log "----- $p 判定行 -----"
    grep -aE "^\[HP\]|^\[MP\]|^\[CP\]|^\[CPSUM\]|^\[NV\] T[0-9]|^\[SCHED\]|^\[NETLINK\]|^\[RESULT\]" "$OUT" > /dev/console 2>&1
done

# ---------------------------------------------------------------- 2. weston
log "===== weston ====="
mkdir -p /run/udev/data /sys/dev/char/226:0/device /sys/devices/simpledrm /sys/bus/faux 2>/dev/null
cat > /run/udev/data/c13:1 <<'EOF'
E:ID_INPUT=1
E:ID_INPUT_KEYBOARD=1
E:ID_SEAT=seat0
EOF
ln -sf ../../faux /sys/dev/char/226:0/device/subsystem 2>/dev/null
mkdir -p /sys/class/drm/card0 2>/dev/null
printf 'MAJOR=226\nMINOR=0\nDEVNAME=dri/card0\nSUBSYSTEM=drm\nDEVTYPE=drm_minor\n' > /sys/class/drm/card0/uevent 2>/dev/null
printf '226:0\n' > /sys/class/drm/card0/dev 2>/dev/null
ln -sf ../../bus/faux /sys/class/drm/card0/subsystem 2>/dev/null
printf 'drm 1.1.0 simpledrm 1.0.0\n' > /sys/class/drm/version 2>/dev/null
mkdir -p /run/user/0 /tmp/.X11-unix 2>/dev/null
chmod 700 /run/user/0 2>/dev/null
chmod 1777 /tmp/.X11-unix 2>/dev/null
pkill -x weston 2>/dev/null; pkill -x seatd 2>/dev/null; sleep 1
rm -f /run/seatd.sock /tmp/weston.log /run/user/0/wayland-*
seatd -g root -l debug >/tmp/seatd.log 2>&1 &
sleep 2
if [ -f /usr/local/lib/libseat-shim.so ]; then
    env LD_PRELOAD=/usr/local/lib/libseat-shim.so XDG_RUNTIME_DIR=/run/user/0 WESTON_DISABLE_ATOMIC=1 \
        weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
        --seat=seat0 --continue-without-input --idle-time=0 --socket=wayland-0 \
        --log=/tmp/weston.log >/dev/console 2>&1 &
    i=0
    while [ "$i" -lt 30 ]; do
        [ -n "$(ls /run/user/0 2>/dev/null | grep -E '^wayland-[0-9]+$')" ] && break
        i=$((i + 1)); sleep 1
    done
    WL=$(ls /run/user/0 2>/dev/null | grep -E '^wayland-[0-9]+$' | head -n1)
    log "  weston=$(pgrep -x weston | tr '\n' ' ') socket=${WL:-NONE}（等 ${i}s）"
fi
export XDG_RUNTIME_DIR=/run/user/0
export WAYLAND_DISPLAY="${WL:-wayland-0}"
mkdir -p /tmp/chromium-baseline

# ---------------------------------------------------------------- 3. Chromium（标准多进程）
log "===== Chromium 标准多进程（无 --in-process-gpu）220s ====="
CL=/root/p4-chrome.log
: > "$CL"
chromium --ozone-platform=wayland --no-sandbox --disable-dev-shm-usage \
    --enable-logging=stderr --v=1 --user-data-dir=/tmp/chromium-baseline \
    --use-gl=swiftshader --disable-gpu-sandbox \
    --no-first-run --no-default-browser-check --disable-component-update \
    --disable-background-networking --disable-sync --disable-extensions --disable-crash-reporter \
    file:///usr/share/html-test/index.html >> "$CL" 2>&1 &
CP=$!
log "  browser pid=$CP"
k=0
while [ "$k" -lt 220 ]; do
    [ -d /proc/$CP ] || break
    echo "--- +${k}s zygote=[$(psn zygote)] gpu=[$(psn gpu)] utility=[$(psn utility)] renderer=[$(psn renderer)]" >> "$LOG" 2>&1
    k=$((k + 10)); sleep 10
done
if [ -d /proc/$CP ]; then
    log "  仍在运行（${k}s）✓ gpu=[$(psn gpu)] renderer=[$(psn renderer)]"
else
    wait "$CP"; rc=$?
    log "  已退出 rc=$rc（存活约 ${k}s）"
fi
for pat in 'Network service crashed' 'NO_NEW_PRIVS' 'GPU process exited' 'GPU process isn' 'FATAL' 'RenderProcessHost' 'FileURLLoader'; do
    log "  COUNT [$pat] = $(grep -c "$pat" "$CL" 2>/dev/null)"
done
log "  ==== GPU / 崩溃相关行 ===="
grep -nE "gpu_process_host|GPU process|gpu_data_manager|FATAL|FileURLLoader" "$CL" | head -25 > /dev/console 2>&1
log "  ==== 尾 25 行 ===="; tail -25 "$CL" > /dev/console 2>&1

log "===== watcher ====="
n=0
while [ "$n" -lt 24 ]; do
    { echo "=== $(date 2>/dev/null) (+$((n * 30))s) weston=$(pgrep -x weston | tr '\n' ' ') browser=$(pgrep -f 'lib/chromium/chromium' | tr '\n' ' ') gpu=[$(psn gpu)] renderer=[$(psn renderer)] ==="; } >> /root/p4-watch.log 2>&1
    sync; n=$((n + 1)); sleep 30
done
log "autorun_p4 done"; sync; sync
