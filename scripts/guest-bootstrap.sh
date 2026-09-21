#!/bin/sh
# guest-bootstrap.sh — 在 x-kernel guest 内准备图形与浏览器环境
#
# 【重要】本脚本在 **guest 内部** 运行（通过 QEMU 串口 shell），不是在 Linux 主机上。
#
# 为什么需要它
# ------------
# 官方 `uapps/weston-start/xk-weston-start` 会执行
#     apk add weston weston-backend-drm weston-shell-desktop weston-clients \
#             weston-xwayland xwayland xterm xclock seatd
# 但 Alpine aarch64 的 **weston 与 chromium 都位于 community 仓库、不在 main**。
# 默认 rootfs 通常只启用 main，导致 apk 报
#     ERROR: unable to select packages: weston (no such package)
# 脚本随即 exit 1，图形环境起不来 → 基础任务 40 分全丢。
# 本脚本先补齐 community 源，再装包，把这条路由打通。
#
# 用法（guest 内）
#     sh /usr/share/guest-bootstrap.sh              # 只装 Weston 全家桶
#     sh /usr/share/guest-bootstrap.sh --with-chromium
#     sh /usr/share/guest-bootstrap.sh --check-only  # 只体检不改动
#
# 依赖：Alpine 系 rootfs（有 apk）；需要 guest 网络可达（virtio-net + user net,
#       DNS 默认 10.0.2.3）

set -u

WITH_CHROMIUM=0
CHECK_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --with-chromium) WITH_CHROMIUM=1 ;;
        --check-only)    CHECK_ONLY=1 ;;
        -h|--help)       sed -n '2,26p' "$0" 2>/dev/null; exit 0 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

MIRROR="https://dl-cdn.alpinelinux.org/alpine"
FAIL=0

say()  { printf '%s\n' "$*"; }
ok()   { printf '  [ OK ] %s\n' "$*"; }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }
warn() { printf '  [WARN] %s\n' "$*"; }

say "=============================================================="
say " 赛题六 · guest 图形环境 bootstrap"
say " 时间: $(date -Is 2>/dev/null || date)"
say "=============================================================="

# ---------------------------------------------------------------- 0. 体检
say ""
say "── 0. 当前状态 ────────────────────────────────────────────────"
say "  uname        : $(uname -a 2>/dev/null)"
say "  uptime       : $(cat /proc/uptime 2>/dev/null)"
if [ -r /etc/alpine-release ]; then
    ALP_VER="$(cat /etc/alpine-release)"
    say "  alpine       : $ALP_VER"
else
    ALP_VER=""
    say "  alpine       : 未检测到 /etc/alpine-release"
fi
for d in /dev/dri/card0 /dev/input; do
    if [ -e "$d" ]; then ok "$d 存在"; else bad "$d 不存在（图形/输入设备未就绪）"; fi
done
if command -v weston >/dev/null 2>&1; then
    say "  weston       : $(command -v weston)"
else
    say "  weston       : 未安装"
fi
if command -v chromium >/dev/null 2>&1; then
    say "  chromium     : $(command -v chromium)"
else
    say "  chromium     : 未安装"
fi
if command -v df >/dev/null 2>&1; then
    say "  df /         : $(df -h / 2>/dev/null | awk 'NR==2{print $2" 总 / "$4" 可用"}')"
fi
if [ -r /etc/resolv.conf ]; then
    say "  resolv.conf  : $(tr '\n' ' ' < /etc/resolv.conf)"
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    say ""
    say "(--check-only 模式，未做任何改动)"
    exit $(( FAIL > 0 ? 1 : 0 ))
fi

if [ -z "$ALP_VER" ]; then
    say ""
    say "❌ 这不是 Alpine 系 rootfs，本脚本的 apk 逻辑不适用。"
    say "   请改用 alpine-busybox 变体，或为 Debian 系自行编写 apt 逻辑。"
    exit 1
fi

# ---------------------------------------------------------------- 1. 网络
say ""
say "── 1. 网络连通性 ──────────────────────────────────────────────"
REACH=0
if command -v wget >/dev/null 2>&1 && wget -q -O /dev/null --timeout=12 "$MIRROR/" 2>/dev/null; then
    REACH=1
elif command -v nc >/dev/null 2>&1 && nc -z -w 8 dl-cdn.alpinelinux.org 443 2>/dev/null; then
    REACH=1
fi
if [ "$REACH" -eq 1 ]; then
    ok "可以访问 $MIRROR"
else
    warn "无法直接探测 $MIRROR；继续尝试 apk（若失败先修网络）"
    warn "  排查: ping 10.0.2.2 / 检查 /etc/resolv.conf 是否有 nameserver 10.0.2.3"
fi

# ---------------------------------------------------------------- 2. 仓库
say ""
say "── 2. 启用 community 仓库（关键修复）──────────────────────────"
VER="$(printf '%s' "$ALP_VER" | cut -d. -f1,2)"
say "  目标版本分支: v$VER"

if [ ! -f /etc/apk/repositories ]; then
    say "  /etc/apk/repositories 不存在，创建之"
    : > /etc/apk/repositories
fi
say "  修改前:"
sed 's/^/    /' /etc/apk/repositories

for repo in main community; do
    line="$MIRROR/v$VER/$repo"
    if grep -qF "$line" /etc/apk/repositories 2>/dev/null; then
        ok "$repo 已启用"
    else
        printf '%s\n' "$line" >> /etc/apk/repositories
        ok "$repo 已追加: $line"
    fi
done

say "  修改后:"
sed 's/^/    /' /etc/apk/repositories

say "  执行 apk update ..."
if apk update 2>&1 | sed 's/^/    /'; then
    ok "apk update 完成"
else
    bad "apk update 失败 —— 先修网络/DNS"
fi

say "  探测包可见性:"
for pkg in weston chromium; do
    if apk search -x "$pkg" 2>/dev/null | grep -q .; then
        ok "$pkg 可见: $(apk search -x "$pkg" 2>/dev/null | head -n1)"
    else
        bad "$pkg 仍不可见 —— community 源未生效或该分支无此包"
    fi
done

# ---------------------------------------------------------------- 3. 空间
say ""
say "── 3. 磁盘空间检查 ────────────────────────────────────────────"
if command -v df >/dev/null 2>&1; then
    AVAIL_KB="$(df -k / 2>/dev/null | awk 'NR==2{print $4}')"
    say "  可用空间: $(( ${AVAIL_KB:-0} / 1024 )) MiB"
    NEED=250
    [ "$WITH_CHROMIUM" -eq 1 ] && NEED=900
    if [ "${AVAIL_KB:-0}" -lt $(( NEED * 1024 )) ]; then
        bad "空间可能不足（粗略需要 ${NEED} MiB 以上）"
        say "      修复: 在 Linux 主机上对 disk.img 扩容："
        say "        truncate -s 4G disk.img && e2fsck -f -y disk.img && resize2fs disk.img"
        say "      注意：扩容必须在 QEMU 关闭状态下进行。"
    else
        ok "空间看起来够用"
    fi
fi

# ---------------------------------------------------------------- 4. 装 Weston
say ""
say "── 4. 安装 Weston 全家桶 ──────────────────────────────────────"
if apk add --no-cache weston weston-backend-drm weston-shell-desktop \
        weston-clients weston-xwayland xwayland xterm xclock seatd 2>&1 | sed 's/^/    /'; then
    ok "Weston 全家桶安装完成"
else
    warn "完整包集安装失败，降级只装 weston + seatd"
    if apk add --no-cache weston seatd 2>&1 | sed 's/^/    /'; then
        ok "降级安装完成（Xwayland/X11 客户端可能不可用）"
    else
        bad "Weston 安装失败"
    fi
fi

# ---------------------------------------------------------------- 5. 装 Chromium
if [ "$WITH_CHROMIUM" -eq 1 ]; then
    say ""
    say "── 5. 安装 Chromium（约 101 MiB 包，TCG 下很慢，请耐心）──────"
    if apk add --no-cache chromium chromium-swiftshader 2>&1 | sed 's/^/    /'; then
        ok "Chromium 安装完成: $(chromium --version 2>/dev/null || echo '版本未知')"
    else
        bad "Chromium 安装失败"
    fi
else
    say ""
    say "── 5. 跳过 Chromium（加 --with-chromium 可安装）──────────────"
fi

# ---------------------------------------------------------------- 6. 自检
say ""
say "── 6. 安装结果自检 ────────────────────────────────────────────"
for c in weston seatd weston-simple-shm xterm xclock Xwayland chromium; do
    p="$(command -v "$c" 2>/dev/null || true)"
    if [ -n "$p" ]; then
        ok "$(printf '%-18s %s' "$c" "$p")"
    else
        if [ "$c" = "chromium" ]; then
            warn "$(printf '%-18s %s' "$c" "未安装（非本次目标）")"
        else
            bad "$(printf '%-18s %s' "$c" "MISSING")"
        fi
    fi
done

say ""
say "── 7. 目录与权限预置（xk-weston-start 会做的事）───────────────"
mkdir -p /run/user/0 && chmod 700 /run/user/0 && ok "/run/user/0 (700)"
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix && ok "/tmp/.X11-unix (1777)"
mkdir -p /run/udev/data && ok "/run/udev/data"
# 伪造 evdev 设备的 udev 属性，骗过 libinput（绕开无 udev/uevent/sysfs 的局限）
cat >/run/udev/data/c13:1 <<'EOF'
E:ID_INPUT=1
E:ID_INPUT_MOUSE=1
E:ID_SEAT=seat0
EOF
cat >/run/udev/data/c13:2 <<'EOF'
E:ID_INPUT=1
E:ID_INPUT_KEYBOARD=1
E:ID_SEAT=seat0
EOF
ok "已写入 /run/udev/data/c13:{1,2}"

# ---------------------------------------------------------------- 8. 试跑
say ""
say "── 8. 手工试跑 Weston（只起 compositor，不起 X11 客户端）──────"
if command -v weston >/dev/null 2>&1; then
    say "  执行: XK_WESTON_CLIENT=none /usr/local/bin/xk-weston-start"
    if command -v xk-weston-start >/dev/null 2>&1 || [ -x /usr/local/bin/xk-weston-start ]; then
        XK_WESTON_CLIENT=none /usr/local/bin/xk-weston-start || \
            warn "xk-weston-start 返回非 0（详见 /tmp/weston.log）"
    else
        say "  未安装 xk-weston-start，直接手工起 weston:"
        mkdir -p /run/user/0
        env XDG_RUNTIME_DIR=/run/user/0 WESTON_DISABLE_ATOMIC=1 weston \
            --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
            --seat=seat0 --continue-without-input --idle-time=0 \
            --log=/tmp/weston.log &
        sleep 5
    fi
    say ""
    say "  ---- /tmp/weston.log (尾部 30 行) ----"
    tail -n 30 /tmp/weston.log 2>/dev/null | sed 's/^/    /' || say "    (无日志)"
    say ""
    say "  ---- wayland sockets ----"
    ls -l /run/user/0/ 2>/dev/null | sed 's/^/    /' || true
    say ""
    say "  ---- weston 进程 ----"
    ps 2>/dev/null | grep -E 'weston|seatd' | grep -v grep | sed 's/^/    /' || true
fi

# ---------------------------------------------------------------- 结论
say ""
say "=============================================================="
if [ "$FAIL" -eq 0 ]; then
    say " ✅ 完成。下一步："
    say "    1) 回 Linux 主机执行 screendump 截图 → 图形会话启动证据(10分)"
    say "    2) 让 Weston 连续跑 >=10 分钟 → 稳定性证据(10分)"
    say "       素材: guest 内 /tmp/weston-watch.log (该脚本每 30s 写一次 ps 快照)"
    say "    3) 关闭 QEMU 后在主机上冻结镜像:"
    say "       cp disk.img images/dev-baseline-weston.img"
    say "       sha256sum images/dev-baseline-weston.img"
else
    say " ❌ 有 $FAIL 项失败，按上面 [FAIL] 行修复后重跑。"
fi
say "=============================================================="
exit $(( FAIL > 0 ? 1 : 0 ))
