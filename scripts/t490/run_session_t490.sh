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

# Optional QMP endpoint used by the reproducible keyboard/mouse interaction
# round.  Ordinary rendering rounds leave it unset and keep the platform
# command line unchanged.  The path is validated because it becomes part of
# the make-provided QEMU_ARGS value.
QMP_ARGS=()
if [ -n "${QMP_SOCKET:-}" ]; then
    case "$QMP_SOCKET" in
        *[!A-Za-z0-9_./-]*)
            echo "!! 非法 QMP_SOCKET=$QMP_SOCKET"
            exit 1
            ;;
    esac
    rm -f "$QMP_SOCKET"
    QMP_VALUE="-qmp unix:${QMP_SOCKET},server=on,wait=off ${QMP_EXTRA_ARGS:-}"
    case "$QMP_VALUE" in
        *[\'\"\;\|\&\`\$]*)
            echo "!! 非法 QMP_EXTRA_ARGS"
            exit 1
            ;;
    esac
    QMP_ARGS=(--qemu-args "$QMP_VALUE")
fi

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
FIRST_SHOT="${FIRST_SHOT:-45}"
python3 "$HOME/xk6/scripts/run-session.py" \
  --cwd "$HOME/x-kernel" \
  --make-args "$PLAT_MAKE_ARGS" \
  --with-input \
  --input-devices "$PLAT_INPUT_DEVICES" \
  --require-platform-compliance \
  --duration "$DUR" --interval "$IVL" --first-shot "$FIRST_SHOT" \
  "${QMP_ARGS[@]}" \
  --out "$OUT"
SESSION_RC=$?
echo "SESSION_RC=$SESSION_RC"

# ④ 取证收尾：像素判据 + 回收 guest 持久日志（round_assert.sh）
#    为什么内联在这里：
#      - 它是**唯一会话入口**（t490_round.sh 也经它进来），一处改动覆盖两条路径；
#      - "轮后立刻取 guest 日志"必须与轮次绑定 —— 下一轮 t490_round.sh 会
#        cp -f BASE_IMG disk.img，覆盖后本轮 guest 内 /root/*.log 就永久没了；
#      - 它同时对本轮 screendump 施加像素判据，把"渲染正确"落成可复核的数字。
#    ★ 默认（探索轮）用 `|| true` 保证：判据失败/告警**不影响**本会话退出码。
#    ★ STRICT_GATE=1（验收轮）时反过来：判据不过 ⇒ 最终 rc 非 0。
#      —— 这是对"缺截图 / 探针关键步骤失败却被整体判为成功"这类假阴性的直接封堵。
#      round_assert.sh --strict 的门禁范围（2026-09-22 阶段0.4 扩展）：
#        (a) 每张 PPM 的像素严格集（strict_fail_count > 0）
#        (b) 探针必验项：guest 日志里 `[PROBE_EXIT] <非0>` 的条目数
ASSERT_RC=0
if [ -f "$HERE/round_assert.sh" ]; then
    if [ "${STRICT_GATE:-0}" = "1" ]; then
        bash "$HERE/round_assert.sh" "$TAG" --strict
        ASSERT_RC=$?
    else
        bash "$HERE/round_assert.sh" "$TAG" || true
    fi
    echo "PPM_SUMMARY=$OUT/ppm-summary.txt"
    echo "ASSERT_RC=$ASSERT_RC"
else
    echo "!! 缺 round_assert.sh，跳过取证收尾（本轮无像素判据、guest 日志未回收）"
    [ "${STRICT_GATE:-0}" = "1" ] && ASSERT_RC=99
fi

# 分层最终判据：会话 rc 与判据 rc 都必须通过（STRICT_GATE=1 时判据才进最终码）
FINAL_RC=$SESSION_RC
if [ "${STRICT_GATE:-0}" = "1" ] && [ "$ASSERT_RC" -ne 0 ] && [ "$FINAL_RC" -eq 0 ]; then
    FINAL_RC=$ASSERT_RC
fi
echo "SESSION_RC_FINAL=$FINAL_RC"
exit "$FINAL_RC"
