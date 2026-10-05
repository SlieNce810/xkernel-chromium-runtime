#!/bin/sh
# autorun_v3.sh — 阶段 A：Ozone 运行期三元组定标轮
#
# 由 autorun_full.sh 派生（保持"冻结基线 + 最小故障复现矩阵"的能力），差异只有下面 7 处：
#
#   ① 开头多打一行 VARIANT，把三元组写进串口与 /root/full.log（进证据）
#   ② weston 等待循环补回 `pgrep -x weston || break` 早退（autorun_install.sh:137 有，
#      autorun_full.sh 丢了 ⇒ 会盲等满 20 s，白吃观察窗预算）
#   ③ FROZEN_ARGS 改为按三元组拼装：--ozone-platform / GL 实现 / GPU 进程模型
#   ④ 启动改为 `env $GL_ENV chromium ...`：ICD 变量只作用于 chromium 子进程
#   ⑤ 观察窗由硬编码 150 s 改为 __OBS_WINDOW__ 占位符
#   ⑥ 每 30 s 报状态时补一次 sync（QEMU 被 Ctrl-A x 提前杀时日志不再残缺）
#   ⑦ 新增 §6.9 A0：向不存在的平台名发起一次短启动，抓 Ozone 的可用后端枚举
#
# ★★ 四个占位符 **必须** 由宿主侧 t490_round.sh 在 debugfs 注入前替换，绝不留在 guest：
#      __OZ_PLATFORM__  wayland | headless
#      __GL_VARIANT__   none | legacy | angle-vulkan | angle-opengles
#      __GPU_MODEL__    in-process | separate
#      __OBS_WINDOW__   观察窗秒数（须 ≤ duration − t_launch − 30）
#    guest 里读到未替换的占位符时会立刻 log + exit 1（见 §6 开头的自检）。
#
# 为什么三元组必须走"宿主替换 + 注入"而不是环境变量：
#   宿主环境变量进不了 guest，`make run` 也没有 fw_cfg/`-append` 通道把变量送进去；
#   t490_round.sh 里 BASE_IMG/PKG_TARBALL/PAGE_HTML 的用法同样只是"宿主侧读取 + 注入时烘焙"。
#
# 为什么 GL 取值是这几个（本 build 实测）：
#   ui/gl/init/gl_factory.cc:110 打印的 allowed implementations 只有
#     [(gl=egl-angle,angle=opengl),(gl=egl-angle,angle=opengles),(gl=egl-angle,angle=vulkan)]
#   ⇒ `--use-gl=swiftshader` 落到 gl=none（历史各轮 "--use-gl=swiftshader" 的报错来源），
#     本 build 的软件光栅只有 ANGLE + Vulkan + SwiftShader ICD 这一条路。
#
# 日志：/root/full.log（持久盘；guest 的 /tmp 是 tmpfs，QEMU 一停就没了）
# 前缀仍用 [full] —— 与历史日志/回收脚本（pull_guest_logs.sh 的 _root_full.log）保持可 grep 一致。

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

# ============================================================ 0. 静态事实
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
#   两个文件都读不到 → 直接 return。x-kernel **没有 sysfs**，所以 present/possible 必然缺失。
#   但注意：这条只是"非致命提示"的诱因（上游只有 log_error + return），**不是 renderer 的阻塞点**
#   —— report/19 已用两轮对照证否。此处保留垫片只为消除噪声，不影响本轮的判据。
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

# ============================================================ 4.5 注入探针
# t490_round.sh 把每个 probe.c 交叉编译为静态 aarch64 并注入到 /<basename>。
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
        # ★ 修正②：weston 自己死了就别再等 —— 否则盲等满 20 s，白吃观察窗预算
        pgrep -x weston >/dev/null 2>&1 || break
        [ -n "$(ls /run/user/0 2>/dev/null | grep -E '^wayland-[0-9]+$')" ] && break
        i=$((i + 1)); sleep 1
    done
    log "  weston pid=$(pgrep -x weston | tr '\n' ' ')（等待 ${i}s）"
    WL_SOCK=$(ls /run/user/0 2>/dev/null | grep -E '^wayland-[0-9]+$' | head -n1)
    log "  wayland socket = ${WL_SOCK:-NONE}"
    grep -nE "Output 'Virtual-1'|desktop-shell|Quitting|ERROR|fatal" /tmp/weston.log > /dev/console 2>&1
    log "  weston 输出模式行: $(grep -nE "Output 'Virtual-1'|mode " /tmp/weston.log 2>/dev/null | head -3 | tr '\n' '|')"
else
    log "  !! libseat-shim.so 缺失"
fi

# ============================================================ 6. Chromium（三元组）
log "===== 6. Chromium（Ozone 三元组定标）====="
export XDG_RUNTIME_DIR=/run/user/0
export WAYLAND_DISPLAY="${WL_SOCK:-wayland-0}"

# ---------------------------------------------------------- 三元组拼装（修正③④）
OZ_PLATFORM='__OZ_PLATFORM__'
GL_VARIANT='__GL_VARIANT__'
GPU_MODEL='__GPU_MODEL__'
OBS_WINDOW='__OBS_WINDOW__'

# ★ 占位符自检：若是宿主替换漏了，这里必须大声失败——
#   绝不能用"未替换的占位符"当合法旗标值去启动 chromium，那会得到一个假的失败结论。
case "$OZ_PLATFORM" in
    wayland|headless) ;;
    *) log "!! 占位符未替换或取值非法: OZ_PLATFORM='$OZ_PLATFORM'"; exit 1 ;;
esac
case "$GL_VARIANT" in
    none|legacy|angle-vulkan|angle-opengles) ;;
    *) log "!! 占位符未替换或取值非法: GL_VARIANT='$GL_VARIANT'"; exit 1 ;;
esac
case "$GPU_MODEL" in
    in-process|separate) ;;
    *) log "!! 占位符未替换或取值非法: GPU_MODEL='$GPU_MODEL'"; exit 1 ;;
esac
case "$OBS_WINDOW" in
    ''|*[!0-9]*) log "!! 占位符未替换或取值非法: OBS_WINDOW='$OBS_WINDOW'"; exit 1 ;;
esac

# GPU 进程模型
case "$GPU_MODEL" in
    in-process) GPU_FLAG="--in-process-gpu" ;;
    separate)   GPU_FLAG="" ;;
esac

# GL 实现（guest 是 busybox sh，**没有 sed**，只能用 case 拼串）
GL_EXTRA=""
GL_ENV=""
case "$GL_VARIANT" in
    none)
        # C0 控制组：显式关掉 GPU ⇒ 复现历史"窗口能画出来、browser 活得久、但页面不渲染"
        GL_EXTRA="--disable-gpu" ;;
    legacy)
        # 故意用历史那个**无效**取值，复现 gl_factory.cc:110 的 gl=none，作对照组
        GL_EXTRA="--use-gl=swiftshader" ;;
    angle-vulkan)
        # 本 build 唯一可行的软件光栅路径：ANGLE + Vulkan + SwiftShader ICD
        GL_EXTRA="--use-gl=angle --use-angle=vulkan"
        GL_ENV="VK_ICD_FILENAMES=/usr/lib/chromium/vk_swiftshader_icd.json VK_DRIVER_FILES=/usr/lib/chromium/vk_swiftshader_icd.json" ;;
    angle-opengles)
        GL_EXTRA="--use-gl=angle --use-angle=opengles" ;;
esac

# ★ 变体值随串口与 /root/full.log 进证据（修正①）
log "VARIANT oz=$OZ_PLATFORM gl=$GL_VARIANT gpu=$GPU_MODEL win=$OBS_WINDOW"
log "  GPU_FLAG=[$GPU_FLAG]  GL_EXTRA=[$GL_EXTRA]  GL_ENV=[$GL_ENV]"

# ★ 持久盘：guest /tmp 是 tmpfs，QEMU 一停日志即失
CHROME_LOG=/root/chrome-full.log
: > "$CHROME_LOG"
CHROME_DUMP=/root/chrome-snap.log
: > "$CHROME_DUMP"

rm -rf /tmp/chromium-baseline
mkdir -p /tmp/chromium-baseline

FROZEN_ARGS="--ozone-platform=$OZ_PLATFORM --no-sandbox --disable-dev-shm-usage \
$GPU_FLAG $GL_EXTRA --disable-gpu-sandbox --disable-crash-reporter \
--disable-features=Vulkan,SegmentationPlatform,OptimizationGuideModelDownloading,OptimizationHints,WebAppProvider,InterestFeedContentSuggestions,AudioServiceOutOfProcess,AudioServiceSandbox \
--disable-background-networking --disable-component-update --disable-sync --disable-extensions \
--no-first-run --no-default-browser-check --mute-audio --disable-audio-output \
--enable-logging=stderr --v=1"

log "  FROZEN_ARGS=$FROZEN_ARGS"

# 全量进程快照：pid / 状态 / --type=。这是"renderer 有没有被 fork"的直接判据。
#
# ★★ v3 关键改造：**全程只用 shell 内建，零 fork**。
#   历史实现每个进程都要 fork 出 tr / awk / grep 各一次，而 /proc 里有 60–80 个进程
#   ⇒ 单次快照 200+ 次 fork。TCG 下 fork+exec 的代价极高，实测单次快照 10 s 起步，
#   且随 chromium 线程数增长而恶化（2026-09-22 C0-r2 轮：7 次快照吃掉 69 s，
#   最后几次迭代超过 47 s 都没跑完，导致 §6.1/§6.2/§6.9 与 A0 全被会话超时砍掉）。
#   改为：
#     - cmdline / stat 用 shell 内建 `read` 读入变量（不再 fork cat/tr）
#     - 字段切分全部用参数展开（不再 fork awk/cut）
#     - type= 提取用 ${var#*pattern} + ${var%%[!class]*}（不再 fork grep）
#     - date 每次快照只取一次（不再每进程 fork）
#   注意：read 在内核不写换行的情况下会返回非 0 但**变量已被赋值**，所以判空而不是判返回值。
snapshot() {
    tag="$1"
    n=0
    _dt=$(date 2>/dev/null)
    for p in "${PROC_ROOT:-/proc}"/[0-9]*; do
        cl=""
        read -r cl < "$p/cmdline" 2>/dev/null
        [ -n "$cl" ] || continue
        case "$cl" in
            *chromium*) ;;
            *) continue ;;
        esac
        st="?"
        stline=""
        read -r stline < "$p/stat" 2>/dev/null
        if [ -n "$stline" ]; then
            # stat 第 2 字段是 (comm)，进程名可能含空格/括号 → 从**最后一个 ')' 之后**切
            st=${stline##*\) }
            st=${st# }
            st=${st%%[ ]*}
        fi
        # type= 提取：**不能用字符类截断**——`read` 会把 cmdline 里的 NUL 丢掉，
        # 参数被拼成一整串（"--type=renderer--no-sandbox"），此时任何
        # `${x%%[!a-z_-]*}` 都截不准（`-` 在括号表达式里会与相邻字符构成区间）。
        # 改成只认已知取值：阶段 A 的判据只需要 renderer / gpu-process 的有无，
        # 未知取值统一归 other（明细仍可从 chrome-full.log 查）。
        ty="type=(browser/none)"
        case "$cl" in
            *type=renderer*)         ty="type=renderer" ;;
            *type=gpu-process*)      ty="type=gpu-process" ;;
            *type=utility*)          ty="type=utility" ;;
            *type=zygote*)           ty="type=zygote" ;;
            *type=crashpad-handler*) ty="type=crashpad-handler" ;;
            *type=*)                 ty="type=other" ;;
        esac
        # pid 取路径末段，而不是靠 `${p#/proc/}`（换成夹具路径就会失效）
        echo "$_dt [$tag] pid=${p##*/} st=$st $ty" >> "$CHROME_DUMP"
        n=$((n + 1))
    done
    echo "[full]   SNAP[$tag] n=$n" >> "$CHROME_LOG"
    return "$n"
}

log "  【启动】env $GL_ENV chromium $FROZEN_ARGS file:///usr/share/html-test/index.html"
# shellcheck disable=SC2086
env $GL_ENV chromium $FROZEN_ARGS --user-data-dir=/tmp/chromium-baseline \
    file:///usr/share/html-test/index.html >> "$CHROME_LOG" 2>&1 &
CPID=$!
log "  browser 主 pid=$CPID"

# 观察窗 = __OBS_WINDOW__ 秒**墙钟**，每 5s 一次全量快照（修正⑤）
#
# ★★ 为什么必须是墙钟而不是计数器：
#   autorun_full.sh 原来写 `j=0; while [ $j -lt 150 ]; do ...; j=$((j+5)); sleep 5; done`，
#   隐含假设"每次迭代恰好 5 s"。但 TCG 下 snapshot() 扫 /proc 的开销就有 8–10 s，
#   实测单次迭代 **13–16 s**（2026-09-22 C0 轮：t=0 在 04:16:48，t=30 在 04:18:09）。
#   于是 j=75 需要 ~225 s 墙钟，而会话只有 180 s ⇒ 观察循环被整段砍掉，
#   §6.1/§6.2/§6.9（含 A0 探针）**全都不会执行**，且末尾 sync 也丢。
#   改用墙钟后，窗口长度与会话时长可以精确对齐。
OBS_START=$(date +%s)
j=0
seen_renderer=0
_last_report=0
# 快照间隔：TCG 下单次快照本身要 2–3 s（36 个进程 × 2 次 procfs read），
# 5 s 间隔意味着采样约占一半 CPU。保持 5 s 是为了与 C0-r3 可比。
SNAP_SLEEP=5
while : ; do
    _now=$(date +%s)
    _el=$((_now - OBS_START))
    [ "$_el" -lt "$OBS_WINDOW" ] || break
    if ! kill -0 "$CPID" 2>/dev/null; then
        wait "$CPID"; rc=$?
        log "  !! browser 已退出 rc=$rc（观察窗内 t=${_el}s）"
        break
    fi
    snapshot "t${j}"
    _it=$(( $(date +%s) - _now ))
    # 快照变慢是会"吃掉后续小节"的前兆，显式记下来便于下一轮校准窗口
    if [ "$_it" -ge 8 ]; then
        log "  !! 单次快照耗时 ${_it}s（偏慢：guest 可能正被软件光栅吃满 CPU）"
    fi
    if grep -q "type=renderer" "$CHROME_DUMP" 2>/dev/null; then
        [ "$seen_renderer" -eq 0 ] && log "  ★ 首次出现 type=renderer（t=${_el}s wall / j=${j}）"
        seen_renderer=1
    fi
    # ★ 快照之后再判一次截止：一次慢快照可能就把窗口耗尽，
    #   这时必须立刻收尾，而不是再去做下一次快照。
    _now=$(( $(date +%s) - OBS_START ))
    [ "$_now" -lt "$OBS_WINDOW" ] || { j=$((j + SNAP_SLEEP)); break; }
    # 每满 30s 墙钟向串口报一次紧凑状态，并 sync 落盘（修正⑥）
    if [ $((_el - _last_report)) -ge 30 ]; then
        _last_report=$_el
        log "  wall=${_el}s renderer=$(grep -c 'type=renderer' "$CHROME_DUMP" 2>/dev/null) 进程表: $(grep "\[t$j\]" "$CHROME_DUMP" 2>/dev/null | tr '\n' '|')"
        sync
    fi
    j=$((j + SNAP_SLEEP))
    sleep "$SNAP_SLEEP"
done
log " 观察窗结束：墙钟 $(( $(date +%s) - OBS_START ))s（j 计到 $j，共 $(grep -c 'SNAP\[' "$CHROME_LOG" 2>/dev/null) 次快照）"
sync

# ============ 6.1/6.2 已移到宿主侧（round_assert.sh）============
# ★ v3 的重要简化：原来在 guest 里做 §6.1（type= 直方图）与 §6.2（日志关键行 grep），
#   需要把 26 KB 日志在 guest 内 grep 好几遍。实测这一步连同 §6.9 A0（要在 guest 里
#   再启动一个 chromium！）会把会话最后 40–60 s 全部吃掉，导致这些小节**永远不会执行**
#   （C0、C0-r2、C1 三轮连续复现）。
#   而它们做的事在宿主侧做更好：round_assert.sh 已经对**拉回来的同一批日志**算了
#   type= 直方图与关键行摘录，且不占 guest 一点 CPU。所以 guest 尾部只留一个同步点。
log "===== 6.1/6.2 已在宿主侧 round_assert.sh 完成（guest 不再重复计算）====="
log "  renderer 出现次数(guest 现值): $(grep -c 'type=renderer' "$CHROME_DUMP" 2>/dev/null)"
log "  gpu-process 出现次数(guest 现值): $(grep -c 'type=gpu-process' "$CHROME_DUMP" 2>/dev/null)"
log "  browser 仍在: $(kill -0 "$CPID" 2>/dev/null && echo yes || echo no)"
sync

# ============================================================ 6.9 A0 Ozone 后端枚举（可选）
# ★ 默认**不执行**：A0 要在 guest 内再启动一个 chromium，在软件光栅已吃满 CPU 的情况下
#   会把会话尾段彻底拖死（C1 轮实测）。阶段 A 的 A0 答案已经拿到（宿主侧二进制符号探测 +
#   C0-r3 的 platform_selection.cc:46 FATAL），无需每轮重跑。
#   需要时把占位符 __RUN_A0__ 置 1。
RUN_A0='__RUN_A0__'
if [ "$RUN_A0" = "1" ]; then
    log "===== 6.9 A0 Ozone 后端枚举 ====="
    env XDG_RUNTIME_DIR=/run/user/0 WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
        chromium --ozone-platform=xk-nonexistent --no-sandbox --disable-gpu \
        --disable-crash-reporter --disable-dev-shm-usage --enable-logging=stderr --v=1 \
        --user-data-dir=/tmp/a0-profile about:blank > /root/a0.log 2>&1 &
    A0PID=$!
    a=0
    while [ "$a" -lt 10 ]; do
        kill -0 "$A0PID" 2>/dev/null || break
        a=$((a + 1)); sleep 1
    done
    kill -9 "$A0PID" 2>/dev/null
    pkill -9 -f "a0-profile" 2>/dev/null
    wait "$A0PID" 2>/dev/null
    log "  a0 探针运行 ${a}s，stderr $(wc -l < /root/a0.log 2>/dev/null) 行"
    grep -aiE "ozone|allowed implementations|unknown platform|not found|platform" /root/a0.log 2>/dev/null \
        | head -20 | tee -a "$LOG" /dev/console
    sync
else
    log "===== 6.9 A0 探针本轮跳过（RUN_A0=$RUN_A0）====="
fi

log "  chromium-stderr 行数 $(wc -l < "$CHROME_LOG" 2>/dev/null)；快照行数 $(wc -l < "$CHROME_DUMP" 2>/dev/null)"

if kill -0 "$CPID" 2>/dev/null; then
    log "  browser 存活 → 保持运行供外部 screendump"
else
    log "  browser 未存活（观察窗内/后退出）"
fi
sync
log "done  variant=$OZ_PLATFORM/$GL_VARIANT/$GPU_MODEL win=$OBS_WINDOW"
