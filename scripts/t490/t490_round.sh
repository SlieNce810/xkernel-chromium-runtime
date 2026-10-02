#!/usr/bin/env bash
# T490 · 通用单轮会话编排（注入任意 probe + 任意 autorun，然后跑一轮会话）
#
# 用法：
#   bash t490_round.sh <tag> <duration> <interval> <autorun文件名> [probe.c ...]
#
# 例：
#   bash t490_round.sh fetch 2400 120 autorun_fetch.sh evprobe.c
#   bash t490_round.sh p1fdpass 300 60 autorun_p1.sh fdprobe.c
#
# 约定：
#   - 源文件都在 guest 侧脚本目录 ~/xk6/scripts/t490/ 下
#   - <autorun文件名> 注入为 /root/autorun.sh（guest 的 99-autostart 会调它）
#     ★ 该 99-autostart 钩子由本脚本第 4a 步**随轮注入**（源码 guest-autostart.sh）：
#       agentos 官方镜像的 /etc/profile.d/ 里没有它，缺了就会"静默空跑一整轮"。
#       INJECT_AUTOSTART=0 可关闭该步骤。
#   - 每个 probe.c 交叉编译为静态 aarch64，注入到 /<basename 无扩展>，mode 0755
#   - 基础镜像由环境变量 BASE_IMG 指定，默认 images/p0-drmversion-fixed.img
#   - 环境变量 PKG_TARBALL：宿主侧打好的 tar.gz（由 t490_build_pkgs.sh 产出）
#     → 注入为 /pkgs.tar.gz，guest 内 tar -x 解开
#   - ★ 测试页（2026-09-22 起为「组委会三页套」）：
#     PAGE_DIR   = 页面集目录（默认 ~/xk6/scripts/testpage，内含官方 index/interaction/layout）
#     PAGE_FILES = 页面集清单（默认 "index.html interaction.html layout.html"）
#     PAGE_URL   = 本轮加载的入口 URL（默认 file:///usr/share/html-test/index.html）
#                  测 JS 交互页 → PAGE_URL=…/interaction.html
#                  测 CSS 布局页 → PAGE_URL=…/layout.html
#     注入由 t490_inject_pages.sh 完成（整套写盘 + 读回逐字节自证，失败即中止）。
#     PAGE_HTML  = （已弃用，保留兼容）单文件模式：只注入一个页面为 index.html
#
# ★ 阶段 A 新增：Ozone 运行期三元组（宿主变量 → 注入时烘焙进 guest 的 /root/autorun.sh）
#   - 环境变量 OZ_PLATFORM：wayland | headless          → --ozone-platform=
#   - 环境变量 GL_VARIANT ：none | legacy | angle-vulkan | angle-opengles | angle-swiftshader
#       none          → --disable-gpu（C0 存活控制组）
#       legacy        → --use-gl=swiftshader（复现本 build 的 gl=none，作对照）
#       angle-vulkan  → --use-gl=angle --use-angle=vulkan + VK_ICD_FILENAMES（主目标）
#       angle-opengles→ --use-gl=angle --use-angle=opengles
#       angle-swiftshader → --use-gl=angle --use-angle=swiftshader (CPU rendering)
#   - 环境变量 GPU_MODEL  ：in-process | separate       → 是否加 --in-process-gpu
#   - 环境变量 OBS_WINDOW ：guest 观察窗秒数（默认按会话时长推算：DUR − 100）
#   - 环境变量 RUN_A0    ：1 = 在 guest 内跑 A0 Ozone 后端枚举探针（默认 0 跳过）。
#       默认关的原因：探针要在 guest 内**再启动一个 chromium**，在软件光栅已吃满 CPU 时
#       会把会话尾段拖死（C1 轮实测）。A0 的答案已由宿主侧二进制符号探测 +
#       C0-r3 的 platform_selection.cc:46 FATAL 取得，无需每轮重跑。
#   为什么要"注入时替换"而不是直接 export：宿主环境变量进不了 guest，
#   make run 也没有 fw_cfg / -append 通道；t490_round.sh 里 BASE_IMG/PKG_TARBALL/
#   PAGE_HTML 的用法本来就只是"宿主侧读取 + 注入时烘焙"。
#
# 例：
#   PKG_TARBALL=~/xk6/tmp/pkgs-fetch.tar.gz \
#     bash t490_round.sh install 1200 120 autorun_install.sh
#   PAGE_URL=file:///usr/share/html-test/layout.html \
#     bash t490_round.sh css 600 120 autorun_v5.sh        # 只测 CSS 布局页
#
# 为什么要有它：v2 §8 要求"一套编排、一套证据格式"。此前每轮都手写注入脚本
# （t490_v7..v16 + t490_pull_v*），既重复又容易让 guest 侧脚本与本地副本失同步
# ——上一轮就因此误判过一次。
#
# 产出：~/xk6/evidence/<date>_t490-<tag>/{console.log,cmd.txt,env.txt,manifest.txt,timestamps.csv,screenshots/}

exec > "$HOME/xk6/tmp/t490_round_$1.log" 2>&1
set -x

export PATH="$HOME/qemu-root/usr/bin:$HOME/.cargo/bin:$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"

TAG="${1:?tag required}"
DUR="${2:-300}"
IVL="${3:-60}"
AUTORUN="${4:?autorun filename required}"
shift 4
PROBES="$*"

SRC_DIR="$HOME/xk6/scripts/t490"
# 该脚本的 autorun 注入流程针对旧 Weston 镜像；使用 agentos X11 镜像时，
# 由调用方显式传 BASE_IMG，并先按 report/24 的 X11 启动路径验证。
BASE_IMG="${BASE_IMG:-$HOME/x-kernel/images/p0-drmversion-fixed.img}"
PKG_TARBALL="${PKG_TARBALL:-}"
# ---- 测试页（组委会三页套）--------------------------------------------- #
PAGE_DIR="${PAGE_DIR:-$HOME/xk6/scripts/testpage}"
PAGE_FILES="${PAGE_FILES:-index.html interaction.html layout.html}"
PAGE_URL="${PAGE_URL:-file:///usr/share/html-test/index.html}"
PAGE_HTML="${PAGE_HTML:-}"              # 已弃用：单文件模式，见文件头说明

# ---- Ozone 运行期三元组（阶段 A）--------------------------------------- #
OZ_PLATFORM="${OZ_PLATFORM:-wayland}"   # 注入 __OZ_PLATFORM__
GL_VARIANT="${GL_VARIANT:-none}"        # 注入 __GL_VARIANT__
GPU_MODEL="${GPU_MODEL:-in-process}"    # 注入 __GPU_MODEL__
# 观察窗默认按会话时长推算，而不是写死一个常数：
#   会话 DUR 秒里，guest 启动 + 前置小节（解包/校验/fc-cache/weston）大约吃掉 55–60 s；
#   轮后分析已全部移到宿主侧（round_assert.sh），guest 尾部只剩 wc+sync（约 2 s），
#   所以只留 40 s 余量即可 ⇒ 窗口 = DUR − 100。
#   早期写死常数的后果实测过三次（C0 / C0-r2 / C1）：窗口吃满，尾部小节被会话超时砍掉。
#   DUR 很长时（如 10 分钟长稳轮）这条会自动放大。
OBS_WINDOW="${OBS_WINDOW:-$(( DUR - 100 ))}"
[ "$OBS_WINDOW" -ge 20 ] 2>/dev/null || OBS_WINDOW=20

RUN_A0="${RUN_A0:-0}"                   # 1 = 开启 guest 内 A0 探针（默认关，见文件头说明）
MP_TRACE_VALUE="${MP_TRACE_VALUE:-1}"   # 1 = guest strace diagnostics; 0 = normal run
MP_GL_VALUE="${MP_GL_VALUE:-angle}"     # angle or legacy Chromium GL selection
MP_NET_VALUE="${MP_NET_VALUE:-normal}"   # normal or disable NetworkService feature
SINGLE_HOLD_VALUE="${SINGLE_HOLD_VALUE:-600}"       # __SINGLE_HOLD_SECONDS__
SINGLE_SAMPLE_VALUE="${SINGLE_SAMPLE_VALUE:-15}"     # __SINGLE_SAMPLE_SECONDS__

# ⭐ 白名单校验：下面这几个值会被写进 guest 的 /root/autorun.sh 由 root shell 执行，
#    这是宿主变量进入 guest 的唯一通道，必须只放行枚举内的取值（防手误/注入）。
case "$OZ_PLATFORM" in
    wayland|headless) ;;
    *) echo "!! 非法 OZ_PLATFORM=$OZ_PLATFORM（允许 wayland|headless）"; exit 1 ;;
esac
case "$GL_VARIANT" in
    none|legacy|angle-vulkan|angle-opengles|angle-swiftshader) ;;
    *) echo "!! 非法 GL_VARIANT=$GL_VARIANT（允许 none|legacy|angle-vulkan|angle-opengles|angle-swiftshader）"; exit 1 ;;
esac
case "$GPU_MODEL" in
    in-process|separate) ;;
    *) echo "!! 非法 GPU_MODEL=$GPU_MODEL（允许 in-process|separate）"; exit 1 ;;
esac
case "$OBS_WINDOW" in
    ''|*[!0-9]*) echo "!! 非法 OBS_WINDOW=$OBS_WINDOW（须为正整数秒）"; exit 1 ;;
esac
case "$RUN_A0" in
    0|1) ;;
    *) echo "!! 非法 RUN_A0=$RUN_A0（允许 0|1）"; exit 1 ;;
esac
case "$MP_TRACE_VALUE" in
    0|1) ;;
    *) echo "!! 非法 MP_TRACE_VALUE=$MP_TRACE_VALUE（允许 0|1）"; exit 1 ;;
esac
case "$MP_GL_VALUE" in
    angle|legacy) ;;
    *) echo "!! 非法 MP_GL_VALUE=$MP_GL_VALUE（允许 angle|legacy）"; exit 1 ;;
esac
case "$MP_NET_VALUE" in
    normal|disable) ;;
    *) echo "!! 非法 MP_NET_VALUE=$MP_NET_VALUE（允许 normal|disable）"; exit 1 ;;
esac
case "$SINGLE_HOLD_VALUE" in
    ''|*[!0-9]*) echo "!! 非法 SINGLE_HOLD_VALUE=$SINGLE_HOLD_VALUE"; exit 1 ;;
esac
case "$SINGLE_SAMPLE_VALUE" in
    ''|*[!0-9]*) echo "!! 非法 SINGLE_SAMPLE_VALUE=$SINGLE_SAMPLE_VALUE"; exit 1 ;;
esac

# ⭐ PAGE_URL 同样会进 guest 的浏览器命令行，且会被写进 sed 替换式 —— 必须白名单化。
#    三层校验缺一不可（2026-09-22 实测出一个洞：`…/html-test/../layout.html`
#    能同时通过"形式合法 + 入口名合法 + 入口在页面集内"，但它实际指向
#    `/usr/layout.html` 这个不存在的路径 —— 于是整轮会"声称测 layout 页、
#    实际加载 404"。所以第一层必须显式拒绝 `..`）。
case "$PAGE_URL" in
    *..*) echo "!! 非法 PAGE_URL（含 .. 路径回溯）: $PAGE_URL"; exit 1 ;;
esac
case "$PAGE_URL" in
    file:///usr/share/html-test/*.html) ;;
    *) echo "!! 非法 PAGE_URL=$PAGE_URL（须形如 file:///usr/share/html-test/<page>.html）"; exit 1 ;;
esac
PAGE_ENTRY="${PAGE_URL##*/}"
case "$PAGE_ENTRY" in
    *[!A-Za-z0-9._-]*|*..*) echo "!! PAGE_URL 入口名含非法字符: $PAGE_ENTRY"; exit 1 ;;
esac
case " $PAGE_FILES " in
    *" $PAGE_ENTRY "*) ;;
    *) echo "!! PAGE_URL 的入口页 $PAGE_ENTRY 不在 PAGE_FILES=[$PAGE_FILES] 内（会启动到不存在的文件）"; exit 1 ;;
esac

cd "$HOME/x-kernel" || exit 1

# ---------------------------------------------------------------- 0. 前置（工具预检 + 会话互斥 + QEMU 探测）
#
# 为什么把这里从一行 pgrep 扩成三层（2026-09-22 阶段0.3）：
#   旧写法 `if pgrep -a qemu-system-aarch64` 只按**进程名**匹配，覆盖不了：
#     (a) 并发的第二个轮次脚本 —— 它会在第一个仍持有 disk.img 时 `cp -f` 覆盖，
#         属于 inode 级静默写坏（不报错，只得到错数据）；
#     (b) 名字不叫 qemu 的写入者（dd / debugfs / mount）；
#     (c) 检查命令自身命中自己（用 grep/ps 命令行找 qemu 时的经典自匹配）。
#   三层分别解决：工具预检（缺命令早失败）、flock 互斥（写盘互斥）、
#   /proc/<pid>/exe 判定（只认真正的 QEMU 可执行文件，不看命令行文本）。
PREFLIGHT_MISSING=""
for t in qemu-system-aarch64 debugfs e2fsck aarch64-linux-musl-gcc sha256sum flock tar; do
    command -v "$t" >/dev/null 2>&1 || PREFLIGHT_MISSING="$PREFLIGHT_MISSING $t"
done
[ -z "$PREFLIGHT_MISSING" ] || { echo "!! 工具预检失败，缺少:$PREFLIGHT_MISSING"; echo "   PATH=$PATH"; exit 1; }
echo "=== 工具预检 OK: $(qemu-system-aarch64 --version | head -1) ==="

LOCKF="$HOME/xk6/tmp/disk.img.lock"
mkdir -p "$HOME/xk6/tmp"
exec 9>"$LOCKF" || { echo "!! 无法打开锁文件 $LOCKF"; exit 1; }
if ! flock -n 9; then
    echo "!! 工作镜像已被另一轮会话锁定（$LOCKF）—— 拒绝并发写盘"
    echo "!! 排查: cat $LOCKF ; ps -ef | grep -F xk6"
    exit 1
fi
echo "=== 已取得工作镜像互斥锁: $LOCKF ==="

QEMU_FOUND=0
for p in /proc/[0-9]*; do
    pid="${p#/proc/}"
    exe="$(readlink -f "$p/exe" 2>/dev/null)" || continue
    case "${exe##*/}" in
        qemu-system-*)
            QEMU_FOUND=1
            echo "   qemu pid=$pid exe=$exe"
            echo "        cmdline=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null | cut -c1-180)"
            ;;
    esac
done
if [ "$QEMU_FOUND" -eq 1 ]; then
    echo "!! 检测到运行中的 QEMU（见上，按 /proc/<pid>/exe 判定）—— 改镜像前必须先停"
    exit 1
fi
echo "=== 无运行中的 QEMU 会话 ==="
[ -f "$BASE_IMG" ] || { echo "!! 基础镜像不存在: $BASE_IMG"; exit 1; }
[ -f "$SRC_DIR/$AUTORUN" ] || { echo "!! autorun 不存在: $SRC_DIR/$AUTORUN"; exit 1; }

echo "=== 基础镜像: $BASE_IMG ==="
sha256sum "$BASE_IMG"

# ---------------------------------------------------------------- 0.5 证据目录守卫
# 同名 tag 在同一天重跑会覆盖已完成的证据（run-session.py 里 console.log/cmd.txt/
# manifest.txt 都是 open(...,"w")，screenshots/ 也会撞同名）——AGENTS.md 明确要求
# "不得覆盖已完成的 run，应新建 scenario 目录"。这里直接拒绝启动，逼出换 tag。
EVID="$HOME/xk6/evidence/$(date +%Y-%m-%d)_t490-$TAG"
if [ -d "$EVID" ]; then
    echo "!! 证据目录已存在，拒绝覆盖已完成的 run: $EVID"
    echo "!! 请换 tag 重跑（例如 $TAG-r2），或先人工确认该轮无效后移走"
    exit 1
fi
echo "=== 证据目录（本轮将新建）: $EVID ==="
echo "=== 三元组: oz=$OZ_PLATFORM gl=$GL_VARIANT gpu=$GPU_MODEL win=$OBS_WINDOW a0=$RUN_A0 trace=$MP_TRACE_VALUE mpgl=$MP_GL_VALUE net=$MP_NET_VALUE ==="

# ---------------------------------------------------------------- 1. 换镜像
cp -f "$BASE_IMG" disk.img
e2fsck -f -y disk.img 2>&1 | tail -3

# ---------------------------------------------------------------- 2. 编译 probe
# 逐探针构建模式（2026-09-22 阶段1.2 新增）：源文件**第 1 行**可声明构建方式
#     // BUILD: static           （默认，未声明时）静态链接
#     // BUILD: dynamic          动态链接（运行期 dlopen 加载 guest 的库；阶段1.2 用）
#     // BUILD: dynamic-so       共享库（供 LD_PRELOAD 观测用）
# 为什么必须支持动态：musl 的**静态**链接没有 ld.so，无法加载 libdrm.so.2，
# 而"用 guest 真实 libdrm 走标准调用"这条证据只有动态链接才能拿到。
# guestlibs 布局：apk/usr/include/libdrm/*.h + apk/usr/include/xf86drm*.h（Alpine libdrm-dev 解包）
GUESTLIBS="${GUESTLIBS:-$HOME/xk6/guestlibs}"
MUSL_GCC=aarch64-linux-musl-gcc
COMPILED=""
for p in $PROBES; do
    name="${p%.c}"
    mode="$(sed -n '1s|^// BUILD: ||p' "$SRC_DIR/$p" 2>/dev/null | tr -d '\r' | awk '{print $1}')"
    case "$mode" in
        dynamic)
            echo "--- 编译 $p（dynamic，运行期 dlopen 加载 guest 的库）"
            # 为什么不加 -L/-l:guest 的 libdrm.so.2 含 .relr.dyn（DT_RELR）段，
            # 本工具链的 ld（binutils 2.36）不认，链接期必然失败；改为运行期 dlopen
            # 反而更硬：dladdr 会直接报出"实际加载了哪个文件"。
            # 但**头文件**仍要来自 guest 同版本的 libdrm-dev（两个 -I 缺一不可：
            # Alpine 把 xf86drm.h/xf86drmMode.h 放 usr/include/ 顶层，
            # 内核 uapi drm.h/drm_mode.h 放 usr/include/libdrm/）。
            $MUSL_GCC -O2 -Wall -Wextra -pthread \
                -I"$GUESTLIBS/apk/usr/include/libdrm" \
                -I"$GUESTLIBS/apk/usr/include" \
                -o "/tmp/$name" "$SRC_DIR/$p" \
                || { echo "!! 编译失败: $p"; exit 1; }
            ;;
        dynamic-so)
            echo "--- 编译 $p（dynamic-so）"
            $MUSL_GCC -O2 -Wall -Wextra -shared -fPIC -o "/tmp/$name.so" "$SRC_DIR/$p" \
                || { echo "!! 编译失败: $p"; exit 1; }
            name="$name.so"
            ;;
        *)
            $MUSL_GCC -static -O2 -Wall -Wextra -pthread -o "/tmp/$name" "$SRC_DIR/$p" \
                || { echo "!! 编译失败: $p"; exit 1; }
            ;;
    esac
    ls -la "/tmp/$name"
    COMPILED="$COMPILED $name"
done

# ---------------------------------------------------------------- 3. autorun
# 注入时把 5 个占位符替换成宿主侧的三元组取值（guest 是 busybox sh，没有 sed，
# 所以替换只能在宿主这一侧做）。替换完必须**硬校验无残留**：残留的占位符会被
# guest 当成合法旗标值传进 chromium，从而得到一个假的"失败"结论。
tr -d "\r" < "$SRC_DIR/$AUTORUN" \
  | sed -e "s|__OZ_PLATFORM__|$OZ_PLATFORM|g" \
        -e "s|__GL_VARIANT__|$GL_VARIANT|g" \
        -e "s|__GPU_MODEL__|$GPU_MODEL|g" \
        -e "s|__OBS_WINDOW__|$OBS_WINDOW|g" \
        -e "s|__RUN_A0__|$RUN_A0|g" \
        -e "s|__MP_TRACE__|$MP_TRACE_VALUE|g" \
        -e "s|__MP_GL__|$MP_GL_VALUE|g" \
        -e "s|__MP_NET__|$MP_NET_VALUE|g" \
        -e "s|__SINGLE_HOLD_SECONDS__|$SINGLE_HOLD_VALUE|g" \
        -e "s|__SINGLE_SAMPLE_SECONDS__|$SINGLE_SAMPLE_VALUE|g" > /tmp/autorun_inj.sh
[ -s /tmp/autorun_inj.sh ] || { echo "!! autorun 生成为空"; exit 1; }
# ⚠️ 正则必须含数字：占位符名里出现过 A0 这类带数字的（__RUN_A0__），
#    用 '__[A-Z_]+__' 会漏检，导致未替换的占位符被当合法取值传进 chromium。
if grep -nE '__[A-Za-z0-9_]+__' /tmp/autorun_inj.sh; then
    echo "!! 仍有未替换的占位符（见上），硬失败"
    exit 1
fi
chmod +x /tmp/autorun_inj.sh
echo "--- autorun 行数 ---"
wc -l /tmp/autorun_inj.sh
echo "--- 注入后三元组落点自证 ---"
grep -nE "^OZ_PLATFORM=|^GL_VARIANT=|^GPU_MODEL=|^OBS_WINDOW=|^RUN_A0=" /tmp/autorun_inj.sh

# ---------------------------------------------------------------- 3b. 页面入口烘焙
# 为什么不直接改 13 个 autorun 源文件里的启动 URL：那是一条"改一处漏一处"的老路
# （平台参数散落 4 处就是这么坏掉的，见 report/15）。这里沿用三元组的同一套做法：
# 宿主侧替换 → 只改注入副本，并对"替换是否真的生效"做自证。
if grep -qE 'file:///(usr/share/html-test/index\.html|root/index\.html)' /tmp/autorun_inj.sh; then
    sed -i -e "s|file:///usr/share/html-test/index\.html|$PAGE_URL|g" \
           -e "s|file:///root/index\.html|$PAGE_URL|g" /tmp/autorun_inj.sh
    grep -qF "$PAGE_URL" /tmp/autorun_inj.sh \
        || { echo "!! PAGE_URL 烘焙后未出现在 autorun 注入副本中: $PAGE_URL"; exit 1; }
    echo "--- 页面入口落点自证（注入副本内）---"
    grep -nF "$PAGE_URL" /tmp/autorun_inj.sh
else
    echo "!! 注意：本 autorun 内没有 file:// 启动行，PAGE_URL=$PAGE_URL 将不被使用"
fi

# ---------------------------------------------------------------- 4. 注入
for n in $COMPILED; do
    debugfs -w -R "rm /$n" disk.img >/dev/null 2>&1
    debugfs -w -R "write /tmp/$n /$n" disk.img
    debugfs -w -R "set_inode_field /$n mode 0100755" disk.img
done
debugfs -w -R "rm /root/autorun.sh" disk.img >/dev/null 2>&1
debugfs -w -R "write /tmp/autorun_inj.sh /root/autorun.sh" disk.img
debugfs -w -R "set_inode_field /root/autorun.sh mode 0100755" disk.img

# ---------------------------------------------------------------- 4a. autostart 钩子
# ★ 2026-09-22 补：本脚本文件头写的契约是「<autorun文件名> 注入为 /root/autorun.sh
#   （guest 的 99-autostart 会调它）」—— 但这条契约在 **agentos 官方 kiosk 镜像**
#   上根本不成立：实测该镜像 /etc/profile.d/ 只有 20locale.sh / README /
#   color_prompt.sh.disabled，没有任何东西会去执行 /root/autorun.sh。
#   后果是整轮"静默空跑"：QEMU 正常起、串口正常出 shell、guest 侧零动作，
#   screendump 恒为 "Display output is not active."（report/25 就是这么误判了一轮）。
#   所以把钩子补成**固定注入步骤**，并做读回自证：钩子缺失属于"最贵的一类失败"
#   ——它不报错，只是让整轮变成什么也没发生。
#
#   INJECT_AUTOSTART=0 可关闭（例如换一个已自带该钩子的镜像时）。
if [ "${INJECT_AUTOSTART:-1}" = "1" ]; then
    HOOK_SRC="$SRC_DIR/guest-autostart.sh"
    [ -f "$HOOK_SRC" ] || { echo "!! 缺少 autostart 钩子源文件: $HOOK_SRC"; exit 1; }
    tr -d "\r" < "$HOOK_SRC" > /tmp/99-autostart.sh
    debugfs -w -R "mkdir /etc/profile.d" disk.img >/dev/null 2>&1   # 已存在则报错，忽略
    debugfs -w -R "rm /etc/profile.d/99-autostart.sh" disk.img >/dev/null 2>&1
    debugfs -w -R "write /tmp/99-autostart.sh /etc/profile.d/99-autostart.sh" disk.img
    debugfs -w -R "set_inode_field /etc/profile.d/99-autostart.sh mode 0100644" disk.img
    # 读回自证：debugfs 的 write 在目标 inode 已存在时会静默失败，必须回读比对
    rm -f /tmp/99-autostart.rt
    debugfs -R "dump /etc/profile.d/99-autostart.sh /tmp/99-autostart.rt" disk.img >/dev/null 2>&1
    if [ -s /tmp/99-autostart.rt ] && cmp -s /tmp/99-autostart.sh /tmp/99-autostart.rt; then
        echo "--- autostart 钩子已注入并回读自证 OK（$(wc -c < /tmp/99-autostart.sh) bytes）---"
    else
        echo "!! autostart 钩子回读不一致/为空 —— 硬失败（否则整轮会静默空跑）"
        debugfs -R "stat /etc/profile.d/99-autostart.sh" disk.img 2>&1 | head -5
        exit 1
    fi
fi

# 包 tarball（单个文件注入，guest 内解包 —— 见 t490_build_pkgs.sh 的说明）
if [ -n "$PKG_TARBALL" ]; then
    [ -s "$PKG_TARBALL" ] || { echo "!! PKG_TARBALL 不存在或为空: $PKG_TARBALL"; exit 1; }
    echo "=== 注入 tarball: $PKG_TARBALL ==="
    ls -la "$PKG_TARBALL"
    debugfs -w -R "rm /pkgs.tar.gz" disk.img >/dev/null 2>&1
    debugfs -w -R "write $PKG_TARBALL /pkgs.tar.gz" disk.img
    debugfs -w -R "set_inode_field /pkgs.tar.gz mode 0100644" disk.img
fi

# 测试页（★ 组委会三页套：整套注入 + 读回自证，入口由 PAGE_URL 决定）
if [ -n "$PAGE_HTML" ]; then
    # 弃用路径：单文件 → /usr/share/html-test/index.html（保留兼容旧调用）
    [ -s "$PAGE_HTML" ] || { echo "!! PAGE_HTML 不存在或为空: $PAGE_HTML"; exit 1; }
    echo "!! 注意：PAGE_HTML 单文件模式已弃用，改用 PAGE_DIR/PAGE_FILES/PAGE_URL"
    echo "=== 注入测试页（单文件，弃用路径）: $PAGE_HTML ==="
    tr -d "\r" < "$PAGE_HTML" > /tmp/index.html
    debugfs -w -R "mkdir /usr/share/html-test" disk.img >/dev/null 2>&1
    debugfs -w -R "rm /usr/share/html-test/index.html" disk.img >/dev/null 2>&1
    debugfs -w -R "write /tmp/index.html /usr/share/html-test/index.html" disk.img
    debugfs -w -R "set_inode_field /usr/share/html-test/index.html mode 0100644" disk.img
else
    echo "=== 注入测试页（三页套）: $PAGE_DIR → /usr/share/html-test/ ==="
    echo "=== 入口: $PAGE_URL ==="
    if ! bash "$HOME/xk6/scripts/t490/t490_inject_pages.sh" disk.img "$PAGE_DIR" "$PAGE_ENTRY" \
            > "$HOME/xk6/tmp/pages-$TAG.txt" 2>&1; then
        echo "!! 页面集注入/自证失败，硬失败（不得带病起会话）："
        cat "$HOME/xk6/tmp/pages-$TAG.txt"
        exit 1
    fi
    cat "$HOME/xk6/tmp/pages-$TAG.txt"
fi

# ---------------------------------------------------------------- 5. 校验
e2fsck -f -y disk.img 2>&1 | tail -2
echo "--- 注入结果 ---"
for n in $COMPILED; do
    printf "%-14s " "/$n"
    debugfs -R "stat /$n" disk.img 2>/dev/null | grep -E "Mode:|Size:" | tr '\n' ' '; echo
done
printf "%-14s " "/root/autorun.sh"
debugfs -R "stat /root/autorun.sh" disk.img 2>/dev/null | grep -E "Mode:|Size:" | tr '\n' ' '; echo
if [ "${INJECT_AUTOSTART:-1}" = "1" ]; then
    printf "%-34s " "/etc/profile.d/99-autostart.sh"
    debugfs -R "stat /etc/profile.d/99-autostart.sh" disk.img 2>/dev/null \
        | grep -E "Mode:|Size:" | tr '\n' ' '; echo
fi
if [ -n "$PKG_TARBALL" ]; then
    printf "%-14s " "/pkgs.tar.gz"
    debugfs -R "stat /pkgs.tar.gz" disk.img 2>/dev/null | grep -E "Mode:|Size:" | tr '\n' ' '; echo
fi
if [ -n "$PAGE_HTML" ]; then
    printf "%-14s " "/usr/share/html-test/index.html"
    debugfs -R "stat /usr/share/html-test/index.html" disk.img 2>/dev/null | grep -E "Mode:|Size:" | tr '\n' ' '; echo
else
    for f in $PAGE_FILES; do
        printf "%-34s " "/usr/share/html-test/$f"
        debugfs -R "stat /usr/share/html-test/$f" disk.img 2>/dev/null | grep -E "Mode:|Size:" | tr '\n' ' '; echo
    done
    printf "%-34s " "/root/index.html（兼容副本）"
    debugfs -R "stat /root/index.html" disk.img 2>/dev/null | grep -E "Mode:|Size:" | tr '\n' ' '; echo
fi

# ---------------------------------------------------------------- 6. 会话
echo "=== 会话 tag=$TAG duration=$DUR interval=$IVL ==="
echo "=== 三元组 oz=$OZ_PLATFORM gl=$GL_VARIANT gpu=$GPU_MODEL win=$OBS_WINDOW a0=$RUN_A0 trace=$MP_TRACE_VALUE mpgl=$MP_GL_VALUE net=$MP_NET_VALUE ==="
bash "$HOME/xk6/scripts/t490/run_session_t490.sh" "$TAG" "$DUR" "$IVL"
echo "SESSION_RC=$?"

# 页面溯源入证据目录：会话跑完后 EVID 已由 run-session.py 建好，把注入自证清单
# 一并归档，这样"这一轮到底加载了哪几页、哪一页是入口、sha256 是多少"可独立复核。
if [ -f "$HOME/xk6/tmp/pages-$TAG.txt" ] && [ -d "$EVID" ]; then
    cp -f "$HOME/xk6/tmp/pages-$TAG.txt" "$EVID/pages.txt" \
        && echo "=== 页面清单已归档: $EVID/pages.txt ==="
fi

# 本轮指纹入证据目录（★ 2026-09-22 阶段0 补齐的取证缺口）
# 为什么必须有：历史证据目录**完全没有记录内核哈希**，导致"某一轮到底跑的是哪个
# 内核"只能靠文件时间戳间接推断 —— 本轮就因此多花了一次核实（见 report/32 §5）。
# 现在把 内核 / 基础镜像 / 页面集 / autorun / 关键脚本 的 sha256 与 git HEAD 一并归档。
if [ -d "$EVID" ]; then
    KERNEL_BIN="$HOME/x-kernel/target/xkmake/kplat-aarch64/release/kernel.bin"
    [ -f "$KERNEL_BIN" ] || KERNEL_BIN="$HOME/x-kernel/xkernel_aarch64-qemu.bin"
    {
        echo "### 本轮指纹（归档时间 $(date -Is)）"
        echo "ROUND_TAG    $TAG  DUR=$DUR IVL=$IVL"
        echo "AUTORUN      $AUTORUN"
        echo "--- 内核 ---"
        echo "KERNEL_BIN   $KERNEL_BIN"
        sha256sum "$KERNEL_BIN" 2>/dev/null
        echo "--- 基础镜像 ---"
        echo "BASE_IMG     $BASE_IMG"
        sha256sum "$BASE_IMG" 2>/dev/null
        echo "--- 页面集 ---"
        echo "PAGE_DIR     $PAGE_DIR   PAGE_URL=$PAGE_URL"
        for f in $PAGE_FILES; do sha256sum "$PAGE_DIR/$f" 2>/dev/null; done
        echo "--- 关键脚本 ---"
        sha256sum "$SRC_DIR/$AUTORUN" "$SRC_DIR/t490_round.sh" "$SRC_DIR/run_session_t490.sh" \
                  "$SRC_DIR/round_assert.sh" "$SRC_DIR/ppm_assert.py" 2>/dev/null
        echo "--- 源码状态 ---"
        ( cd "$HOME/x-kernel" && git rev-parse HEAD && git status --porcelain )
        echo "--- 平台参数（单一真源 platform.env 的实际取值）---"
        if [ -f "$SRC_DIR/platform.env" ]; then
            # 本脚本自身不 source platform.env（会话脚本才 source），
            # 这里在子 shell 里 source 一次只为记录**派生后的**真实取值。
            # shellcheck disable=SC1090
            ( . "$SRC_DIR/platform.env"; echo "PLAT_MAKE_ARGS=$PLAT_MAKE_ARGS" )
        fi
    } > "$EVID/build-manifest.txt" 2>&1
    echo "=== 本轮指纹已归档: $EVID/build-manifest.txt ==="
fi

echo "ROUND_DONE tag=$TAG"
echo "EVIDENCE=$EVID"
