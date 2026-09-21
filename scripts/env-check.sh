#!/usr/bin/env bash
# env-check.sh — 赛题六 基础任务 · 宿主机依赖自检 + 指纹采集
#
# 作用：一次性确认 Linux 主机是否满足构建/运行 x-kernel 的全部前提，
#       并输出赛题第七节（二）4 要求的"宿主机 CPU 型号/内存/QEMU 版本/OS"指纹。
#
# 必须在 Linux 主机运行（Windows 无法构建 x-kernel）。
#
# 用法：
#   bash scripts/env-check.sh
#   bash scripts/env-check.sh --out evidence/s1-env/env.txt

set -u

OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

FAIL=0
WARN=0

emit() { printf '%s\n' "$*"; }

check_cmd() {  # check_cmd <name> <cmd...>
    local name="$1"; shift
    if command -v "$1" >/dev/null 2>&1; then
        emit "  [ OK ] $name"
        return 0
    else
        emit "  [FAIL] $name  (未找到: $1)"
        FAIL=$((FAIL + 1))
        return 1
    fi
}

report() {
    emit "=============================================================="
    emit " 赛题六 · 基础任务 · 环境自检"
    emit " 时间: $(date -Is)"
    emit "=============================================================="

    emit ""
    emit "── 1. 宿主机指纹（赛题要求交叉核验） ──────────────────"
    emit "  OS          : $( (. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}") || uname -s )"
    emit "  Kernel      : $(uname -sr)"
    emit "  架构        : $(uname -m)"
    if [ -r /proc/cpuinfo ]; then
        emit "  CPU 型号    : $(grep -m1 'model name' /proc/cpuinfo | sed 's/.*: //')"
        emit "  CPU 逻辑核  : $(grep -c '^processor' /proc/cpuinfo)"
    fi
    if command -v free >/dev/null 2>&1; then
        emit "  内存        : $(free -h | awk '/^Mem:/{print $2" total / "$7" available"}')"
    fi
    emit "  磁盘(当前)  : $(df -h . | awk 'NR==2{print $4" available on "$6}')"
    emit "  用户        : $(id -un)  (sudo: $( [ "$(id -u)" -eq 0 ] && echo "已是 root" || echo "非 root，需密码" ))"

    emit ""
    emit "── 2. 关键工具 ────────────────────────────────────────"
    check_cmd "git"                  git
    check_cmd "make"                 make
    check_cmd "curl"                 curl
    check_cmd "xz"                   xz
    check_cmd "python3"              python3
    check_cmd "cc / gcc"             cc
    check_cmd "debugfs (e2fsprogs)"  debugfs
    check_cmd "resize2fs"            resize2fs
    check_cmd "e2fsck"               e2fsck
    check_cmd "truncate"             truncate
    check_cmd "dumpe2fs"             dumpe2fs

    emit ""
    emit "── 3. QEMU（赛题硬性要求 >= 8.0）────────────────────"
    if command -v qemu-system-aarch64 >/dev/null 2>&1; then
        local qv qmaj qmin
        qv="$(qemu-system-aarch64 --version | head -n1)"
        emit "  $qv"
        qmaj="$(printf '%s' "$qv" | sed -n 's/.*version \([0-9]*\)\.\([0-9]*\).*/\1/p')"
        qmin="$(printf '%s' "$qv" | sed -n 's/.*version \([0-9]*\)\.\([0-9]*\).*/\2/p')"
        if [ -n "$qmaj" ] && [ "$qmaj" -ge 8 ]; then
            emit "  [ OK ] 版本满足 >= 8.0"
        else
            emit "  [FAIL] 版本低于 8.0，赛题不接受"
            FAIL=$((FAIL + 1))
        fi
        # virtio-gpu / virtio-input 设备是否可用
        for dev in virtio-gpu-pci virtio-input-pci virtio-blk-pci virtio-net-pci; do
            if qemu-system-aarch64 -device help 2>&1 | grep -q "$dev"; then
                emit "  [ OK ] device $dev"
            else
                emit "  [WARN] device $dev 未在 -device help 中出现（可能命名不同）"
                WARN=$((WARN + 1))
            fi
        done
    else
        emit "  [FAIL] qemu-system-aarch64 未安装"
        FAIL=$((FAIL + 1))
    fi

    emit ""
    emit "── 4. Rust 工具链 ─────────────────────────────────────"
    if command -v rustc >/dev/null 2>&1; then
        emit "  rustc       : $(rustc --version)"
        emit "  cargo       : $(cargo --version)"
        emit "  host target : $(rustc -vV | sed -n 's/^host: //p')"
        if rustup target list --installed 2>/dev/null | grep -qx 'aarch64-unknown-none-softfloat'; then
            emit "  [ OK ] target aarch64-unknown-none-softfloat 已安装"
        else
            emit "  [FAIL] 缺少 target: aarch64-unknown-none-softfloat"
            emit "         修复: rustup target add aarch64-unknown-none-softfloat"
            FAIL=$((FAIL + 1))
        fi
    else
        emit "  [FAIL] rustc 未安装（需 rustup）"
        FAIL=$((FAIL + 1))
    fi

    emit ""
    emit "── 5. AArch64 musl 交叉工具链（uapps prepare 需要）────"
    if command -v aarch64-linux-musl-gcc >/dev/null 2>&1; then
        emit "  [ OK ] $(aarch64-linux-musl-gcc --version | head -n1)"
    else
        emit "  [WARN] aarch64-linux-musl-gcc 不在 PATH"
        emit "         uapps/weston-start 是纯脚本、不需要它；"
        emit "         但含 Rust/C 源码的 uapp 会编译失败。"
        emit "         修复: curl -LO https://musl.cc/aarch64-linux-musl-cross.tgz \\"
        emit "               && sudo tar -C /opt -xzf aarch64-linux-musl-cross.tgz \\"
        emit "               && export PATH=/opt/aarch64-linux-musl-cross/bin:\$PATH"
        WARN=$((WARN + 1))
    fi

    emit ""
    emit "── 6. 软件加速相关（判断是否天然纯 TCG）───────────────"
    emit "  宿主架构    : $(uname -m)"
    if [ "$(uname -m)" = "aarch64" ]; then
        emit "  [注意] 宿主是 aarch64，跑 aarch64 guest 时 xkmake 可能启用 KVM。"
        emit "         初赛取证必须显式传 ACCEL=n（或 KFEAT_VMM=y）。"
    else
        emit "  [ OK ] 宿主与 guest 架构不同，xkmake 不会加 -accel → 天然纯 TCG。"
    fi
    if [ -e /dev/kvm ]; then
        emit "  /dev/kvm    : 存在（但非 aarch64 宿主时不会被使用）"
    else
        emit "  /dev/kvm    : 不存在"
    fi
    if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
        emit "  [注意] 检测到 WSL/WSL2。xkmake 会主动排除 KVM，但"
        emit "         WSL 下 TCG 性能更差、debugfs/loop 设备可能有坑。建议用原生 Linux。"
        WARN=$((WARN + 1))
    fi

    emit ""
    emit "── 7. 结论 ────────────────────────────────────────────"
    if [ "$FAIL" -eq 0 ]; then
        emit "  ✅ 环境就绪（FAIL=0, WARN=$WARN）"
    else
        emit "  ❌ 环境未就绪：FAIL=$FAIL, WARN=$WARN —— 按上面 [FAIL] 项修完再继续"
    fi
    emit "=============================================================="

    return "$FAIL"
}

# 注意：这里刻意 **不用管道** 调 report。
# 若写成 `report | tee "$OUT"`，report 会跑在子 shell 里，
# 里面累加的 FAIL/WARN 无法传回父 shell，导致退出码恒为 0（静默失真）。
TMP="${TMPDIR:-/tmp}/xk-env-check-$$.txt"
report >"$TMP" 2>&1
RC=$?

if [ -n "$OUT" ]; then
    mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
    cp "$TMP" "$OUT" 2>/dev/null && echo "已落盘: $OUT（退出码 $RC）" || echo "⚠️ 无法写入 $OUT"
fi

cat "$TMP" 2>/dev/null || sed -n '1,$p' "$TMP"
rm -f "$TMP"

exit "$RC"
