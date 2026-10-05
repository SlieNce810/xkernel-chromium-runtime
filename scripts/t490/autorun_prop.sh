#!/bin/sh
# autorun_prop.sh —— 属性面 uapi 探针轮（缺口 A 的 errno 级复现 + guest 网络体检）
#
# 本脚本在 guest 内以 root 运行（由 /etc/profile.d/99-autostart.sh 拉起 /root/autorun.sh）。
# 它做两件互不干扰的事，一次开机同时取两类事实：
#
#   ① 主指标：/drmpropprobe 的属性面编号对照（mainline 0xA8/0xAA vs xk 现用 0xAA/0xAC）
#      + /drmdumbprobe 的 bpp 回归（确认本轮没有把既有结论碰坏）
#   ② 附带：guest 网络体检 —— 决定「补 Weston」走哪条路：
#        - 若 apk/wget 可达 → 可直接 `apk add weston seatd …`（官方 xk-weston-start 的路子）
#        - 若不可达 → 改为宿主侧下载 apk 包、注入镜像离线安装
#      这不是"顺手加的功能"：Weston 装入路径是基础任务 40 分的必经环节，
#      而它到底能不能联网，此前从未在 agentos 镜像 + x-kernel 上实测过。
#
# 输出约定（宿主侧 grep / debugfs 回收）：
#   /root/prop.log        全量日志（round_assert.sh 回收清单里的额外文件）
#   [PROP]/[CHAIN]/[PROPSUM]  探针判定行（同时打到串口，进 console.log）
#   [NET]/[NETSUM]        网络体检判定行
#
# 注意：本文件会被 t490_round.sh 做过「双下划线包裹的占位符」替换与残留硬校验
#       （正则匹配形如 双下划线+标识符+双下划线 的字面量），
#       所以正文里**不得**出现该形式的字符串 —— 注释里也不行。

LOG=/root/prop.log
: > "$LOG"

log() {
    echo "[prop] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}

# 有界后台执行：探针卡住时不能跟着永远等
run_bounded() {
    name="$1"; shift
    out="$1"; shift
    "$@" > "$out" 2>&1 &
    pp=$!
    j=0
    while [ "$j" -lt 60 ]; do
        [ -d /proc/$pp ] || break
        j=$((j + 1)); sleep 1
    done
    if [ -d /proc/$pp ]; then
        log "!! $name 超过 ${j}s 未返回 → HUNG, kill -9"
        kill -9 "$pp" 2>/dev/null
        sleep 1
        echo "HUNG" > /tmp/rc_$name
    else
        wait "$pp"; echo "$?" > /tmp/rc_$name
    fi
    log "$name 结果=$(cat /tmp/rc_$name 2>/dev/null) 输出=$(wc -c < "$out" 2>/dev/null) 字节（等待 ${j}s）"
}

log "start uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
log "uname: $(uname -a 2>/dev/null)"

# ============================================================ ① 主指标：探针
log "===== 探针 A: /drmpropprobe（属性面编号对照）====="
if [ -x /drmpropprobe ]; then
    run_bounded drmpropprobe /root/prop-drmpropprobe.out /drmpropprobe
    cat /root/prop-drmpropprobe.out >> "$LOG"
    cat /root/prop-drmpropprobe.out > /dev/console 2>&1
    log "----- 判定行 -----"
    grep -aE '^\[PROP\]|^\[CHAIN\]|^\[PROPSUM\]|^\[SELF\]' /root/prop-drmpropprobe.out \
        | tail -60 > /dev/console 2>&1
else
    log "!! /drmpropprobe 未注入 —— 本轮主指标缺失（检查 t490_round.sh 的 probe 参数）"
fi

log "===== 探针 B: /drmdumbprobe（bpp 回归，确认既有结论未变）====="
if [ -x /drmdumbprobe ]; then
    run_bounded drmdumbprobe /root/prop-drmdumbprobe.out /drmdumbprobe
    cat /root/prop-drmdumbprobe.out >> "$LOG"
    grep -aE 'CREATE_DUMB|对照|!!' /root/prop-drmdumbprobe.out | tail -20 > /dev/console 2>&1
else
    log "!! /drmdumbprobe 未注入（非阻塞，仅提示）"
fi

# ============================================================ ② 附带：网络体检
log "===== 网络体检（决定 Weston 装入路径）====="
NETSUM="net_unknown"

{
    echo "--- 接口 ---"
    ifconfig -a 2>&1 | head -30
    echo "--- 路由 ---"
    (ip route 2>/dev/null || route -n 2>/dev/null) | head -10
    echo "--- DNS ---"
    cat /etc/resolv.conf 2>&1 | head -5
    echo "--- apk 源 ---"
    cat /etc/apk/repositories 2>&1 | head -5
    echo "--- 网关 ping (10.0.2.2) ---"
    ping -c 2 -W 3 10.0.2.2 2>&1 | tail -4
    echo "--- DNS 解析 (dl-cdn / tuna) ---"
    (nslookup mirrors.tuna.tsinghua.edu.cn 2>&1 || nslookup dl-cdn.alpinelinux.org 2>&1) | head -8
    echo "--- HTTP 探测（tuna mirror 根）---"
    timeout 20 wget -q -O /dev/null http://mirrors.tuna.tsinghua.edu.cn/alpine/v3.22/main/ 2>&1
    echo "wget_main_rc=$?"
    timeout 30 wget -q -O /dev/null http://mirrors.tuna.tsinghua.edu.cn/alpine/v3.22/community/ 2>&1
    echo "wget_community_rc=$?"
    echo "--- apk update（120s 上限）---"
    timeout 120 apk update 2>&1 | tail -8
    echo "apk_update_rc=$?"
    echo "--- 关键包能否解析（不安装，只看索引）---"
    apk search -x weston 2>&1 | head -8
    echo "apk_search_rc=$?"
} > /root/net.log 2>&1

# 判定：wget 两个 rc 都是 0 → 联网可用
W1=$(grep -a '^wget_main_rc=' /root/net.log | tail -1 | cut -d= -f2)
W2=$(grep -a '^wget_community_rc=' /root/net.log | tail -1 | cut -d= -f2)
AU=$(grep -a '^apk_update_rc=' /root/net.log | tail -1 | cut -d= -f2)
WESTON_PKG=$(grep -ac '^weston' /root/net.log 2>/dev/null)

if [ "$W1" = "0" ] && [ "$W2" = "0" ] && [ "$AU" = "0" ]; then
    NETSUM="net_ok(apk_update_rc=0, weston_candidates=$WESTON_PKG)"
elif [ "$W1" = "0" ] || [ "$W2" = "0" ]; then
    NETSUM="net_partial(wget:main=$W1,community=$W2,apk_update=$AU)"
else
    NETSUM="net_down(wget:main=$W1,community=$W2,apk_update=$AU)"
fi
echo "[NETSUM] $NETSUM" >> "$LOG"
echo "[NETSUM] $NETSUM" > /dev/console 2>&1
cat /root/net.log >> "$LOG"
grep -aE '^\[NETSUM\]|inet |^default |nameserver|^wget_|^apk_|^weston' /root/net.log \
    | head -24 > /dev/console 2>&1

# ============================================================ ③ 汇总
log "===== 汇总（判定行）====="
grep -aE '^\[PROPSUM\]|^\[NETSUM\]|CREATE_DUMB.*bpp' "$LOG" | tail -20 > /dev/console 2>&1

# 保持会话存活，供宿主侧周期 screendump 与本轮取证收尾
n=0
while [ "$n" -lt 7 ]; do
    { echo "=== $(date 2>/dev/null) (+$((n * 30))s) prop 轮 ==="; } >> /root/prop-watch.log 2>&1
    sync
    n=$((n + 1))
    sleep 30
done
log "autorun_prop done"
sync
sync
