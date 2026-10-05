#!/bin/sh
# autorun_weston.sh —— Weston 装包 + 首次启动轮（M2：图形会话真正建立输出）
#
# 本脚本在 guest 内以 root 运行（由 /etc/profile.d/99-autostart.sh 拉起 /root/autorun.sh）。
# 四个小节严格按「先只读 → 后写入 → 再启动」排序：
#
#   A. 修正版 drmpropprobe —— 拿属性名（name）与 flags 解码证据。**只读**，不改变系统状态。
#      （上一轮 before/after 的 rc/errno 证据已经锁定结论；本轮补 name 是为了
#        让证据自解释：证明 768 这个 prop_id 的名字确实是 "CRTC_ID"。）
#   B. apk 装 Weston 全家桶 —— 网络已实测可用（net_ok, apk_update_rc=0）。
#      装包清单逐字取自官方 uapps/weston-start/xk-weston-start 的 install_deps()。
#   C. 启动 seatd + weston —— 参数形态取自同一个官方启动器，不自创参数。
#      本轮**保留** WESTON_DISABLE_ATOMIC=1：官方就是这么写的，先按官方跑通（单一变量）；
#      "修复属性面后能否去掉这个绕行"留给下一轮做增量验证。
#   D. 周期记录 —— 供宿主侧 run-session.py 的周期 screendump 观察：
#      画面从 "Display output is not active." 变成真实内容（桌面背景/客户端窗口）才算 M2 过。
#
# 为什么必须在 guest 内装包而不是注入二进制：
#   官方启动器本身就是 apk 路线（它假设 rootfs 是 Alpine 且能联网），
#   且 agentos 镜像已内置 main+community 双源 —— 顺着官方的路子走，可追溯性最好。
#
# 输出：/root/weston-round.log 主日志（已登记进 round_assert.sh 回收清单）
#       /root/weston.log /root/seatd.log /root/weston-install.log /root/simple-shm.log
#       /root/prop.log（探针小节）
#
# 注意：本文件会被 t490_round.sh 做过「双下划线包裹的占位符」替换与残留硬校验，
#       正文里不得出现该形式的字符串 —— 注释里也不行。

LOG=/root/weston-round.log
: > "$LOG"
RD=/run/user/0

log() {
    echo "[weston-round] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}

# 有界后台执行（探针/装包都可能卡住，不能让整轮跟着无限等）。
# 用法：RC=$(run_bounded_out <名字> <秒上限> <输出文件> <命令...>)
# ⚠ 坑：重定向必须写在函数**内部**（作用于被跑的命令）。
#   若写成 `RC=$(run_bounded ... >> file 2>&1)`，重定向会作用于整个函数调用，
#   连 `echo $?` 都被一起吞进文件 —— RC 恒为空，看起来像"命令没返回码"。
run_bounded_out() {
    name="$1"; limit="$2"; out="$3"; shift 3
    : >> "$out"
    "$@" >> "$out" 2>&1 &
    pp=$!
    j=0
    while [ "$j" -lt "$limit" ]; do
        [ -d /proc/$pp ] || break
        j=$((j + 1)); sleep 1
    done
    if [ -d /proc/$pp ]; then
        log "!! $name 超过 ${limit}s 未返回 → HUNG, kill -9"
        kill -9 "$pp" 2>/dev/null
        echo "HUNG"
    else
        wait "$pp"; echo "$?"
    fi
}

log "start uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
log "uname: $(uname -a 2>/dev/null)"
log "df /: $(df -h / 2>/dev/null | tail -1)"

# ==================================================== A. 修正版属性面探针（只读）
log "===== A. 属性面探针（补 name/flags 证据）====="
if [ -x /drmpropprobe ]; then
    RC=$(run_bounded_out drmpropprobe 90 /root/prop.log /drmpropprobe)
    log "探针 rc=$RC 输出 $(wc -c < /root/prop.log) 字节"
    grep -aE '^\[CHAIN\] step=5|^\[PROPSUM\]' /root/prop.log | tee -a "$LOG" > /dev/console 2>&1
else
    log "!! /drmpropprobe 未注入（非阻塞）"
fi

# ==================================================== B. 装包
log "===== B. apk 装 Weston 全家桶 ===="
need_install=1
for c in weston seatd weston-simple-shm xterm xclock; do
    if ! command -v "$c" >/dev/null 2>&1; then
        need_install=1
        break
    fi
    need_install=0
done

if [ "$need_install" = "0" ]; then
    log "依赖已齐（镜像已装过），跳过 apk"
else
    log "当前缺失组件："
    for c in weston seatd weston-simple-shm xterm xclock; do
        command -v "$c" >/dev/null 2>&1 || log "  missing: $c"
    done

    # apk update 必须先跑：本轮 disk.img 由 BASE_IMG 拷贝而来，不带上一轮的索引。
    # 它同时充当"网络可用"的自证（before 轮已得 net_ok，这里用于快速失败早发现）
    : > /root/weston-install.log
    log "--- apk update ---"
    RC=$(run_bounded_out apk-update 150 /root/weston-install.log apk update)
    log "apk update rc=$RC"

    log "--- apk add（清单逐字取自官方 xk-weston-start）---"
    RC=$(run_bounded_out apk-add 480 /root/weston-install.log apk add --no-cache \
            weston weston-backend-drm weston-shell-desktop weston-clients \
            weston-xwayland xwayland xterm xclock seatd)
    log "apk add rc=$RC"
    tail -12 /root/weston-install.log >> "$LOG" 2>/dev/null
    tail -12 /root/weston-install.log > /dev/console 2>&1

    log "--- 装后自证（逐个命令 + ldd 缺失检查）---"
    for c in weston seatd weston-simple-shm xterm xclock; do
        P=$(command -v "$c" 2>/dev/null || echo MISSING)
        log "  $c -> $P"
    done
    if [ -x /usr/bin/weston ]; then
        log "--- ldd /usr/bin/weston（只看 not found）---"
        ldd /usr/bin/weston 2>&1 | grep -i 'not found' | tee -a "$LOG" > /dev/console 2>&1 \
            || log "  ldd 无 not found（依赖完整）"
        log "--- weston --version ---"
        weston --version >> "$LOG" 2>&1
        tail -1 "$LOG" > /dev/console 2>&1
    fi
fi

# ==================================================== C. 启动 seatd + weston
log "===== C. 启动 seatd + weston（官方参数形态）===="

mkdir -p "$RD" 2>/dev/null
chmod 700 "$RD" 2>/dev/null
mkdir -p /tmp/.X11-unix 2>/dev/null
chmod 1777 /tmp/.X11-unix 2>/dev/null

# udev 数据：照官方启动器写死 c13:1(鼠标)/c13:2(键盘)；同时把本 guest 实际
# /dev/input 节点号记进日志，便于诊断（x-kernel 的设备号分配可能与 Linux 不同）
mkdir -p /run/udev/data 2>/dev/null
printf 'E:ID_INPUT=1\nE:ID_INPUT_MOUSE=1\nE:ID_SEAT=seat0\n' > /run/udev/data/c13:1 2>/dev/null
printf 'E:ID_INPUT=1\nE:ID_INPUT_KEYBOARD=1\nE:ID_SEAT=seat0\n' > /run/udev/data/c13:2 2>/dev/null
log "/dev/input 实际节点："
ls -l /dev/input/ >> "$LOG" 2>&1
ls /dev/input/ > /dev/console 2>&1

log "RD=$RD 可写测试：$(touch "$RD/.wtest" 2>&1 && echo OK || echo FAIL)"

# weston 需要 libseat：优先 seatd 后端；seatd 起不来则记录（后续轮再换后端）
if ! command -v seatd >/dev/null 2>&1; then
    log "!! seatd 不可用（装包失败？）—— 跳过，直接试 weston"
else
    rm -f /run/seatd.sock
    seatd -g root -l debug > /root/seatd.log 2>&1 &
    log "seatd pid=$!"
    sleep 1
    [ -S /run/seatd.sock ] && log "seatd socket OK" || log "!! seatd socket 未出现"
fi

rm -f "$RD"/wayland-* "$RD"/wayland-*.lock /tmp/.X11-unix/X0 /tmp/.X0-lock 2>/dev/null
rm -f /root/weston.log /root/simple-shm.log

log "--- start weston（--backend=drm-backend.so --renderer=pixman）---"
env XDG_RUNTIME_DIR="$RD" WESTON_DISABLE_ATOMIC=1 weston \
    --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
    --seat=seat0 --continue-without-input --idle-time=0 --xwayland \
    --log=/root/weston.log \
    > /root/weston-stdout.log 2>&1 &
WP=$!
log "weston pid=$WP"

# 等 wayland socket（最多 20s）
i=0
while [ "$i" -lt 100 ]; do
    [ -S "$RD/wayland-0" ] && break
    [ -d /proc/$WP ] || break
    i=$((i + 1))
    sleep 0.2
done

if [ -d /proc/$WP ] && [ -S "$RD/wayland-0" ]; then
    log "WESTON_UP pid=$WP socket=$RD/wayland-0（等待 ${i} × 0.2s）"
    # 起一个纯 Wayland 客户端：screendump 里会是一个明显的移动彩色方块 ——
    # 这是"Weston 不仅活着、而且真的在合成与扫描输出"的最直接证据。
    if command -v weston-simple-shm >/dev/null 2>&1; then
        env XDG_RUNTIME_DIR="$RD" WAYLAND_DISPLAY=wayland-0 \
            weston-simple-shm > /root/simple-shm.log 2>&1 &
        log "weston-simple-shm pid=$!"
    else
        log "weston-simple-shm 不可用（跳过；desktop-shell 背景亦可作为画面证据）"
    fi
else
    log "!! WESTON_FAIL 进程存活=$([ -d /proc/$WP ] && echo yes || echo no) socket=$([ -S "$RD/wayland-0" ] && echo yes || echo no)"
    log "--- weston.log 尾部 ---"
    tail -40 /root/weston.log >> "$LOG" 2>&1
    tail -40 /root/weston.log > /dev/console 2>&1
    log "--- weston-stdout 尾部 ---"
    tail -20 /root/weston-stdout.log >> "$LOG" 2>&1
    tail -20 /root/weston-stdout.log > /dev/console 2>&1
fi

# weston.log 里的关键行（成功/失败都能一眼看出）
log "--- weston.log 关键行 ---"
grep -aE 'Output|CRTC|enabled|disabled|Connector|pixman|libseat|error|Error|failed|Failed|DRM' \
    /root/weston.log 2>/dev/null | tail -40 >> "$LOG"
grep -aE 'Output|enabled|error|failed' /root/weston.log 2>/dev/null | tail -16 > /dev/console 2>&1

# ==================================================== D. 周期记录（供 screendump 时间线）
log "===== D. 周期记录 ===="
n=0
while [ "$n" -lt 16 ]; do
    ALIVE=no
    [ -d /proc/$WP ] && ALIVE=yes
    SOCK=no
    [ -S "$RD/wayland-0" ] && SOCK=yes
    NLINES=$(wc -l < /root/weston.log 2>/dev/null)
    log "+$((n * 30))s weston_alive=$ALIVE socket=$SOCK weston_log_lines=$NLINES"
    sync
    n=$((n + 1))
    sleep 30
done
log "autorun_weston done (weston pid=$WP)"
sync
sync
