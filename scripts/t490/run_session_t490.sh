#!/usr/bin/env bash
# ============================================================================
# T490 会话编排：平台合规预检 + run-session.py + QEMU(用户级解包) + 长时长取证
#
# 用法：run_session_t490.sh [session_tag] [duration] [interval]
#
# ★ QEMU 平台参数**不在这里手写** —— 全部来自 scripts/t490/platform.env
#   （赛题第六节/第七节(一) 的统一评测平台要求，单一真源，条款追溯见该文件）
#   改参数只改 platform.env，run-session.py 与预检脚本自动同步，避免三处漂移。
#
# 环境变量：
#   PLAT_ALLOW_NONCOMPLIANT=1   即使平台预检 FAIL 也继续（默认会告警但仍继续；
#                               因为 run-session.py 内部已做命令行级硬断言）
# ============================================================================
exec > "$HOME/xk6/tmp/run_session_t490.log" 2>&1
set -x

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=platform.env
. "$HERE/platform.env"
export PATH="$HOME/qemu-root/usr/bin:$HOME/.cargo/bin:$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"

TAG="${1:-run1}"
DUR="${2:-2400}"
IVL="${3:-120}"

mkdir -p "$HOME/xk6/tmp"
OUT="$HOME/xk6/evidence/$(date +%Y-%m-%d)_t490-$TAG"

# ① 交叉核验指纹：QEMU 版本（赛题第七节(一)2 要求 >= 8.0）
"$PLAT_QEMU_BIN_NAME" --version | head -1

# ② 平台合规预检（第七节(一)1/2/3 + (二)）—— 产物随证据归档
bash "$HERE/t490_platform_check.sh" "$OUT/platform-check.txt"
CHECK_RC=$?
if [ "$CHECK_RC" -ne 0 ]; then
    echo "!! 平台预检有 FAIL（详见 $OUT/platform-check.txt）"
    if [ "${PLAT_ALLOW_NONCOMPLIANT:-0}" != "1" ]; then
        echo "!! 已阻断。如确认要带病起会话，请设 PLAT_ALLOW_NONCOMPLIANT=1"
        exit 1
    fi
fi

cd "$HOME/xk6" || exit 1

# ③ 起会话：参数全部来自 platform.env；--require-platform-compliance 让
#    run-session.py 对**实跑命令行**再做一次 第七节(一)3 的硬断言
python3 "$HOME/xk6/scripts/run-session.py" \
  --cwd "$HOME/x-kernel" \
  --make-args "$PLAT_MAKE_ARGS" \
  --with-input \
  --input-devices "$PLAT_INPUT_DEVICES" \
  --require-platform-compliance \
  --duration "$DUR" --interval "$IVL" --first-shot 45 \
  --out "$OUT"
echo "SESSION_RC=$?"
