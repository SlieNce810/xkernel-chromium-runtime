#!/bin/sh
# autorun_full.sh — 阶段一（冻结基线）+ 阶段二（最小故障复现矩阵）合体轮
#
# 与 autorun_install.sh 的关键差异（单一变量）：
#   ★ **去掉 --disable-gpu**。历史各轮 launch_chrome() 都带 --disable-gpu，
#     而 g17chr 轮日志给出证据：
#       ERROR:ui/gl/init/gl_factory.cc:110 Requested GL implementation
#       (gl=none,angle=none) not found in allowed implementations:
#       [(gl=egl-angle,angle=opengl),(gl=egl-angle,angle=opengles),(gl=egl-angle,angle=vulkan)]
#     → `gl=none` 正是 --disable-gpu 的直接后果；GL 初始化失败后 GPU 通道建不起来，
#       renderer 的合成器无从挂载。本轮按第七节(二) 冻结旗标**不再传 --disable-gpu**。
#   其余旗标严格照计划冻结：--ozone-platform=wayland --in-process-gpu
#   --use-gl=swiftshader --disable-gpu-sandbox --disable-crash-reporter + 非关键特性关闭项。
#
# 本脚本同时采集阶段二所需的静态事实与进程快照：
#   ① /proc/cpuinfo 全文字段（processor/CPU architecture/Features/CPU implementer/...）
#   ② /proc/sys/fs/inotify/* 与 /sys/devices/system/cpu/* 拓扑、cache（cpuinfo 库的其它输入）
#   ③ 子进程矩阵：每 5s 全量扫描 /proc，记录 chromium 各进程的 pid/线程数/状态/type=
#      —— 这是判定 "renderer 是否被 fork 出来、活了多久" 的唯一直接证据
#
# 日志：/root/full.log（持久盘；guest 的 /tmp 是 tmpfs，QEMU 一停就没了）

LOG=/root/full.log
: > "$LOG"

log() {
    echo "[full] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}
# 只进持久日志，不刷串口
ql() { "$@" >> "$LOG" 2>&1; }
# 同时进串口与日志
tl() { "$@" 2>&1 | tee -a "$LOG" /dev/console; }

log "start  alpine=$(cat /etc/alpine-release 2>/dev/null)  uname=$(uname -a 2>/dev/null)"

# ============================================================ 0. 静态事实（阶段二 ①②③）
log "===== 0. 静态事实 ====="

log "----- 0.1 /proc/cpuinfo 全文 -----"
cat /proc/cpuinfo >> "$LOG" 2>&1
# 串口只打关键字段的取值，便于人工核对
grep -E "^(processor|Features|CPU implementer|CPU architecture|CPU variant|CPU part|CPU revision|BogoMIPS|Hardware|Revision|Serial)" \
    /proc/cpuinfo > /dev/console 2>&1

log "----- 0.2 /proc/sys/fs/inotify -----"
if [ -d /proc/sys/fs/inotify ]; then
    log "  目录存在: $(ls /proc/sys/fs/inotify 2>&1 | tr '\n' ' ')"
    for f in max_queued_events max_user_instances max_user_watches; do
        v=$(cat "/proc/sys/fs/inotify/$f" 2>&1)
        log "  $f = $v"
    done
else
    log "  !! /proc/sys/fs/inotify 不存在（file_path_watcher_inotify.cc:922 的失败点）"
fi

log "----- 0.3 CPU 拓扑与 cache（cpuinfo 库的其它读点）-----"
for f in /sys/devices/system/cpu/possible /sys/devices/system/cpu/present \
         /sys/devices/system/cpu/online /sys/devices/system/cpu/kernel_max; do
    log "  $f = $(cat "$f" 2>&1)"
done
log "  cpu0 目录: $(ls /sys/devices/system/cpu/ 2>&1 | tr '\n' ' ')"
log "  cpu0/topology: $(ls /sys/devices/system/cpu/cpu0/topology 2>&1 | tr '\n' ' ')"
log "  cpu0/cache: $(ls /sys/devices/system/cpu/cpu0/cache 2>&1 | tr '\n' ' ')"
log "  cpu0/cpufreq: $(ls /sys/devices/system/cpu/cpu0/cpufreq 2>&1 | tr '\n' ' ')"

log "----- 0.4 进程自述 -----"
log "  /proc/self/status 关键行:"
grep -E "^(Name|Pid|PPid|Threads|CapEff|Seccomp)" /proc/self/status 2>/dev/null >> "$LOG"
grep -E "^(Name|Threads)" /proc/self/status > /dev/console 2>&1

# ============================================================ 0.5 sysfs CPU 拓扑垫片
# ★ 根因（上游 cpuinfo 源码级确认）：ARM64 Linux 上 cpuinfo_arm_linux_init() 的第一道门是
#       max_present  = 1 + cpuinfo_linux_get_max_present_processor()   // /sys/devices/system/cpu/present
#       max_possible = 1 + cpuinfo_linux_get_max_possible_processor()  // /sys/devices/system/cpu/possible
#       if ((max_present | max_possible) == 0) { log_error("failed to parse both lists ..."); return; }
#   两个文件都读不到 → 直接 return → 全局 cpuinfo_is_initialized 永远为 false
#   → Chromium 的 content_main_runner_impl.cc:414 打 "Failed to initialize cpuinfo"。
#   而 x-kernel **没有 sysfs**（fs/filesystems/ 下无 sysfs 实现，/sys 只是 rootfs 普通目录），
#   所以 present/possible 必然缺失 —— 这是 cpuinfo 初始化的真根因，/proc/cpuinfo 只是并列的第二道门。
#
#   在 sysfs 尚未落地为内核文件系统前，这里按引导环境的方式物化最小 CPU 视图；
#   取值与 /proc/cpuinfo 宣告的 CPU part 0xd0b（Cortex-A76，QEMU -cpu cortex-a76）一致，
#   cache 几何与该 uarch 的公开参数一致（L1I/L1D 64K、L2 512K）。
log "===== 0.5 物化 /sys/devices/system/cpu（sysfs 垫片）====="
CPUMAX=3
if command -v nproc >/dev/null 2>&1; then
    CPUMAX=$(( $(nproc) - 1 ))
fi
[ "$CPUMAX" -ge 0 ] 2>/dev/null || CPUMAX=3
CPU_LIST="0-${CPUMAX}"
SC=/sys/devices/system/cpu
mkdir -p "$SC" 2>/dev/null
printf '%s\n' "$CPU_LIST" > "$SC/possible" 2>/dev/null
printf '%s\n' "$CPU_LIST" > "$SC/present" 2>/dev/null
printf '%s\n' "$CPU_LIST" > "$SC/online" 2>/dev/null
printf '%s\n' "$CPUMAX"   > "$SC/kernel_max" 2>/dev/null
i=0
while [ "$i" -le "$CPUMAX" ]; do
    d="$SC/cpu$i"
    mkdir -p "$d/topology" "$d/cpufreq" 2>/dev/null
    printf '%s\n' "$i"        > "$d/topology/core_id" 2>/dev/null
    printf '0\n'              > "$d/topology/physical_package_id" 2>/dev/null
    printf '%s\n' "$CPU_LIST" > "$d/topology/core_siblings_list" 2>/dev/null
    printf '%s\n' "$i"        > "$d/topology/thread_siblings_list" 2>/dev/null
    printf '2400000\n'        > "$d/cpufreq/cpuinfo_max_freq" 2>/dev/null
    printf '600000\n'         > "$d/cpufreq/cpuinfo_min_freq" 2>/dev/null
    for idx in 0 1 2; do
        c="$d/cache/index$idx"
        mkdir -p "$c" 2>/dev/null
        case "$idx" in
            0) printf '1\n' > "$c/level"; printf 'Data\n'        > "$c/type"; printf '64K\n'  > "$c/size" ;;
            1) printf '1\n' > "$c/level"; printf 'Instruction\n' > "$c/type"; printf '64K\n'  > "$c/size" ;;
            2) printf '2\n' > "$c/level"; printf 'Unified\n'     > "$c/type"; printf '512K\n' > "$c/size" ;;
        esac
        printf '%s\n' "$i" > "$c/shared_cpu_list" 2>/dev/null
        printf '64\n'      > "$c/coherency_line_size" 2>/dev/null
    done
    i=$((i + 1))
done
log "  possible=$(cat $SC/possible 2>&1) present=$(cat $SC/present 2>&1) kernel_max=$(cat $SC/kernel_max 2>&1)"
log "  cpu0/cache/index2: size=$(cat $SC/cpu0/cache/index2/size 2>&1) shared_cpu_list=$(cat $SC/cpu0/cache/index2/shared_cpu_list 2>&1)"
log "  $SC 目录: $(ls $SC 2>&1 | tr '\n' ' ')"

# ============================================================ 1. 解包 / 校验 / 字体
log "===== 1. 解包 /pkgs.tar.gz ====="
CHROME_SZ=$(stat -c %s /usr/lib/chromium/chromium 2>/dev/null || echo 0)
if [ "$CHROME_SZ" -gt 1000000 ] 2>/dev/null; then
    log "  chromium 已就位（$CHROME_SZ 字节），跳过解包"
else
    if [ -f /pkgs.tar.gz ]; then
        ql tar -xzf /pkgs.tar.gz -C /
        log "  tar rc=$?"
    else
        log "  !! /pkgs.tar.gz 不存在，且 chromium 未就位"
    fi
fi
sync

log "===== 2. 关键文件实体校验 ====="
for f in /usr/lib/chromium/chromium /usr/bin/chromium /etc/fonts/fonts.conf \
         /usr/share/fonts/opensans/OpenSans-Regular.ttf; do
    log "  $(ls -l "$f" 2>&1 | tr -s ' ')"
done
log "  CHROME_SHA256: $(sha256sum /usr/lib/chromium/chromium 2>/dev/null | cut -c1-64)"
log "  chromium --version: $(chromium --version 2>&1 | head -1)"

log "===== 3. fc-cache ====="
if command -v fc-cache >/dev/null 2>&1; then
    ql fc-cache -f
    log "  fc-list 计数: $(fc-list 2>/dev/null | wc -l)"
fi

# ============================================================ 4. 输入设备
log "===== 4. 输入设备 ====="
mkdir -p /run/udev/data 2>/dev/null
cat > /run/udev/data/c13:1 <<'EOF'
E:ID_INPUT=1
E:ID_INPUT_KEYBOARD=1
E:ID_SEAT=seat0
EOF
log "  /dev/input 实况: $(ls -l /dev/input/ 2>&1 | tr '\n' '|')"

# ============================================================ 4.5 注入探针（阶段二）
# t490_round.sh 把每个 probe.c 交叉编译为静态 aarch64 并注入到 /<basename>。
# 命中即运行；输出同时进串口与持久日志，便于与 Linux 原生结果逐项对照。
for probe in /credprobe /childprobe /nvprobe /fdprobe /p2probe /evprobe /compatprobe; do
    if [ -x "$probe" ]; then
        log "===== 探针 $probe ====="
        tl "$probe"
        log "----- $probe 判定行 -----"
    fi
done

# ============================================================ 5. weston
log "===== 5. weston ====="
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
log "  seatd pid=$(pgrep -x seatd | head -n1)"

WL_SOCK=""
if [ -f /usr/local/lib/libseat-shim.so ]; then
    env LD_PRELOAD=/usr/local/lib/libseat-shim.so XDG_RUNTIME_DIR=/run/user/0 WESTON_DISABLE_ATOMIC=1 \
        weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
        --seat=seat0 --continue-without-input --idle-time=0 --socket=wayland-0 \
        --log=/tmp/weston.log >/dev/console 2>&1 &
    i=0
    while [ "$i" -lt 20 ]; do
        [ -n "$(ls /run/user/0 2>/dev/null | grep -E '^wayland-[0-9]+$')" ] && break
        i=$((i + 1)); sleep 1
    done
    log "  weston pid=$(pgrep -x weston | tr '\n' ' ')（等待 ${i}s）"
    WL_SOCK=$(ls /run/user/0 2>/dev/null | grep -E '^wayland-[0-9]+$' | head -n1)
    log "  wayland socket = ${WL_SOCK:-NONE}"
    grep -nE "Output 'Virtual-1'|desktop-shell|Quitting|ERROR|fatal" /tmp/weston.log > /dev/console 2>&1
else
    log "  !! libseat-shim.so 缺失"
fi

# ============================================================ 6. Chromium（冻结旗标）
log "===== 6. Chromium（阶段一冻结旗标，注意：无 --disable-gpu）====="
export XDG_RUNTIME_DIR=/run/user/0
export WAYLAND_DISPLAY="${WL_SOCK:-wayland-0}"
log "  WAYLAND_DISPLAY=$WAYLAND_DISPLAY"

# ★ 持久盘：guest /tmp 是 tmpfs，QEMU 一停日志即失
CHROME_LOG=/root/chrome-full.log
: > "$CHROME_LOG"
CHROME_DUMP=/root/chrome-snap.log
: > "$CHROME_DUMP"

rm -rf /tmp/chromium-baseline
mkdir -p /tmp/chromium-baseline

FROZEN_ARGS="--ozone-platform=wayland --no-sandbox --disable-dev-shm-usage \
--in-process-gpu --use-gl=swiftshader --disable-gpu-sandbox --disable-crash-reporter \
--disable-features=Vulkan,SegmentationPlatform,OptimizationGuideModelDownloading,OptimizationHints,WebAppProvider,InterestFeedContentSuggestions,AudioServiceOutOfProcess,AudioServiceSandbox \
--disable-background-networking --disable-component-update --disable-sync --disable-extensions \
--no-first-run --no-default-browser-check --mute-audio --disable-audio-output \
--enable-logging=stderr --v=1"

log "  FROZEN_ARGS=$FROZEN_ARGS"

# 全量进程快照：pid / 线程数 / 状态 / --type=。这是"renderer 有没有被 fork"的直接判据。
snapshot() {
    tag="$1"
    n=0
    for p in /proc/[0-9]*; do
        [ -r "$p/cmdline" ] || continue
        c=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
        case "$c" in
            *chromium*) ;;
            *) continue ;;
        esac
        pid=${p#/proc/}
        st=$(awk '{print $3}' "$p/stat" 2>/dev/null)
        thr=$(ls -d "$p"/task/* 2>/dev/null | wc -l)
        ty=$(echo " $c" | grep -oE 'type=[a-z_-]+' | head -n1)
        [ -n "$ty" ] || ty="type=(browser/none)"
        echo "$(date 2>/dev/null) [$tag] pid=$pid thr=$thr st=$st $ty" >> "$CHROME_DUMP"
        n=$((n + 1))
    done
    echo "[full]   SNAP[$tag] 匹配进程数=$n" >> "$CHROME_LOG"
    grep "\[$tag\]" "$CHROME_DUMP" | tail -n 20 >> "$CHROME_LOG"
    return "$n"
}

log "  【启动】chromium $FROZEN_ARGS file:///usr/share/html-test/index.html"
# shellcheck disable=SC2086
chromium $FROZEN_ARGS --user-data-dir=/tmp/chromium-baseline \
    file:///usr/share/html-test/index.html >> "$CHROME_LOG" 2>&1 &
CPID=$!
log "  browser 主 pid=$CPID"

# 150s 观察窗，每 5s 一次全量快照
j=0
seen_renderer=0
while [ "$j" -lt 150 ]; do
    if ! kill -0 "$CPID" 2>/dev/null; then
        wait "$CPID"; rc=$?
        log "  !! browser 已退出 rc=$rc（存活约 ${j}s）"
        break
    fi
    snapshot "t${j}"
    if grep -q "type=renderer" "$CHROME_DUMP" 2>/dev/null; then
        [ "$seen_renderer" -eq 0 ] && log "  ★ 首次出现 type=renderer（t=${j}s）"
        seen_renderer=1
    fi
    # 每 30s 向串口报一次紧凑状态
    if [ $((j % 30)) -eq 0 ]; then
        log "  t=${j}s renderer=$(grep -c 'type=renderer' "$CHROME_DUMP" 2>/dev/null) 进程表: $(grep "\[t$j\]" "$CHROME_DUMP" 2>/dev/null | tr '\n' '|')"
    fi
    j=$((j + 5))
    sleep 5
done

log "===== 6.1 进程快照汇总（去重后的 type 集合）====="
grep -oE 'type=[a-z_-]+|type=\(browser/none\)' "$CHROME_DUMP" 2>/dev/null | sort | uniq -c >> "$CHROME_LOG"
grep -oE 'type=[a-z_-]+|type=\(browser/none\)' "$CHROME_DUMP" 2>/dev/null | sort | uniq -c > /dev/console 2>&1
log "  renderer 出现次数: $(grep -c 'type=renderer' "$CHROME_DUMP" 2>/dev/null)"
log "  browser 仍在: $(kill -0 "$CPID" 2>/dev/null && echo yes || echo no)"

log "===== 6.2 Chromium 日志关键行 ===="
{
    echo "--- cpuinfo ---";  grep -n "cpuinfo" "$CHROME_LOG"
    echo "--- inotify ---";  grep -n "inotify" "$CHROME_LOG"
    echo "--- credentials ---"; grep -n "credentials" "$CHROME_LOG"
    echo "--- GL/GPU ---";  grep -nE "gl_factory|InitializeGL|gpu_init|GPU process|gl=none" "$CHROME_LOG"
    echo "--- 进程/zygote ---"; grep -nE "zygote|ZygoteMain|render_process_host|Failed to launch|spawn|child" "$CHROME_LOG"
    echo "--- 导航 ---";     grep -nE "FileURLLoader|navigation|commit" "$CHROME_LOG"
    echo "--- ERROR/FATAL 计数 ---"; grep -c "ERROR" "$CHROME_LOG"; grep -c "FATAL" "$CHROME_LOG"
    echo "--- FATAL 行 ---"; grep -n "FATAL" "$CHROME_LOG"
} >> "$CHROME_LOG" 2>&1
grep -nE "cpuinfo|gl_factory|gl=none|ZygoteMain|type=renderer|FileURLLoader|FATAL" "$CHROME_LOG" | tail -n 60 > /dev/console 2>&1

log "  chromium.log 共 $(wc -l < "$CHROME_LOG" 2>/dev/null) 行；快照 $(wc -l < "$CHROME_DUMP" 2>/dev/null) 行"

if kill -0 "$CPID" 2>/dev/null; then
    log "  browser 存活 → 保持运行供外部 screendump"
else
    log "  browser 未存活"
fi
sync
log "done"
