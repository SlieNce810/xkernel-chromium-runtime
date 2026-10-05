#!/bin/sh
# ============================================================================
# autorun_x11.sh — guest 侧 X11 kiosk 启动器（T490 · agentos kiosk 镜像）
#
# 一、为什么需要这个脚本（来自 report/25 的两条已定位结论）
#   1) x-kernel 的 PID 1 是 `/bin/sh --login`，不跑 BusyBox init。镜像自带的
#      /etc/inittab 里那条 `tty1::respawn:/usr/local/bin/x11-session` 从来没被
#      执行过 —— 整条 kiosk 链一次都没跑，virtio-gpu 上从未发生 modeset，
#      于是 QEMU monitor screendump 恒为 "Display output is not active."。
#   2) 镜像自带的 /usr/local/bin/x11-session 第 24 行把 Xorg 的 stdout/stderr
#      重定向到 /dev/ttyAMA0；x-kernel 下该设备打开失败，shell 在 fork Xorg
#      **之前**就被重定向挡住：
#        x11-session: line 24: can't create /dev/ttyAMA0: Permission denied
#
#   本脚本的做法不是改镜像，而是把 kiosk 链搬到**注入通道**里：
#     t490_round.sh 注入 /root/autorun.sh（本文件）
#       → 同轮注入的 /etc/profile.d/99-autostart.sh 在 login shell 里把它拉起
#         → 本脚本按 Xorg → jwm → chromium 的顺序起会话
#   Xorg 日志改用 `-logfile /root/xorg.log`（ext4 可写）落盘，彻底绕开 ttyAMA0。
#
# 二、合规边界（R-1 / R-2 / S-2 / S-3）
#   * 本脚本是**启停与诊断通道**：只负责把镜像自带的图形链真正拉起来，并把
#     失败点落成可复核的日志。它不修改任何内核代码，也不修改平台参数
#     （2G / 4 vCPU / 纯 TCG 由 platform.env + run_session_t490.sh 保证）。
#   * 它**不得**写入任何优化收益表；`--no-sandbox` / `--disable-dev-shm-usage`
#     属 S-3 允许的起步简化，使用情况如实记录在 /root/autorun-x11.log 里。
#   * 不写伪 /sys、不装 shim、不改任何内核可见状态 —— 全部观测只读。
#
# 三、★ 入口烘焙点（改动会导致整轮静默测错页）
#   下面 URL= 那行的字面量 file:///usr/share/html-test/index.html 是
#   t490_round.sh「3b. 页面入口烘焙」的替换锚点，替换后会 grep -F 自证。
#   不要改字面量、不要拆行、不要在它前面加别的东西。
# ============================================================================

LOG=/root/autorun-x11.log
: > "$LOG" 2>/dev/null

log() {   # 双通道：/dev/console（串口实时）+ ext4 持久日志（轮后可由 debugfs 回收）
    echo "[x11] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG" 2>/dev/null
}
stage() {   # 阶段打点：让"卡在哪一步"一眼可见
    log "STAGE=$1"
    echo "$1" > "/tmp/stage-x11-$1" 2>/dev/null
}
has() { command -v "$1" >/dev/null 2>&1; }

# ---- 本轮要加载的页面（★ t490_round.sh 的 PAGE_URL 烘焙锚点，勿改字面量）----
URL="file:///usr/share/html-test/index.html"

log "================ autorun_x11 start ================"
log "PAGE_URL=$URL"
log "uname: $(uname -a 2>/dev/null)"
log "id: $(id 2>/dev/null)"

# ------------------------------------------------------------------ 0. 只读诊断
log "===== /dev/dri | /dev/fb0 | /dev/input ====="
ls -l /dev/dri/ /dev/fb0 /dev/input/ >> "$LOG" 2>&1
ls -l /dev/dri/ /dev/fb0 /dev/input/ > /dev/console 2>&1

log "===== tty 设备（Xorg 找 VT/console 用）====="
for t in /dev/console /dev/tty /dev/tty0 /dev/tty1 /dev/ttyAMA0; do
    if [ -e "$t" ]; then
        log "  OK   $t -> $(ls -l "$t" 2>/dev/null | awk '{print $1, $5, $6}')"
    else
        log "  MISS $t"
    fi
done

log "===== 关键组件存在性 ====="
for f in /usr/bin/Xorg /usr/libexec/Xorg /usr/libexec/Xorg.wrap /usr/bin/jwm \
         /usr/bin/xset /usr/bin/xauth /usr/bin/chromium \
         /usr/lib/xorg/modules/drivers/modesetting_drv.so \
         /usr/lib/xorg/modules/input/libinput_drv.so \
         /usr/lib/xorg/modules/extensions/libglx.so; do
    if [ -e "$f" ]; then log "  OK   $f ($(stat -c %s "$f" 2>/dev/null) B)"
    else log "  MISS $f"; fi
done

log "===== /proc/devices 中 drm/fb ====="
grep -iE 'drm|fb' /proc/devices >> "$LOG" 2>&1 || log "  (无 drm/fb 条目)"

# libdrm 的设备枚举真依赖 sysfs —— 这里按 libdrm 源码实际读的路径逐级探测。
# 依据：libdrm 的 drmGetMinorNameForFD()/drmGetDevices2() 走
#   /sys/dev/char/<maj>:<min>/device/drm/<subsys>/<name>
# 若这些路径不存在，则"设备存在但枚举为空"是**必然**结果，与 DRM 驱动本体无关。
# 这是"内核 sysfs 暴露面"的证据，用来把"X 侧问题"和"内核 sysfs 缺失"分开。
log "===== libdrm 枚举依赖的 sysfs 路径（只读逐级探测）====="
for p in /sys/dev/char/226:0 /sys/dev/char/226:0/device \
         /sys/dev/char/226:0/device/drm /sys/dev/char/226:0/device/drm/card0 \
         /sys/dev/char/226:0/subsystem /sys/class/drm /sys/bus/platform/devices \
         /sys/bus/pci/devices /sys/devices; do
    if [ -e "$p" ]; then log "  OK   $p"
    else log "  MISS $p"; fi
done
log "  /sys 是否可读: $(ls /sys 2>&1 | tr '\n' ' ' | head -c 300)"

log "===== DRM connector status（只读，不写伪 sysfs）====="
if [ -d /sys/class/drm ]; then
    ls -l /sys/class/drm/ >> "$LOG" 2>&1
    for s in /sys/class/drm/card*/status; do
        [ -e "$s" ] && log "  $s = $(cat "$s" 2>/dev/null)"
    done
    for m in /sys/class/drm/card*/modes; do
        [ -e "$m" ] && log "  $m = [$(head -c 120 "$m" 2>/dev/null | tr '\n' ' ')]"
    done
else
    log "  /sys/class/drm 不存在"
fi

# ------------------------------------------------------------------ 1. 运行时目录
# 镜像原本靠 /etc/init.d/kiosk-boot（::sysinit）+ init 建这些目录；x-kernel 不跑 init，
# 所以这里自己建。全部是用户态运行时状态，不涉及内核改动。
mkdir -p /run/x11 /tmp/.X11-unix /run/user/1000 2>/dev/null
chmod 1777 /tmp/.X11-unix 2>/dev/null
chown kiosk:kiosk /run/user/1000 2>/dev/null
chmod 700 /run/user/1000 2>/dev/null

# /dev/shm：镜像 /etc/fstab 只有 / 与 /tmp，chromium 需要共享内存段。
# ★ x11p1 轮实测：/dev/shm 虽然"是挂载点"，但 `df` 报 `none 0 0 0 0%`，
#   即一个 **0 字节 tmpfs** —— 这种状态下 mountpoint 判定为真，很容易被
#   当成"已经好了"，然后 chromium 在渲染器启动时才炸。所以这里按**容量**判定，
#   容量不足就 remount 放大（remount 不改变挂载点所有权，比 umount 安全）。
mkdir -p /dev/shm 2>/dev/null
SHM_KB=$(df -k /dev/shm 2>/dev/null | tail -n1 | awk '{print $2}')
case "$SHM_KB" in ''|*[!0-9]*) SHM_KB=0 ;; esac
if [ "$SHM_KB" -lt 65536 ]; then
    mount -o remount,size=512m /dev/shm 2>>"$LOG" \
        && log "/dev/shm remount size=512m 成功" \
        || log "!! /dev/shm remount 失败（继续，chromium 退用 --disable-dev-shm-usage）"
fi
log "dev/shm: $(df -h /dev/shm 2>/dev/null | tail -n1 | tr -s ' ')"
df -h /dev/shm / /tmp >> "$LOG" 2>&1

# kiosk 的家目录（本镜像 /home/kiosk 可能未创建，chromium 需要可写 profile 目录）
mkdir -p /home/kiosk 2>/dev/null
chown kiosk:kiosk /home/kiosk 2>/dev/null
chmod 755 /home/kiosk 2>/dev/null
log "kiosk home: $(ls -ld /home/kiosk 2>&1 | tr -s ' ')"

# DRM 探针（由 t490_round.sh 作为 probe 编译注入）：
#   /drmprobe      —— 通路 + libdrm/libudev 能力（历史探针）
#   /drmdumbprobe  —— CREATE_DUMB 的 bpp 接受度（本路线新增，钉死 ScreenInit 失败点）
# 两者的价值都是把"内核 DRM 到底哪一步不支持"变成 errno 级事实，
# 而不是靠读代码推断 —— 推断只能给出候选，测量才能给出结论。
DRM_PROBE_RAN=0
for p in /drmprobe /drmdumbprobe; do
    if [ -x "$p" ]; then
        log "===== $p 输出 ====="
        "$p" >> "$LOG" 2>&1
        "$p" > /dev/console 2>&1
        DRM_PROBE_RAN=1
    fi
done
[ "$DRM_PROBE_RAN" = "1" ] || log "(未注入 DRM 探针 —— 本轮不做 errno 级取证)"

# ------------------------------------------------------------------ 2. xauth cookie
XAUTH=/run/x11/auth
rm -f "$XAUTH"
COOKIE="$(hexdump -n 16 -v -e '4/4 "%08x" 1 ""' /dev/urandom 2>/dev/null)"
if [ -z "$COOKIE" ]; then
    log "!! hexdump 取 cookie 失败，退用固定值（仅诊断用）"
    COOKIE=0123456789abcdef0123456789abcdef
fi
xauth -q -f "$XAUTH" add :0 . "$COOKIE" 2>>"$LOG"
chmod 644 "$XAUTH"      # kiosk 要能读；Xorg 只读校验
log "xauth: $XAUTH 存在=$([ -f "$XAUTH" ] && echo yes || echo no)"

# ------------------------------------------------------------------ 3. 启动 Xorg
# 为什么不用镜像自带的 /usr/local/bin/x11-session：
#   它把日志重定向到 /dev/ttyAMA0（x-kernel 下必失败），且依赖 inittab respawn。
#   这里复刻它的会话结构（Xorg as root → jwm/chromium as kiosk + xauth），
#   只把日志目标换成 ext4 文件。
XLOG=/root/xorg.log
XERR=/root/xorg-stderr.log
XORG_WAIT="${XORG_WAIT:-60}"
XORG_SETTLE="${XORG_SETTLE:-20}"
rm -f "$XLOG" "$XERR"

# 把 Xorg 自己的日志尾巴同时送串口与持久日志。
# 为什么必须在**每个**变体失败时都调：x11p1 轮第一次实测发现 Xorg 会在建好
# /tmp/.X11-unix/X0 之后 1–2 s 内退出，而原判据只看 socket，于是打出假的
# "Xorg UP"，真正的死因（xorg.log）反而一个字都没进证据。
dump_xorg_tail() {   # $1=行数
    N="${1:-25}"
    if [ -s "$XLOG" ]; then
        log "---- xorg.log tail(-$N) ----"
        tail -n "$N" "$XLOG" >> "$LOG" 2>&1
        tail -n "$N" "$XLOG" > /dev/console 2>&1
    else
        log "---- xorg.log 不存在或为空（Xorg 未及写日志）----"
    fi
    if [ -s "$XERR" ]; then
        log "---- xorg stderr tail(-$N) ----"
        tail -n "$N" "$XERR" >> "$LOG" 2>&1
        tail -n "$N" "$XERR" > /dev/console 2>&1
    fi
}

# ---- 功能门禁 + 变体清理（两轮实测教训，勿退回"看文件"式判据）--------------
# x_ready()：真的能和 X 通信才算"起来了"。
#   为什么不用 socket 存在性：x11p1 与 x11p2 两轮都证明 —— Xorg 会**先建**出
#   /tmp/.X11-unix/X0，然后花约 7 s 加载 glx 模块、再在 DDX/ScreenInit 失败，
#   最后才把 socket 清掉。也就是说存在一个十几秒的"**假可用窗口**"，
#   任何固定长度的短窗判据都可能正好落在窗口内，从而得到假成功。
x_ready() {
    DISPLAY=:0 XAUTHORITY="$XAUTH" xset q >/dev/null 2>&1
}

# cleanup_xorg()：变体之间必须用 **PID** 清理，不能用 pkill。
#   实测 x-kernel 的 procfs 不暴露进程名，`pgrep -x Xorg` 恒为空
#   （x11p2 轮因此打出过 "Xorg UP on :0 (pid )"）⇒ pkill 同样可能匹配不到；
#   残留的 Xorg 会占住 /dev/dri/card0 与 socket，把后续所有变体一起毒化，
#   而这种污染表现为"每个变体都失败"，极易被误读成"X11 路线彻底不行"。
cleanup_xorg() {
    if [ -n "${XPID:-}" ]; then
        kill "$XPID" 2>/dev/null
        i=0
        while [ -d "/proc/$XPID" ] && [ "$i" -lt 5 ]; do i=$((i + 1)); sleep 1; done
        [ -d "/proc/$XPID" ] && kill -9 "$XPID" 2>/dev/null
    fi
    rm -f /tmp/.X11-unix/X0 /tmp/.X0-lock 2>/dev/null
}

start_xorg() {   # $1=变体名，其余=传给 Xorg 的额外参数
    desc="$1"; shift
    log "--- Xorg try[$desc]: args=[$*] ---"
    # -logfile 显式指定：Xorg 自己的详细日志（含 modesetting/DRM 探测结论）
    # -logverbose 7：默认的 (II) 级拿不到"设备为什么没被发现"的过程，
    #   而本轮要回答的正是这个问题 —— 日志详细度本身就是一项"测量能力"。
    /usr/bin/Xorg :0 -logfile "$XLOG" -logverbose "${XORG_VERBOSE:-7}" \
        -nolisten tcp -auth "$XAUTH" "$@" >> "$XERR" 2>&1 &
    XPID=$!
    n=0
    while [ "$n" -lt "$XORG_WAIT" ]; do
        if [ -S /tmp/.X11-unix/X0 ] && x_ready; then break; fi
        if [ ! -d "/proc/$XPID" ]; then
            wait "$XPID" 2>/dev/null; XRC=$?
            log "  -> Xorg 在 ~${n}s 退出（rc=$XRC），从未达到可用状态"
            dump_xorg_tail 30
            return 1
        fi
        n=$((n + 1))
        sleep 1
    done
    if [ "$n" -ge "$XORG_WAIT" ]; then
        log "  -> ${XORG_WAIT}s 内未达到可用状态"
        cleanup_xorg
        dump_xorg_tail 30
        return 1
    fi
    log "  -> 首次可用（~${n}s）；进入 ${XORG_SETTLE}s 持续可用复核"
    s=0
    while [ "$s" -lt "$XORG_SETTLE" ]; do
        if [ ! -d "/proc/$XPID" ]; then
            wait "$XPID" 2>/dev/null; XRC=$?
            log "  -> 复核失败：Xorg 在首次可用后 ${s}s 退出（rc=$XRC）"
            dump_xorg_tail 35
            return 1
        fi
        if ! x_ready; then
            log "  -> 复核失败：进程仍在但 X 已不可连接（第 ${s}s）"
            cleanup_xorg
            dump_xorg_tail 35
            return 1
        fi
        s=$((s + 1))
        sleep 1
    done
    log "  -> 持续复核通过（${XORG_SETTLE}s 内始终可连接）"
    return 0
}

XORG_UP=0
# ---------------------------------------------------------------------------
# 变体设计（M3「一轮一变量」）
#   x11p1 轮已经定位到：Xorg 建完 socket 后 1–2 s 在 DDX 层退出，日志末条为
#     (II) modeset(0): Using 24bpp hw front buffer with 32bpp shadow
#     ...
#     (EE) AddScreen/ScreenInit failed for driver 0
#   而内核侧 io/drmdevice/src/card0.rs 的 DrmModeCreateDumb（0xB2）**只接受 bpp==32**：
#     if c.width == 0 || c.height == 0 || c.bpp != 32 || c.flags != 0 → EINVAL
#   modesetting 在 ShadowFB 被强制开启时，会把**硬件前缓冲**切成 24bpp packed
#   (DRM_FORMAT_RGB888)，也就是会去调 drmModeCreateDumbBuffer(bpp=24) → 必然 EINVAL。
#   所以这三个变体构成一个单变量序列：
#     V1 无配置（基线，已知失败，用来证明问题可复现）
#     V2 普通显式配置（控制组：证明"失败不是 -config 机制本身造成的"）
#     V3 显式配置 + ShadowFB=false + AccelMethod=none（单变量：让前缓冲回到 32bpp）
#   若 V3 成功而 V2 失败，收益即可归因到"前缓冲 bpp 从 24 回到 32"，而不是别的。
#   ⚠️ 这是**用户态配置**（S-2 允许），只能记为验证/过渡；真正的修复应落在内核
#      （让 CreateDumb 支持 24bpp，或与 DDX 的格式协商对齐），见 report/26。
# ---------------------------------------------------------------------------
make_conf() {   # $1=目标文件 $2=extra_device_options（可多行）
    {
        echo 'Section "ServerLayout"'
        echo '    Identifier "layout0"'
        echo '    Screen     0 "screen0"'
        echo 'EndSection'
        echo ''
        echo 'Section "Device"'
        echo '    Identifier  "gpudev0"'
        echo '    Driver      "modesetting"'
        echo '    Option      "kmsdev" "/dev/dri/card0"'
        [ -n "$2" ] && printf '%s\n' "$2"
        echo 'EndSection'
        echo ''
        echo 'Section "Screen"'
        echo '    Identifier  "screen0"'
        echo '    Device      "gpudev0"'
        echo 'EndSection'
    } > "$1"
    log "生成 $1（$(wc -l < "$1") 行）"
}

# V1 基线
if start_xorg "keeptty" -keeptty; then XORG_UP=1; fi
# V2 控制组：仅显式配置
if [ "$XORG_UP" != "1" ]; then
    cleanup_xorg
    make_conf /root/xorg-plain.conf ""
    if start_xorg "conf-plain" -config /root/xorg-plain.conf -keeptty; then XORG_UP=1; fi
fi
# V3 单变量：关 ShadowFB + 关 glamor ⇒ 前缓冲回到 XRGB8888/32bpp
if [ "$XORG_UP" != "1" ]; then
    cleanup_xorg
    make_conf /root/xorg-noshadow.conf '    Option      "ShadowFB" "false"
    Option      "AccelMethod" "none"'
    if start_xorg "conf-noshadow-32bpp" -config /root/xorg-noshadow.conf -keeptty; then XORG_UP=1; fi
fi

if [ "$XORG_UP" != "1" ]; then
    stage x11-xorg-failed
    log "===== 三个变体全部失败：归拢 Xorg 日志 ====="
    dump_xorg_tail 45
else
    stage x11-xorg-up
    log "Xorg UP on :0 (pid=$XPID)"
    DISPLAY=:0 XAUTHORITY="$XAUTH" xset s off -dpms s noblank >> "$LOG" 2>&1 \
        && log "xset: 屏保/DPMS 已关" || log "!! xset 失败（不致命）"
    log "===== 成功路径也留档：xorg.log 尾部 25 行（modeset 证据）====="
    dump_xorg_tail 25
    log "===== 当前 DRM 状态（Xorg 起来后）====="
    for s in /sys/class/drm/card*/status; do
        [ -e "$s" ] && log "  $s = $(cat "$s" 2>/dev/null)"
    done
fi

# ------------------------------------------------------------------ 4. jwm + chromium
CHROME_LOG=/root/chromium.log
if [ -S /tmp/.X11-unix/X0 ] && x_ready; then
    log "--- 启动 jwm（降权到 kiosk）---"
    su kiosk -s /bin/sh -c "DISPLAY=:0 XAUTHORITY=$XAUTH exec jwm" >/root/jwm.log 2>&1 &
    sleep 3
    JWM_PID=$(pgrep -x jwm 2>/dev/null | head -n1)
    log "jwm pid=$JWM_PID"

    # GL 旗标复刻镜像自己的意图（/usr/local/bin/x11-session）：
    #   --ozone-platform=x11 --use-gl=angle --use-angle=gl  => ANGLE/GLX => Mesa llvmpipe
    # 若 GLX 模块缺失导致浏览器秒退，第 5 节会用 --disable-gpu 做一次对照重试，
    # 用"哪套旗标下 browser 存活 / 有截图差异"来把"GL 问题"与"X 问题"分开。
    # 旗标集刻意只用单行、无内嵌双引号：guest 是 BusyBox ash，
    # 多层引号 + 续行最容易出的错是"参数在传输中被吞掉"，
    # 那会得到一个假的"chromium 起不来"结论（M2 自证原则：先让判据可信）。
    CBASE="--ozone-platform=x11 --use-gl=angle --use-angle=gl --disable-vulkan"
    CBASE="$CBASE --disable-features=Vulkan --kiosk --noerrdialogs --disable-infobars"
    CBASE="$CBASE --no-first-run --no-default-browser-check --check-for-update-interval=31536000"
    CBASE="$CBASE --incognito --no-sandbox --disable-dev-shm-usage"
    CBASE="$CBASE --disable-crash-reporter --disable-breakpad --disable-crashpad"
    CBASE="$CBASE --mute-audio --disable-audio-output --enable-logging=stderr"

    launch_chromium() {   # $1=标签，$2=额外旗标串（可为空）
        tag="$1"; extra="$2"
        : > "$CHROME_LOG"
        log "--- chromium launch[$tag] extra=[$extra] ---"
        su kiosk -s /bin/sh -c "DISPLAY=:0 XAUTHORITY=$XAUTH exec chromium $CBASE $extra $URL" \
            >> "$CHROME_LOG" 2>&1 &
        CPID=$!
        sleep 30
        if kill -0 "$CPID" 2>/dev/null; then
            log "  -> chromium 存活 30s（pid=$CPID）"
            return 0
        fi
        log "  -> chromium 30s 内退出（见 $CHROME_LOG 尾部）"
        tail -n 25 "$CHROME_LOG" >> "$LOG" 2>&1
        tail -n 25 "$CHROME_LOG" > /dev/console 2>&1
        return 1
    }

    GL_OK=0
    launch_chromium "angle-gl-default" "" && GL_OK=1

    if [ "$GL_OK" != "1" ]; then
        log "===== 对照组：--disable-gpu + --in-process-gpu（隔离 GL 与 X 层）====="
        pkill -x chromium 2>/dev/null; sleep 3
        launch_chromium "disable-gpu-control" "--disable-gpu --in-process-gpu" \
            && log "对照组存活 -> 问题在 GL 层，X11/X 层是通的" \
            || log "对照组也失败 -> 优先怀疑 X11/X 层"
    fi

    # 进程存活判定一律走 /proc/<pid>，不用 pgrep（x-kernel procfs 不暴露进程名）
    log "进程快照: Xorg=[$([ -d /proc/$XPID ] && echo $XPID)] jwm=[$([ -n "${JWM_PID:-}" ] && [ -d /proc/$JWM_PID ] && echo $JWM_PID)] chromium=[$([ -n "${CPID:-}" ] && [ -d /proc/$CPID ] && echo $CPID)]"
    stage x11-session-launched
else
    stage x11-session-skipped
    log "Xorg 未就绪，跳过 jwm / chromium（本轮不会有图形证据）"
fi

sync
log "================ autorun_x11 done ================"
