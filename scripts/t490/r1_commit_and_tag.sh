#!/usr/bin/env bash
# ============================================================================
# scripts/t490/r1_commit_and_tag.sh
#   R1 · 把 T490 内核工作区的 P0–P4 兼容补丁提交为分次、可复核的提交，
#        并打上《赛题六》第七节(二)1/3 要求的「首个可运行版本」基线 tag。
#
# 为什么必须有这一步
# ------------------
# 第七节(二)3 原文：「跨层优化的 before/after 数据以队伍首个可运行版本为基线，
# 提交时存档 git tag 与原始数据，**组委会复核存档代码**」。
# 此前 T490 工作区长期 `-dirty`（`git describe` = `p0-drm-version-fix-dirty`），
# 意味着**实测二进制与任何可复核的提交都不对应** —— 性能项最容易被扣分的点。
#
# 用法（在 T490 上执行）：
#   bash ~/xk6/scripts/t490/r1_commit_and_tag.sh [--dry-run]
#
# 退出码：0 成功；1 前置检查失败；2 提交/tag 失败
#
# 设计原则
# --------
# - **只提交已知的 7 个内核文件**，不用 `git add -A`（`images/` 下是 4GB 镜像，
#   一旦误加会把仓库撑爆）。
# - 分 5 次提交（P1 / P2a / P2b / P3 / P4），与 report/09–13 的缺陷编号一一对应，
#   便于后续拆成上游 PR。
# - 提交身份沿用仓库已有的 `xk6 <xk6@local>`（P0 提交 `8162e8a` 用的就是它）。
# - `images/` 写进 `.git/info/exclude`（**仅本地**，不改上游 .gitignore）。
#
# ★ 血泪教训（本脚本第一版就在此翻车）
# ------------------------------------
# 仓库装了 `core.hooksPath=.githooks` 的 pre-commit 钩子，它会跑
# `make fmt`（依赖 pinned nightly `nightly-2026-03-08`）与 `make clippy`。
# 第一版脚本**没有检查 `git commit` 的返回值**，结果 5 次提交全部被钩子拒绝，
# 脚本却继续往下执行，把 tag 打到了错误的提交上（`!810 refactor(timer)`）。
# 现在：每次提交失败立即 `die`，且**打 tag 前断言恰好新增 5 个提交 + 工作区干净**。
# 逃生开关（钩子自带）：`SKIP_FMT=1` / `SKIP_CLIPPY=1` / `SKIP_ALL=1`。
# ============================================================================
set -u

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

REPO="${XKERNEL_DIR:-$HOME/x-kernel}"
cd "$REPO" 2>/dev/null || { echo "FATAL: 仓库不存在: $REPO"; exit 1; }

TAG_FIRST_RUNNABLE="v0.1-first-runnable"
TAG_COMPAT_COMPLETE="v0.2-compat-p0p4"

die() { echo "!! FATAL: $*" >&2; exit 2; }

echo "=============================================================================="
echo " R1 · 内核补丁提交 + 基线 tag"
echo " 仓库: $REPO"
echo " 模式: $([ "$DRY_RUN" = 1 ] && echo 'DRY-RUN（不做任何改动）' || echo '正式执行')"
echo " 时间: $(date -Is)"
echo "=============================================================================="

# ---------------------------------------------------------------- 0. 前置检查
echo
echo "── 0. 前置检查 ──"

HEAD_BEFORE="$(git rev-parse HEAD)"
echo "HEAD     = $HEAD_BEFORE"
echo "describe = $(git describe --tags --always --dirty 2>/dev/null)"

# 期望恰好这 7 个文件被修改（P1/P2a/P2b/P3/P4 的落点）
EXPECTED="$(printf '%s\n' \
    core/ksyscall/src/task/ctl.rs \
    core/ksyscall/src/task/sched.rs \
    mm/memspace/src/aspace.rs \
    net/knet/src/netlink/socket.rs \
    net/knet/src/unix/stream.rs \
    net/knet/src/unix/stream/channel.rs \
    posix/mm/src/mmap.rs | sort)"
ACTUAL="$( { git diff --name-only; git diff --cached --name-only; } | sort -u)"

if [ "$EXPECTED" != "$ACTUAL" ]; then
    echo "!! 工作区改动与预期不符，拒绝自动提交（避免把无关改动卷进补丁提交）："
    echo "--- 预期 ---"; printf '%s\n' "$EXPECTED"
    echo "--- 实际 ---"; printf '%s\n' "$ACTUAL"
    exit 1
fi
echo "OK：工作区恰好是 P1–P4 的 7 个落点文件"
git diff HEAD --stat | tail -1

# ★ 暂存区必须为空：若上一次失败的运行已 `git add` 过，这些文件会被卷进
#   第一个提交（P1），破坏「一次提交=一个缺陷」的边界。
STAGED_N="$(git diff --cached --name-only | wc -l)"
if [ "$STAGED_N" != "0" ]; then
    echo "!! 暂存区已有 $STAGED_N 个文件，拒绝继续（否则会串进 P1 提交）。"
    echo "   先清空暂存区（不动工作区）：  git reset"
    echo "   当前已暂存："; git diff --cached --name-only | sed 's/^/     /'
    exit 1
fi
echo "OK：暂存区为空"

# 钩子依赖：fmt 需要 pinned nightly
if [ "$DRY_RUN" = 0 ]; then
    if ! cargo +nightly-2026-03-08 fmt --version >/dev/null 2>&1; then
        echo "!! 缺少 pinned nightly（make fmt 需要）："
        echo "     rustup toolchain install nightly-2026-03-08 --profile minimal --component rustfmt"
        echo "   或本次用 SKIP_FMT=1 绕过。"
        [ "${SKIP_FMT:-0}" = "1" ] || exit 1
    fi
    echo "fmt 工具链: $(cargo +nightly-2026-03-08 fmt --version 2>/dev/null || echo '缺失(SKIP_FMT)')"
    echo "钩子路径  : $(git config core.hooksPath || echo '(默认 .git/hooks)')"
    [ -f .config ] || echo "!! 注意: 无 .config → 钩子会跳过 clippy"
fi

# ---------------------------------------------------------------- 1. 身份与排除
echo
echo "── 1. 提交身份 + 本地排除 ──"
if [ "$DRY_RUN" = 0 ]; then
    git config user.name  "xk6"          # 沿用 P0 提交（8162e8a）的作者身份
    git config user.email "xk6@local"
    if ! grep -qx '/images/' .git/info/exclude 2>/dev/null; then
        printf '\n# R1: 本地磁盘镜像（4GB），不入库\n/images/\n' >> .git/info/exclude
    fi
fi
echo "user.name  = $(git config user.name)"
echo "user.email = $(git config user.email)"

# ---------------------------------------------------------------- 2. 分次提交
echo
echo "── 2. 分 5 次提交（P1 / P2a / P2b / P3 / P4）──"

# commit_one <subject> <body> -- <file...>
commit_one() {
    local subject="$1"; shift
    local body="$1"; shift
    [ "${1:-}" = "--" ] && shift

    if [ "$DRY_RUN" = 1 ]; then
        echo "  [dry-run] add  $*"
        echo "  [dry-run] commit \"$subject\""
        return 0
    fi
    git add -- "$@" || return 1
    # ★ 钩子可能拒绝提交；这里必须让错误向上传播（第一版就是漏了这点）
    git commit -F - <<EOF || return 1
$subject

$body
EOF
    printf '  -> %s\n' "$(git log --oneline -1)"
}

commit_one \
"fix(knet): deliver AF_UNIX SOCK_STREAM ancillary data" \
"SOCK_STREAM sockets silently dropped ancillary data, so SCM_RIGHTS file
descriptors were never transferred. Wayland clients never received the
compositor's shared-memory buffer fds and the graphical session could not
start at all.

Queue one ancillary payload per sendmsg on the channel and publish it with the
first successful read of the matching message, mirroring the datagram path.

Verified by fdprobe (SCM_RIGHTS across processes) and by the Weston session
rendering its desktop." \
    -- net/knet/src/unix/stream.rs net/knet/src/unix/stream/channel.rs \
    || die "P1 提交失败（见上方钩子输出）"

commit_one \
"fix(ksyscall): resolve sched target by tid as well as tgid" \
"sched_getparam/sched_setparam/sched_getscheduler looked the target up by tgid
only. musl's pthread_getschedparam forwards the *target thread's* kernel tid, so
the lookup failed with ESRCH for every non-leader thread -- and Chromium queries
the scheduling parameters of its own worker threads during startup.

Try the tid first and fall back to the process-leader lookup." \
    -- core/ksyscall/src/task/sched.rs \
    || die "P2a 提交失败"

commit_one \
"fix(knet): accept non-zero multicast groups in netlink bind" \
"NETLINK_ROUTE bind() with a non-zero groups mask returned EOPNOTSUPP, so
Chromium's AddressTrackerLinux could not subscribe to route notifications and
aborted early in network initialization.

Binding RTMGRP_* groups is now accepted. Notifications themselves are not
delivered yet -- with static networking that is currently a no-op -- which is
tracked as a TODO in the socket." \
    -- net/knet/src/netlink/socket.rs \
    || die "P2b 提交失败"

commit_one \
"feat(ksyscall): implement PR_SET_NO_NEW_PRIVS" \
"prctl(PR_SET_NO_NEW_PRIVS) unconditionally returned ENOSYS, so every Chromium
child process died between fork and exec: base/process/launch_posix.cc probes
the option and treats a failure as fatal. The kernel-side latch already existed
(process/kprocess/src/thread/core.rs) -- it was simply not reachable through the
syscall.

Also make the flag readable back through PR_GET_NO_NEW_PRIVS." \
    -- core/ksyscall/src/task/ctl.rs \
    || die "P3 提交失败"

commit_one \
"fix(mm): stop rejecting well-formed madvise calls" \
"Two errnos that Linux never produces for a valid call:

- only MADV_DONTNEED was accepted, so MADV_NORMAL/RANDOM/SEQUENTIAL/WILLNEED/
  FREE returned EINVAL. PartitionAlloc and V8 issue these routinely.
- MADV_DONTNEED required the range to be fully covered by VMAs and returned
  ENOMEM on any hole. Linux applies the advice to whatever is mapped and
  silently ignores unmapped gaps." \
    -- posix/mm/src/mmap.rs mm/memspace/src/aspace.rs \
    || die "P4 提交失败"

# ---------------------------------------------------------------- 3. 提交后硬断言
echo
echo "── 3. 提交后硬断言（打 tag 的前置条件）──"
if [ "$DRY_RUN" = 0 ]; then
    N_NEW="$(git rev-list --count "$HEAD_BEFORE..HEAD")"
    echo "新增提交数 = $N_NEW （期望 5）"
    [ "$N_NEW" = "5" ] || die "新增提交数不是 5（提交可能被钩子拒绝），拒绝打 tag"

    if [ -n "$(git status --porcelain)" ]; then
        git status --short | sed 's/^/  /'
        die "工作区仍有改动，拒绝打 tag"
    fi
    echo "工作区 CLEAN ✓"
fi

# ---------------------------------------------------------------- 4. 打基线 tag
echo
echo "── 4. 打基线 tag（第七节(二)1/3）──"

if [ "$DRY_RUN" = 1 ]; then
    echo "  [dry-run] $TAG_FIRST_RUNNABLE -> P3 提交（HEAD~1）"
    echo "  [dry-run] $TAG_COMPAT_COMPLETE -> HEAD"
else
    P3_SHA="$(git rev-parse HEAD~1)"     # HEAD = P4，HEAD~1 = P3
    P4_SHA="$(git rev-parse HEAD)"

    HOST_FP="$(printf '%s\n' \
        "  CPU   $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')" \
        "  规模  $(nproc) 逻辑核 / $(awk '/^MemTotal/{printf "%.1f GiB", $2/1048576}' /proc/meminfo) 内存" \
        "  OS    $(sed -n 's/^PRETTY_NAME=\"\(.*\)\"/\1/p' /etc/os-release) / $(uname -sr) $(uname -m)" \
        "  QEMU  $(qemu-system-aarch64 --version 2>/dev/null | head -1)")"

    git tag -a "$TAG_COMPAT_COMPLETE" -F - <<EOF || die "打 tag $TAG_COMPAT_COMPLETE 失败"
赛题六 · 兼容补丁齐全（P0–P4）

在 $TAG_FIRST_RUNNABLE 之上追加 P4：madvise 放宽 advice 白名单，并容忍
MADV_DONTNEED 区间内的未映射空洞（对齐 Linux 语义）。

此版本**只含兼容性修复，尚未做任何性能优化**。若以「兼容补丁齐全」作为
before 基线，请用本 tag 而非 $TAG_FIRST_RUNNABLE。

主机指纹（第七节(二)4 要求随数据一起提交）：
$HOST_FP
EOF

    git tag -a "$TAG_FIRST_RUNNABLE" "$P3_SHA" -F - <<EOF || die "打 tag $TAG_FIRST_RUNNABLE 失败"
赛题六 · before 基线 —— 队伍首个可运行版本

状态：Weston（DRM backend + pixman 软渲染）图形会话可建立，Chromium 可创建
窗口并显示本地 HTML 页面，QEMU monitor screendump 取证成功。

依据：《赛题六》第七节(二)1/3 —— 性能改善与跨层优化的 before/after 数据以
「参赛队伍首个可运行版本（git tag 存档）」为基线，组委会复核存档代码。

自上游 main 起累积的兼容补丁（详见 report/09–13）：
  P0  fix(drm)       DRM_IOCTL_VERSION / DRM_UNIQUE 容忍 NULL 指针
  P1  fix(knet)      AF_UNIX SOCK_STREAM 传递 ancillary 数据（SCM_RIGHTS）
  P2a fix(ksyscall)  sched 目标按 tid 解析，不再只认 tgid
  P2b fix(knet)      netlink bind 接受非零 multicast groups
  P3  feat(ksyscall) prctl(PR_SET_NO_NEW_PRIVS) 实现
（紧随其后的 $TAG_COMPAT_COMPLETE 追加 P4：madvise 白名单与空洞容忍）

主机指纹（第七节(二)4 要求随数据一起提交）：
$HOST_FP

平台合规：scripts/t490/t490_platform_check.sh → PASS=35 FAIL=0，产物见
evidence/2026-09-21_t490-platverify/（report/15）。
EOF

    # 硬断言：tag 落点必须正确
    A="$(git rev-list -n1 "$TAG_FIRST_RUNNABLE")"
    B="$(git rev-list -n1 "$TAG_COMPAT_COMPLETE")"
    [ "$A" = "$P3_SHA" ] || die "$TAG_FIRST_RUNNABLE 落点错误: $A != $P3_SHA"
    [ "$B" = "$P4_SHA" ] || die "$TAG_COMPAT_COMPLETE 落点错误: $B != $P4_SHA"
    printf '  %-22s -> %s  %s\n' "$TAG_FIRST_RUNNABLE" "${A:0:9}" "$(git log -1 --format=%s "$A")"
    printf '  %-22s -> %s  %s\n' "$TAG_COMPAT_COMPLETE" "${B:0:9}" "$(git log -1 --format=%s "$B")"
fi

# ---------------------------------------------------------------- 5. 验收
echo
echo "── 5. 验收 ──"
if [ "$DRY_RUN" = 0 ]; then
    echo "git status --short:"
    S="$(git status --porcelain)"
    if [ -z "$S" ]; then echo "  (空) → 工作区 CLEAN ✓"; else printf '%s\n' "$S" | sed 's/^/  /'; fi
    echo
    echo "describe = $(git describe --tags --always --dirty)"
    echo "tags     = $(git tag | tr '\n' ' ')"
    echo
    echo "提交序列（本次新增）："
    git log --oneline "$HEAD_BEFORE..HEAD" --reverse | sed 's/^/  /'
    echo
    echo "各提交改动文件："
    for c in $(git rev-list --reverse "$HEAD_BEFORE..HEAD"); do
        printf '  %s  %s\n' "$(git log -1 --format=%h "$c")" "$(git log -1 --format=%s "$c")"
        git show --stat --format="" "$c" | grep '|' | sed 's/^/        /'
    done
fi
echo
echo "=============================================================================="
echo " R1 完成。before 基线 tag：$TAG_FIRST_RUNNABLE / $TAG_COMPAT_COMPLETE"
echo " 注意：若 pre-commit 的 make fmt 改写了源码，请重新 make build 后再采数。"
echo "=============================================================================="
