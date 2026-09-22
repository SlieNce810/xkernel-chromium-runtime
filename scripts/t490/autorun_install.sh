#!/bin/sh
# autorun_install.sh — guest 侧：解包安装 fontconfig/字体/Chromium → 起 weston → 起 Chromium
#
# 为什么是"解包"而不是"apk add"
# ----------------------------
# guest 侧网络实测不可达（eth0=10.0.2.15、DNS=10.0.2.3 都正常，但取包 0 字节），
# 且 P0 冻结镜像里的字体/Chromium 是 0 字节空壳、/lib/apk/db/installed 也是空的。
# 因此由宿主侧用 apk.static 跨架构装好 → 打成单个 tar.gz 注入 → 这里 tar -x 解开。
# tar 会保真 symlink / 权限 / 硬链接，比 debugfs 逐文件注入可靠得多。
#
# 阶段
#   1  解包 /pkgs.tar.gz 到 /
#   2  校验关键文件是**非空实体**
#   3  fc-cache 生成字体缓存
#   4  输入设备：按 evprobe 的实测结论写 /run/udev/data（c13:1 = 键盘，不是鼠标！）
#   5  伪造 sysfs + seatd + weston（libseat-shim + card0 单路线）
#   6  Chromium 起测试页
#   7  watcher 每 30s 快照（含 sync）

LOG=/root/install.log
WATCH=/root/install-watch.log
: > "$LOG"
: > "$WATCH"

log() {
    echo "[inst] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}
# 只进日志（避免刷爆串口）
ql() { "$@" >> "$LOG" 2>&1; }
# 同时进串口与日志
tl() { "$@" 2>&1 | tee -a "$LOG" /dev/console; }

log "start  alpine=$(cat /etc/alpine-release 2>/dev/null)"
log "df before: $(df -h / 2>/dev/null | tail -1)"

# ---------------------------------------------------------------- 1. 解包
log "===== 1. 解包 /pkgs.tar.gz ====="
CHROME_SZ=$(stat -c %s /usr/lib/chromium/chromium 2>/dev/null || echo 0)
if [ "$CHROME_SZ" -gt 1000000 ] 2>/dev/null; then
    # 基座镜像已是 pkg-installed.img（已装好包），跳过解包 → 省掉 387MB 注入与解包时间
    log "chromium 已就位（$CHROME_SZ 字节），跳过解包"
else
    if [ -f /pkgs.tar.gz ]; then
        log "tar 文件: $(ls -l /pkgs.tar.gz 2>/dev/null | tr -s ' ')"
        tar -xzf /pkgs.tar.gz -C / >> "$LOG" 2>&1
        log "tar rc=$?"
    else
        log "!! /pkgs.tar.gz 不存在，且 chromium 未就位 —— 无法安装"
    fi
fi
sync

# ---------------------------------------------------------------- 2. 校验
log "===== 2. 关键文件实体校验（Size 必须非 0）====="
for f in /usr/lib/chromium/chromium /usr/bin/chromium /etc/fonts/fonts.conf \
         /usr/share/fonts/opensans/OpenSans-Regular.ttf; do
    if [ -e "$f" ]; then
        log "  $(ls -l "$f" 2>&1 | tr -s ' ')"
    else
        log "  MISSING: $f"
    fi
done
log "  /usr/lib/chromium 体积: $(du -sh /usr/lib/chromium 2>/dev/null | cut -f1)"
log "  chromium --version: $(chromium --version 2>&1 | head -1)"
log "  fonts.conf 头 2 行: $(head -2 /etc/fonts/fonts.conf 2>&1 | tr '\n' ' ')"
log "df after: $(df -h / 2>/dev/null | tail -1)"

# ---------------------------------------------------------------- 3. 字体缓存
log "===== 3. fc-cache ====="
if command -v fc-cache >/dev/null 2>&1; then
    tl fc-cache -f
    log "fc-list 计数: $(fc-list 2>/dev/null | wc -l)"
else
    log "无 fc-cache"
fi

# ---------------------------------------------------------------- 4. 输入设备 udev 伪造
# ★ 实测（evprobe.c）: /dev/input/event0 = minor 1 = "QEMU Virtio Keyboard"（KEY_A/KEY_Z/KEY_SPACE）
#   所以 c13:1 必须是 KEYBOARD。旧 guest-bootstrap.sh 把它写成 MOUSE，是**反的**。
#   另外：virtio-mouse-pci 在 guest 内**没有生成 evdev 节点**（只有 event0），
#   属内核侧缺口，本轮先如实记录，不做假节点。
log "===== 4. 输入设备 ====="
mkdir -p /run/udev/data 2>/dev/null
cat > /run/udev/data/c13:1 <<'EOF'
E:ID_INPUT=1
E:ID_INPUT_KEYBOARD=1
E:ID_SEAT=seat0
EOF
log "  已写 /run/udev/data/c13:1 → ID_INPUT_KEYBOARD（evprobe 实测结论）"
log "  /dev/input 实况: $(ls -l /dev/input/ 2>&1 | tr '\n' '|')"

# ---------------------------------------------------------------- 4.5 可选探针
# t490_round.sh 注入到 / 下的可执行探针，按名字命中即运行（输出同时进串口与持久日志）
for probe in /nvprobe /p2probe /childprobe /evprobe /fdprobe; do
    if [ -x "$probe" ]; then
        log "===== 探针 $probe ====="
        tl "$probe"
        log "----- $probe 判定行 -----"
        grep -E "^\[[A-Z]+\].*=(PASS|FAIL)|^\[RESULT\]|^\[SUMMARY\]|^\[EVMAP\]|^\[EVSUM\]" "$LOG" > /dev/console 2>&1
    fi
done

# ---------------------------------------------------------------- 5. weston
log "===== 5. weston（libseat-shim + 伪造 sysfs + card0）====="
# 伪造 sysfs（libdrm faux 总线分支 + libudev sysfs fallback）
mkdir -p /sys/dev/char/226:0/device /sys/devices/simpledrm /sys/bus/faux 2>/dev/null
ln -sf ../../faux /sys/dev/char/226:0/device/subsystem 2>/dev/null
mkdir -p /sys/class/drm/card0 2>/dev/null
printf 'MAJOR=226\nMINOR=0\nDEVNAME=dri/card0\nSUBSYSTEM=drm\nDEVTYPE=drm_minor\n' > /sys/class/drm/card0/uevent 2>/dev/null
printf '226:0\n' > /sys/class/drm/card0/dev 2>/dev/null
ln -sf ../../bus/faux /sys/class/drm/card0/subsystem 2>/dev/null
printf 'drm 1.1.0 simpledrm 1.0.0\n' > /sys/class/drm/version 2>/dev/null

mkdir -p /run/user/0 /tmp/.X11-unix 2>/dev/null
chmod 700 /run/user/0 2>/dev/null
chmod 1777 /tmp/.X11-unix 2>/dev/null

pkill -x weston 2>/dev/null
pkill -x seatd 2>/dev/null
sleep 1
rm -f /run/seatd.sock /tmp/weston.log /run/user/0/wayland-*
seatd -g root -l debug >/tmp/seatd.log 2>&1 &
sleep 2
log "  seatd pid=$(pgrep -x seatd | head -n1) socket=$([ -S /run/seatd.sock ] && echo yes || echo no)"

if [ -f /usr/local/lib/libseat-shim.so ]; then
    # ★ 必须钉死 socket 名：weston 的 wl_display_add_socket_auto() 在本内核上会跳过
    #   wayland-0 直接用 wayland-1（疑与 flock 语义不完整有关），而客户端默认连 wayland-0
    #   → 上一轮 Chromium 就是因此报 "Failed to connect to Wayland display: No such file or directory"。
    env LD_PRELOAD=/usr/local/lib/libseat-shim.so XDG_RUNTIME_DIR=/run/user/0 WESTON_DISABLE_ATOMIC=1 \
        weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
        --seat=seat0 --continue-without-input --idle-time=0 --socket=wayland-0 \
        --log=/tmp/weston.log >/dev/console 2>&1 &
    i=0
    while [ "$i" -lt 20 ]; do
        pgrep -x weston >/dev/null 2>&1 || break
        [ -n "$(ls /run/user/0 2>/dev/null | grep -E '^wayland-[0-9]+$')" ] && break
        i=$((i + 1)); sleep 1
    done
    log "  weston pid=$(pgrep -x weston | tr '\n' ' ')（等待 ${i}s）"
    # 不假设名字，直接发现实际 socket
    WL_SOCK=$(ls /run/user/0 2>/dev/null | grep -E '^wayland-[0-9]+$' | head -n1)
    log "  wayland socket = ${WL_SOCK:-NONE}"
    log "  /run/user/0 实况: $(ls -l /run/user/0 2>&1 | tr '\n' '|')"
    log "  界标:"; grep -nE "Output 'Virtual-1'|desktop-shell|create_pool|Quitting|ERROR|fatal" /tmp/weston.log > /dev/console 2>&1
else
    log "  !! libseat-shim.so 缺失"
fi

# ---------------------------------------------------------------- 6. Chromium
log "===== 6. Chromium ====="
export XDG_RUNTIME_DIR=/run/user/0
# 用实际发现的 socket 名，不要硬编码（weston 可能给出 wayland-1）
export WAYLAND_DISPLAY="${WL_SOCK:-wayland-0}"
log "  WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
mkdir -p /tmp/chromium-baseline /root/.config/chromium

# ★ 必须写持久盘：guest 的 /tmp 是 tmpfs（内存），QEMU 一停日志就没了。
#   上一轮就是把日志落在 /tmp 且当时还没写入，结果什么都没抓到。
CHROME_LOG=/root/chromium.log
: > "$CHROME_LOG"

launch_chrome() {
    tag="$1"; shift
    log "  【尝试 $tag】"
    chromium --ozone-platform=wayland --no-sandbox --disable-gpu --disable-dev-shm-usage \
        --enable-logging=stderr --v=1 \
        --disable-crash-reporter \
        --user-data-dir=/tmp/chromium-baseline "$@" \
        file:///usr/share/html-test/index.html >> "$CHROME_LOG" 2>&1 &
    CPID=$!
    log "    pid=$CPID"
    j=0
    while [ "$j" -lt 90 ]; do
        kill -0 "$CPID" 2>/dev/null || break
        j=$((j + 5)); sleep 5
    done
    if kill -0 "$CPID" 2>/dev/null; then
        log "    [$tag] 仍在运行（${j}s）✓"
    else
        wait "$CPID"; rc=$?
        log "    [$tag] 已退出 rc=$rc（存活约 ${j}s）"
    fi
    log "    [$tag] browser=[$(pgrep -f 'lib/chromium/chromium' | tr '\n' ' ')] renderer=[$(pgrep -f 'type=renderer' | tr '\n' ' ')]"
    log "    [$tag] FATAL 行: $(grep -c 'FATAL' "$CHROME_LOG" 2>/dev/null)"
    grep -nE "FATAL|GPU process isn't usable|launch failed" "$CHROME_LOG" > /dev/console 2>&1
    return 0
}

# 已确诊的两步：
#   ① 默认组合 → "GPU process isn't usable. Goodbye."（rc=191），因为 GPU 子进程起不来
#      → 加 --in-process-gpu 后 browser 存活、且**窗口真的画出来了**（标题栏 "Chromium"）
#   ② 但 renderer 始终没出现，日志每 ~3s 循环
#        Network service crashed or was terminated, restarting service.
#        prctl(PR_SET_NO_NEW_PRIVS) failed
#      → 说明本内核上 Chromium 的**所有子进程**都活不下来（GPU 那个只是第一个被发现的）
#      → 对策：--single-process，把 renderer/utility 也并进 browser 进程
launch_chrome "A-single-process" --single-process --no-zygote --in-process-gpu \
    --use-gl=swiftshader --disable-gpu-sandbox \
    --disable-features=Vulkan,SegmentationPlatform,OptimizationGuideModelDownloading,OptimizationHints,WebAppProvider,InterestFeedContentSuggestions \
    --disable-background-networking --disable-component-update --disable-sync \
    --no-first-run --disable-extensions
if ! pgrep -f "lib/chromium/chromium" >/dev/null 2>&1; then
    log "  尝试 A 未存活 → 换 B：仅 --in-process-gpu（已知能出窗口，但页面不渲染）"
    launch_chrome "B-inprocess-gpu" --in-process-gpu --use-gl=swiftshader --disable-gpu-sandbox \
        --disable-features=Vulkan,SegmentationPlatform,OptimizationGuideModelDownloading,OptimizationHints,WebAppProvider,InterestFeedContentSuggestions \
        --disable-background-networking --disable-component-update
fi

log "  ==== /root/chromium.log 共 $(wc -l < "$CHROME_LOG" 2>/dev/null) 行，尾 120 行 ===="
tail -120 "$CHROME_LOG" > /dev/console 2>&1
log "  ==== 关键错误行 ===="
grep -nE "ERROR|FATAL|Failed|Aborted|trap|signal|Unimplemented" "$CHROME_LOG" > /dev/console 2>&1
log "  ==== 进程确认 ===="
ps 2>/dev/null | grep -E "chromium" | grep -v grep > /dev/console 2>&1

# ---------------------------------------------------------------- 7. watcher
log "进入 watcher（每 30s，含 sync）"
n=0
while [ "$n" -lt 80 ]; do
    {
        echo "=== $(date 2>/dev/null) uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null) (+$((n * 30))s) ==="
        echo "weston:        $(pgrep -x weston | tr '\n' ' ')"
        echo "desktop-shell: $(pgrep -f weston-desktop-shell | tr '\n' ' ')"
        echo "browser:       $(pgrep -f 'lib/chromium/chromium' | tr '\n' ' ')"
        echo "renderer:      $(pgrep -f 'type=renderer' | tr '\n' ' ')"
        echo "wayland sock:  $(ls /run/user/0 2>/dev/null | grep -E '^wayland-[0-9]+$' | tr '\n' ' ')"
        echo "chromium.log 尾 8 行:"
        tail -8 /root/chromium.log 2>/dev/null
        ps 2>/dev/null | grep -E 'weston|chromium|seatd' | grep -v grep | head -8
    } >> "$WATCH" 2>&1
    sync
    n=$((n + 1))
    sleep 30
done
log "watcher 结束（$n 轮）"
sync
sync
log "autorun_install done"
