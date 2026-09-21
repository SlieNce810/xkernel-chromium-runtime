#!/usr/bin/env bash
# ============================================================================
# scripts/t490/t490_platform_check.sh
#   赛题六 第七节「统一评测平台与测量规范」的**合规预检**
#
# 把 PDF 第七节的每一条要求变成一条可执行断言，逐条打 [PASS]/[FAIL]/[WARN]，
# 最后给出总判定。产物可归档为证据目录里的 platform-compliance.txt。
#
# 用法：
#   bash scripts/t490/t490_platform_check.sh                 # 打印到 stdout
#   bash scripts/t490/t490_platform_check.sh /path/check.txt # 同时落盘
#   XKERNEL_DIR=~/x-kernel bash .../t490_platform_check.sh
#
# 退出码：0 = 全部必需项 PASS；1 = 有 FAIL
#
# 设计原则：只读。唯一的"副作用"是
#   (a) 在 mktemp 目录里重展开一次基线配置（隔离，不影响仓库）
#   (b) 在 $XKERNEL_DIR 执行 `make justrun XKMAKE_ARGS=--dry-run`
#       —— xkmake 的 dry-run 只打印命令行、**不启动 QEMU**
# ============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=platform.env
. "$HERE/platform.env"

OUT="${1:-}"
XKERNEL_DIR="${XKERNEL_DIR:-$HOME/x-kernel}"
export PATH="${QEMU_ROOT:-$HOME/qemu-root/usr/bin}:$HOME/.cargo/bin:$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"

BUF="$(mktemp)"
PASS_N=0
FAIL_N=0
WARN_N=0

say()  { printf '%s\n' "$*"; }
hdr()  { say ""; say "── $* ──"; }
ok()   { PASS_N=$((PASS_N + 1)); printf '[PASS] %s\n' "$*"; }
bad()  { FAIL_N=$((FAIL_N + 1)); printf '[FAIL] %s\n' "$*"; }
warn() { WARN_N=$((WARN_N + 1)); printf '[WARN] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }

# assert <描述> <命令...>      —— 命令成功即 PASS
assert()     { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
# assert_not <描述> <命令...>  —— 命令失败即 PASS（用于"必须不出现"）
assert_not() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi; }

# 从 "qemu-system-aarch64 \" 开始，抓取整段续行命令，并去掉行尾反斜杠（保留缩进）
extract_qcmd() {
    awk '
        /^qemu-system-aarch64/ { f = 1 }
        f {
            cont = ($0 ~ /\\[[:space:]]*$/)
            sub(/[[:space:]]*\\[[:space:]]*$/, "")
            print
            if (!cont) exit
        }
    ' "$1"
}

check_main() {

say "=============================================================================="
say " 赛题六 · 第七节 统一评测平台 —— 合规预检"
say " 时间   : $(date -Is 2>/dev/null || date)"
say " 仓库   : $XKERNEL_DIR"
say " 断言集 : $HERE/platform.env"
say "=============================================================================="

# --------------------------------------------------------------- 七(一)1 架构
hdr "七(一)1  架构与配置：AArch64 + 组委会 qemu_defconfig 基线"

if ! cd "$XKERNEL_DIR" 2>/dev/null; then
    bad "仓库目录不存在: $XKERNEL_DIR"
    return 1
fi

if [ -f "$PLAT_DEFCONFIG" ]; then
    ok "组委会基线存在: $PLAT_DEFCONFIG ($(wc -c <"$PLAT_DEFCONFIG") 字节 / $(wc -l <"$PLAT_DEFCONFIG") 行)"
else
    bad "组委会基线不存在: $PLAT_DEFCONFIG"
fi

if [ -e "platforms/aarch64-qemu-virt" ]; then
    warn "存在旧平台目录 platforms/aarch64-qemu-virt（上游 README 的失效路径）—— 勿使用"
else
    ok "旧平台路径 platforms/aarch64-qemu-virt 不存在（不会误用 README 路径）"
fi

if [ -f .config ]; then
    ok ".config 存在 ($(wc -c <.config) 字节 / $(wc -l <.config) 行)"
    assert     ".config 的 ARCH 为 aarch64"      grep -q  "$PLAT_KCONFIG_ARCH_LINE" .config
    assert     ".config 为 MACHINE_AARCH64_QEMU" grep -q  '^MACHINE_AARCH64_QEMU=y$' .config
    assert     ".config 启用 virtio GPU 驱动"    grep -q  '^KFEAT_DRIVER_VIRTIO_GPU=y$' .config
    assert     ".config 启用 virtio INPUT 驱动"  grep -q  '^KFEAT_DRIVER_VIRTIO_INPUT=y$' .config
    assert     ".config 启用 virtio PCI 总线"    grep -q  '^KFEAT_VIRTIO_BUS_PCI=y$' .config
    assert_not ".config 未混入 riscv64/x86_64/loongarch64" grep -q "$PLAT_KCONFIG_FORBIDDEN" .config
    assert_not ".config 未混入 RK3588 机型"      grep -q '^MACHINE_AARCH64_RK3588=y$' .config
    assert_not ".config 未启用 VMM"              grep -q '^KFEAT_VMM=y$' .config
    info "NR_CPUS = $(grep -m1 -E '^NR_CPUS=' .config)  （期望与 SMP=$PLAT_SMP 匹配）"
else
    bad ".config 不存在 —— 先执行: cp $PLAT_DEFCONFIG .config && make defconfig"
fi

# 正向一致性：组委会基线在隔离目录重展开，与线上 .config 逐字节比对
# 注意 defconfig 的输出路径硬编码为「相对 cwd 的 .config」，故必须在临时目录里跑
if [ -f .config ] && command -v cargo >/dev/null 2>&1 && command -v rustc >/dev/null 2>&1; then
    _T="$(mktemp -d)"
    _HOST="$(rustc -vV 2>/dev/null | sed -n 's/^host: //p')"
    _rc=1
    if cp "$PLAT_DEFCONFIG" "$_T/seed_defconfig" 2>/dev/null; then
        ( cd "$_T" && env CARGO_BUILD_TARGET="$_HOST" RUSTFLAGS= CARGO_ENCODED_RUSTFLAGS= \
            cargo run --quiet \
              --target-dir "$XKERNEL_DIR/target/tools/xconfig" \
              --manifest-path "$XKERNEL_DIR/xtask/Cargo.toml" \
              -p xconfig --bin xconf -- \
              defconfig "$_T/seed_defconfig" \
              --kconfig "$XKERNEL_DIR/Kconfig" --srctree "$XKERNEL_DIR" ) >/dev/null 2>&1 \
          && _rc=0
    fi
    if [ "$_rc" -eq 0 ] && [ -f "$_T/.config" ]; then
        if cmp -s "$_T/.config" .config; then
            ok "线上 .config 与组委会基线重展开结果 逐字节一致 (sha256 $(sha256sum .config | cut -c1-16)…)"
        else
            bad "线上 .config 与组委会基线重展开结果不一致（≠ 基线展开）"
            info "  差异行数: $(diff "$_T/.config" .config 2>/dev/null | grep -c '^[<>]')"
        fi
    else
        warn "跳过「重展开比对」：xconf 调用失败（不影响其它断言）"
    fi
    rm -rf "$_T"
else
    warn "跳过「重展开比对」：cargo/rustc 不可用"
fi

# --------------------------------------------------------------- 七(一)2 QEMU
hdr "七(一)2  QEMU 规格：>= $PLAT_QEMU_MIN_MAJOR.0 且纯 TCG（初赛禁 KVM/HVF）"

QEMU_VER_LINE=""
QEMU_BIN="$(command -v "$PLAT_QEMU_BIN_NAME" 2>/dev/null || true)"
if [ -n "$QEMU_BIN" ]; then
    ok "$PLAT_QEMU_BIN_NAME 位于 $QEMU_BIN"
    QEMU_VER_LINE="$("$QEMU_BIN" --version 2>/dev/null | head -1)"
    _ver="$(printf '%s' "$QEMU_VER_LINE" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
    _maj="${_ver%%.*}"
    if [ -n "${_maj:-}" ] && [ "$_maj" -ge "$PLAT_QEMU_MIN_MAJOR" ] 2>/dev/null; then
        ok "QEMU 版本 $_ver >= $PLAT_QEMU_MIN_MAJOR.0 （$QEMU_VER_LINE）"
    else
        bad "QEMU 版本不达标: '$QEMU_VER_LINE'（要求 >= $PLAT_QEMU_MIN_MAJOR.0）"
    fi
else
    bad "$PLAT_QEMU_BIN_NAME 不在 PATH（检查 \$QEMU_ROOT=${QEMU_ROOT:-$HOME/qemu-root/usr/bin}）"
fi

if [ -e /dev/kvm ]; then
    warn "宿主存在 /dev/kvm —— 必须确保 accel 被显式关闭（ACCEL=$PLAT_ACCEL）"
else
    ok "宿主无 /dev/kvm（即使不传 ACCEL 也必然是纯 TCG）"
fi

# --------------------------------------------------------------- 干跑抓命令行
hdr "QEMU 命令行（make justrun XKMAKE_ARGS=--dry-run 干跑，无副作用）"

_QRAW="$(mktemp)"
if command -v make >/dev/null 2>&1 && [ -f Makefile ]; then
    # shellcheck disable=SC2086
    make justrun XKMAKE_ARGS=--dry-run $PLAT_MAKE_ARGS QEMU_ARGS="$PLAT_QEMU_ARGS" \
        >"$_QRAW" 2>&1
    QCMD="$(extract_qcmd "$_QRAW")"
    if [ -n "$QCMD" ]; then
        ok "成功抓取字面 QEMU 命令行（$(printf '%s\n' "$QCMD" | wc -l) 行）"
        say ""
        printf '%s\n' "$QCMD" | sed 's/^/       /'
        say ""
        QF="$(mktemp)"; printf '%s\n' "$QCMD" >"$QF"

        # —— 七(一)2 纯 TCG（唯一硬判据：命令行无任何 -accel）——
        assert_not "命令行无任何 -accel（纯 TCG 硬判据）" grep -q -- '-accel' "$QF"
        for _a in $PLAT_FORBIDDEN_ACCEL; do
            assert_not "命令行无 -accel $_a" grep -q -- "-accel=$_a" "$QF"
        done
        assert "命令行含 -cpu $PLAT_CPU_TCG（非 host，本身即 TCG 证据）" \
            grep -q -- "-cpu $PLAT_CPU_TCG" "$QF"
        assert "命令行含 -cpu $PLAT_CPU_TCG 或带引号变体" \
            grep -qE -- "-cpu +'?$PLAT_CPU_TCG'?" "$QF"
        assert "命令行含 -machine $PLAT_MACHINE" \
            grep -qE -- "-machine +'?$(printf '%s' "$PLAT_MACHINE" | sed 's/,/[,]/g')'?" "$QF"

        # —— 七(一)1 机型参数 ——
        assert "命令行含 -m $PLAT_MEM（非默认 1g）" grep -qE -- "-m +'?$PLAT_MEM'?" "$QF"
        assert "命令行含 -smp $PLAT_SMP"            grep -qE -- "-smp +'?$PLAT_SMP'?" "$QF"

        # —— 七(一)3 设备组合（四类 virtio）——
        for _d in $PLAT_REQUIRED_DEVICES; do
            assert "设备组合含 $_d" grep -q -- "$_d" "$QF"
        done

        # —— 七(一)3 取证通路 + 图形后端 ——
        assert     "命令行含 -serial mon:stdio（screendump 取证通路）" \
            grep -qE -- "-serial +'?mon:stdio'?" "$QF"
        assert_not "命令行不含 -nographic（否则无图形窗口）" grep -q -- '-nographic' "$QF"
        assert     "命令行含 -device virtio-gpu-pci（图形后端）" \
            grep -q -- '-device virtio-gpu-pci' "$QF"
        assert     "命令行含 -vga none（避免与 virtio-gpu 冲突）" grep -q -- '-vga none' "$QF"

        rm -f "$QF"
    else
        bad "未能抓取 QEMU 命令行（make justrun --dry-run 输出异常）"
        info "dry-run 原始输出尾部："
        tail -20 "$_QRAW" | sed 's/^/       /'
    fi
else
    bad "无 make 或不在仓库根目录，无法干跑"
fi
rm -f "$_QRAW"

# --------------------------------------------------------------- 七(二) 测量
hdr "七(二)  测量规范：git tag 存档 + 宿主指纹"

if git -C "$XKERNEL_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    _sha="$(git -C "$XKERNEL_DIR" rev-parse HEAD 2>/dev/null)"
    _desc="$(git -C "$XKERNEL_DIR" describe --tags --always --dirty 2>/dev/null)"
    ok "git_commit   = $_sha"
    ok "git_describe = $_desc"
    if printf '%s' "$_desc" | grep -q -- '-dirty'; then
        warn "工作区 dirty —— 七(二)3 要求 before/after 基线以 git tag 存档、组委会复核存档代码；采数前先 commit/tag"
    else
        ok "工作区干净（采数二进制与存档代码一致）"
    fi
    if git -C "$XKERNEL_DIR" tag 2>/dev/null | grep -q .; then
        info "现有 tag: $(git -C "$XKERNEL_DIR" tag | tr '\n' ' ')"
    else
        warn "仓库无任何 tag —— 七(二)1/3 的 before/after 基线标签尚未建立"
    fi
else
    bad "$XKERNEL_DIR 不是 git 仓库（无法满足七(二)3 的存档要求）"
fi

info "七(二)4 交叉核验指纹（每份证据都应带这些字段）："
info "  cpu_model = $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ *//')"
info "  mem_total = $(awk '/^MemTotal/{printf "%.1f GiB", $2/1048576}' /proc/meminfo 2>/dev/null)"
info "  os        = $(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release 2>/dev/null)"
info "  qemu      = ${QEMU_VER_LINE:-unknown}"
info "  repeat    = >= $PLAT_REPEAT_MIN 次取 $PLAT_STAT + 波动范围"

hdr "第八节 参考资料（方案选型应可追溯到这里）"
info "1 x-kernel 基线    : $PLAT_REF_XKERNEL"
info "2 Wayland 协议     : $PLAT_REF_WAYLAND"
info "3 X.Org/X11 参考   : $PLAT_REF_XORG_WIKI"
info "4 X.Org 官方文档   : $PLAT_REF_XORG_DOC"
info "5 Chromium Ozone   : $PLAT_REF_OZONE"

# --------------------------------------------------------------- 判定
say ""
say "=============================================================================="
say " 判定：PASS=$PASS_N  FAIL=$FAIL_N  WARN=$WARN_N"
if [ "$FAIL_N" -eq 0 ]; then
    say " PLATFORM_COMPLIANT —— 符合赛题第七节统一评测平台要求"
else
    say " PLATFORM_NOT_COMPLIANT —— 有 $FAIL_N 项不满足，本轮数据不得作为评分证据"
fi
say "=============================================================================="

[ "$FAIL_N" -eq 0 ] && return 0 || return 1
}

check_main >"$BUF" 2>&1
RC=$?
cat "$BUF"

if [ -n "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
    if cp "$BUF" "$OUT" 2>/dev/null; then
        # mktemp 产物是 0600，cp 会继承源权限 → 显式放开，便于证据被读取/归档
        chmod 0644 "$OUT" 2>/dev/null || true
        printf '\n已写出：%s\n' "$OUT"
    else
        printf '\n[WARN] 无法写出：%s\n' "$OUT"
    fi
fi
rm -f "$BUF"
exit "$RC"
