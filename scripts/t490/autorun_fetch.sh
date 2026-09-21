#!/bin/sh
# autorun_fetch.sh — guest 侧取证 + 取包安装总控
#
# 背景（本轮新发现，必须先解决）
# ----------------------------
# P0 冻结镜像里"宿主跨架构 apk 预装"那批文件**全是 0 字节空壳**：
#     /usr/share/fonts/noto/NotoSansCJK-Regular.ttc   Size 0 / Blockcount 0
#     /usr/share/fonts/opensans/OpenSans-Regular.ttf  Size 0 / Blockcount 0
#     /usr/lib/chromium/chromium                      Size 0 / Blockcount 0
#     /lib/apk/db/installed                           Size 0 / Blockcount 0
#     /etc/fonts/fonts.conf                           Size 0（→ Fontconfig "line 1: no element found"）
# 对照：/usr/bin/weston 为 67240 字节 / Blockcount 136（真实），所以图形链能跑。
# 结论：字体与 Chromium 在镜像里**没有实体**，必须在 guest 内重新装。
#
# 为什么在 guest 内装而不是继续宿主注入
# ------------------------------------
# apk 会正确处理依赖闭包、符号链接、文件权限、脚本；宿主手工注入这几百个文件
# 极易漏 symlink / 权限。代价是 TCG 下慢，故放在长时长会话里跑。
# 注意：/lib/apk/db/installed 为空 → apk 认为"什么都没装"，会拉完整依赖闭包，
# 因此必须 `--force-overwrite`，否则会因"文件已存在"中止。
#
# 阶段
#   1  evprobe：判定 eventN 的键盘/鼠标归类（决赛键鼠 4 分的前置）
#   2  网络探测（wget/curl 拉 APKINDEX，判 bytes）
#   3  可达 → apk update + apk add fontconfig / 字体 / chromium
#   4  校验：chromium 真身大小、字体大小、fonts.conf 是否合法
#   5  watcher 保活（每 30s 写 /root/fetch-watch.log 并 sync）

LOG=/root/fetch.log
WATCH=/root/fetch-watch.log
: > "$LOG"
: > "$WATCH"

log() {
    echo "[fetch] $*" > /dev/console 2>/dev/null
    echo "$(date 2>/dev/null) $*" >> "$LOG"
}
# 命令输出同时进串口与持久日志（busybox tee 支持多目标）
tl() { "$@" 2>&1 | tee -a "$LOG" /dev/console; }

log "start alpine=$(cat /etc/alpine-release 2>/dev/null)"
log "repos: $(tr '\n' ' ' < /etc/apk/repositories 2>/dev/null)"
log "resolv: $(tr '\n' ' ' < /etc/resolv.conf 2>/dev/null)"
log "ifaces: $(ip -o addr 2>/dev/null | tr '\n' '|')"

# ---------------------------------------------------------------- 1. evprobe
log "===== evprobe: evdev 设备归类 ====="
if [ -x /evprobe ]; then
    tl /evprobe
    log "---- evprobe 汇总行 ----"
    grep -E "^\[EVSUM\]|^\[EVMAP\]" "$LOG" > /dev/console 2>&1
else
    log "evprobe NOT FOUND"
fi
log "输入节点实况: $(ls -l /dev/input/ 2>&1 | tr '\n' '|')"

# ---------------------------------------------------------------- 2. 网络探测
PROBE_URL=https://dl-cdn.alpinelinux.org/alpine/v3.23/main/x86_64/APKINDEX.tar.gz
SZ=""
log "===== 网络探测 ====="
if command -v wget >/dev/null 2>&1; then
    SZ=$(wget -q -O- --timeout=25 "$PROBE_URL" 2>/dev/null | wc -c)
    log "probe via wget: bytes=$SZ"
elif command -v curl >/dev/null 2>&1; then
    SZ=$(curl -sS --max-time 25 "$PROBE_URL" 2>/dev/null | wc -c)
    log "probe via curl: bytes=$SZ"
else
    log "既无 wget 也无 curl —— 无法探测"
fi

if [ -z "$SZ" ] || [ "$SZ" -lt 1000 ] 2>/dev/null; then
    log "NET_VERDICT=UNREACHABLE  (bytes='$SZ') —— 需转宿主侧跨架构预装方案"
else
    log "NET_VERDICT=REACHABLE  (bytes=$SZ) —— 开始 apk 安装"

    # ------------------------------------------------------------ 3. 安装
    log "===== apk update ====="
    tl apk update

    # 说明：db 为空 → 必然拉完整闭包；--force-overwrite 覆盖已存在的空壳文件。
    PKGS="fontconfig font-opensans ttf-dejavu chromium"
    log "===== apk add --force-overwrite $PKGS ====="
    log "（TCG 下依赖求解 + 解包较慢，请耐心；过程实时打到串口）"
    apk add --no-cache --force-overwrite $PKGS 2>&1 | tee -a "$LOG" /dev/console
    log "apk add rc=$?"

    # ------------------------------------------------------------ 4. 校验
    log "===== 安装结果校验 ====="
    for f in /usr/lib/chromium/chromium /usr/bin/chromium /usr/share/fonts/opensans/OpenSans-Regular.ttf \
             /usr/share/fonts/dejavu/DejaVuSans.ttf /etc/fonts/fonts.conf; do
        if [ -e "$f" ]; then
            log "  $(ls -l "$f" 2>&1 | tr -s ' ')"
        else
            log "  MISSING: $f"
        fi
    done
    log "chromium --version: $(chromium --version 2>&1 | head -1)"
    log "fonts.conf 前 3 行: $(head -3 /etc/fonts/fonts.conf 2>&1 | tr '\n' ' ')"
    log "/usr/lib/chromium 体积: $(du -sh /usr/lib/chromium 2>/dev/null | cut -f1)"
fi

# ---------------------------------------------------------------- 5. watcher
log "进入 watcher（每 30s 写 $WATCH 并 sync）"
n=0
while [ "$n" -lt 80 ]; do
    {
        echo "=== $(date 2>/dev/null) uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null) (+$((n * 30))s) ==="
        echo "chromium: $(ls -l /usr/lib/chromium/chromium 2>/dev/null | tr -s ' ')"
        echo "du:       $(du -sh /usr/lib/chromium 2>/dev/null | cut -f1)"
        echo "weston:   $(pgrep -x weston | tr '\n' ' ')"
    } >> "$WATCH" 2>&1
    sync
    n=$((n + 1))
    sleep 30
done
log "watcher 结束（$n 轮）"
sync
sync
log "autorun_fetch done"
