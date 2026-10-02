#!/usr/bin/env bash
# round_assert.sh —— 单轮结束后的取证收尾（尺寸校验 → 收 guest 日志 → 像素判据 → 汇总）
#
# 用法：
#   bash round_assert.sh <tag> [--strict] [--force-e2fsck]
#
# 为什么要有它（而不是每次手工敲一遍）
#   1. **guest 日志必须在本轮之后立刻取回**：下一轮 t490_round.sh 会 `cp -f BASE_IMG disk.img`
#      覆盖镜像，该轮 guest 内 /root/*.log 就永久没了。把它内联成会话收尾的一步，
#      就不依赖"人记得按顺序做"。
#   2. 像素判据的输入是 QEMU monitor screendump 的**原始 PPM**（赛题第七节(一)3 唯一
#      认可的取证方式）。PPM 留存与否不能靠运气，这里发现 0 张就大声告警。
#   3. 每轮的"渲染正确"必须留下可复核的数字，否则只是口头结论。
#
# 产物（全部为**新增**文件，绝不改写本轮既有文件）：
#   <EV>/ppm-assert-<shot>.json     逐张判据
#   <EV>/ppm-diff-<a>__<b>.json     相邻帧心跳判据
#   <EV>/ppm-summary.txt            本轮汇总（尺寸/严格集/失败项/心跳/type 直方图）
#   <EV>/guest/*.log                从 disk.img 回收的 guest 持久日志
#
# 退出码：仅当 --strict 且严格集未全通过时为 1；其余情况一律 0（判据是取证，不是门禁）。

set -u

TAG="${1:?usage: round_assert.sh <tag> [--strict] [--force-e2fsck]}"
shift || true
STRICT=""
FORCE_E2=""
for a in "$@"; do
    case "$a" in
        --strict)       STRICT="--strict" ;;
        --force-e2fsck) FORCE_E2=1 ;;
        *) echo "!! 未知参数: $a" ;;
    esac
done

HERE="$(cd "$(dirname "$0")" && pwd)"
ASSERT="$HERE/ppm_assert.py"
ASSERT_PROFILE="${ASSERT_PROFILE:-legacy}"
PULL="$HERE/pull_guest_logs.sh"
IMAGE="$HOME/x-kernel/disk.img"
PY=python3
command -v "$PY" >/dev/null 2>&1 || PY=python

EV="$(ls -d "$HOME"/xk6/evidence/*"_t490-$TAG" 2>/dev/null | tail -1)"
if [ -z "$EV" ] || [ ! -d "$EV" ]; then
    echo "!! 找不到本轮证据目录: ~/xk6/evidence/*_t490-$TAG（tag=$TAG）"
    exit 1
fi
[ -f "$ASSERT" ] || { echo "!! 判据脚本缺失: $ASSERT"; exit 1; }

# ★ 超时护栏：本脚本被挂在会话收尾里，**绝不能把一轮会话卡住**。
#   任何一次判据调用最多 120 s，超时按失败处理（不影响 QEMU 的退出码）。
RUNTO=""
if command -v timeout >/dev/null 2>&1; then
    RUNTO="timeout 120"
fi

SUMMARY="$EV/ppm-summary.txt"
: > "$SUMMARY"
say() { echo "$*" | tee -a "$SUMMARY"; }

say "=================================================================="
say "round_assert  tag=$TAG"
say "证据目录      $EV"
say "时间          $(date -Is)"
say "=================================================================="

# ---------------------------------------------------------------- ① 截图清单与尺寸一致性
say ""
say "--- ① screendump 清单与尺寸一致性 ---"
PPM_LIST=$(ls "$EV"/screenshots/*.ppm 2>/dev/null || true)
N_PPM=$(printf '%s\n' "$PPM_LIST" | grep -c '\.ppm$' || true)
N_PNG=$(ls "$EV"/screenshots/*.png 2>/dev/null | wc -l || true)
say "PPM 张数 : $N_PPM"
say "PNG 张数 : $N_PNG"

if [ "$N_PPM" -eq 0 ]; then
    say "!! 本轮没有 PPM：判据无输入。"
    say "!!   —— 流程本身不删 PPM（ppm2png.py 默认 --keep 且无删除逻辑），"
    say "!!      出现这种情况通常是有人手工转 PNG 后删了 PPM（历史上 nnp / inotifycpu 两轮如此）。"
    say "!!      后果：该轮不算合规证据包，无法参与跨轮像素比较。"
    printf 'RESULT: NO_PPM\n' >> "$SUMMARY"
    exit 0
fi

SIZES="$(for f in $PPM_LIST; do
    $RUNTO $PY - "$f" <<'PYEOF' 2>/dev/null
import os, sys
p = sys.argv[1]
with open(p, 'rb') as fh:
    head = fh.read(64)
parts = head.split(b'\n')
try:
    w, h = parts[1].split()[:2]
    print("%sx%s %d %s" % (w.decode(), h.decode(), os.path.getsize(p), os.path.basename(p)))
except Exception:
    print("BAD_HEADER %d %s" % (os.path.getsize(p), os.path.basename(p)))
PYEOF
done)"
printf '%s\n' "$SIZES" | awk '{print "  "$0}' >> "$SUMMARY"
UNIQ_SIZES=$(printf '%s\n' "$SIZES" | awk '{print $1}' | sort -u | tr '\n' ' ')
UNIQ_BYTES=$(printf '%s\n' "$SIZES" | awk '{print $2}' | sort -u | tr '\n' ' ')
say "尺寸集合     : $UNIQ_SIZES"
say "字节数集合   : $UNIQ_BYTES"

SIZE_OK=1
case "$(printf '%s' "$UNIQ_SIZES" | wc -w)" in
    1) ;;
    *) SIZE_OK=0; say "!! 本轮内截图尺寸不一致 → 该轮证据不得用于跨轮像素比较（疑 weston 模式中途变化或截图中断）" ;;
esac
for b in $UNIQ_BYTES; do
    case "$b" in
        921615|3072016) ;;
        *) SIZE_OK=0; say "!! 出现非预期字节数 $b（合法值只有 921615=640x480 与 3072016=1280x800）" ;;
    esac
done
# 判据用**众数尺寸**而不是首图尺寸：实测 weston 在会话中途才把模式设成 1280×800，
# 于是同一轮里首张仍是 640×480、之后全是 1280×800（2026-09-22 C0 轮实测）。
# 拿首图尺寸去要求整轮，会把正确的 1280×800 截图误判成"尺寸不符"。
DOM_SZ=$(printf '%s\n' "$SIZES" | awk '{print $1}' | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
say "众数尺寸     : $DOM_SZ（用于逐张判据的 --expect-size）"
if [ "$SIZE_OK" -eq 1 ]; then
    say "→ 尺寸一致性通过（集合单元素 $DOM_SZ）"
else
    say "→ 尺寸不一致（有异于众数的帧，通常是 weston 设模式之前的首帧）；"
    say "   仍按众数 $DOM_SZ 逐张判定，非众数帧只记'尺寸不符'、不计入渲染失败"
fi

# ---------------------------------------------------------------- ② 收尾是否干净 → 决定要不要 fsck
say ""
say "--- ② 会话收尾状态与镜像一致性 ---"
CLEAN=0
if [ -f "$EV/console.log" ]; then
    if grep -q "SESSION END (exit=0)" "$EV/console.log"; then
        CLEAN=1
        say "console.log 有 'SESSION END (exit=0)' → QEMU 正常收尾"
    elif grep -qE "未响应 Ctrl-A x|仍存活，发送 SIGKILL" "$EV/console.log"; then
        say "!! console.log 显示 QEMU 是被 SIGTERM/SIGKILL 收掉的 → ext4 可能带脏 journal"
    else
        say "!! console.log 未见正常收尾标记（会话可能被外部中断）"
    fi
else
    say "!! console.log 缺失"
fi

if [ "$CLEAN" -eq 0 ] || [ -n "$FORCE_E2" ]; then
    if [ -f "$IMAGE" ]; then
        if pgrep -f "qemu-system-aarch6[4]" >/dev/null 2>&1; then
            say "!! QEMU 仍在运行 → 跳过 e2fsck 与 guest 日志回收（debugfs 不能在挂载态读）"
        else
            say "→ 先 e2fsck -f -y（避免 debugfs dump 到陈旧/残缺内容）"
            e2fsck -f -y "$IMAGE" 2>&1 | tail -3 >> "$SUMMARY"
        fi
    else
        say "!! 镜像不存在: $IMAGE"
    fi
fi

# ---------------------------------------------------------------- ③ 回收 guest 持久日志
say ""
say "--- ③ 回收 guest 持久日志 ---"
if [ -f "$PULL" ]; then
    # ★ pull_guest_logs.sh 内置清单只覆盖 chromium.log/nnp.log/install.log 等历史文件，
    #   本轮 autorun_v3.sh 写的是 full.log / chrome-full.log / chrome-snap.log / a0.log
    #   —— 必须以「额外文件」传入，否则会 dump 出 0 字节并被误判成"无日志"。
    # ★ 2026-09-22 X11 路线：autorun_x11.sh 写的是 autorun-x11.log / xorg.log /
    #   xorg-stderr.log / jwm.log，同样必须在额外清单里，否则"Xorg 为什么没起来"
    #   这个最关键的问题会变成"无日志可查"。
    bash "$PULL" "$TAG" \
        /root/full.log /root/chrome-full.log /root/chrome-snap.log /root/a0.log \
        /root/autorun-x11.log /root/xorg.log /root/xorg-stderr.log \
        /root/jwm.log /root/prop.log /root/net.log /root/weston-round.log /root/weston.log /root/seatd.log /root/weston-install.log /root/simple-shm.log \
        /root/plane2.out /root/drmstd.out \
        /root/std1.log /root/std1-planeprobe.out /root/std2-drmstdprobe.out /root/std3-iocspy.out \
        /root/std3.log /root/std3-udevprobe.out /root/std3-seatprobe.out /root/std3-seatd.log \
        /root/weston9.log /root/weston9-weston.log /root/weston9-stdout.log /root/weston9-seatd.log /root/weston9-simple-shm.log \
        /root/weston10.log /root/weston10-sim.out /root/weston10-weston.log /root/weston10-iocspy.log /root/weston10-seatd.log \
        /root/weston11.log /root/weston11-weston.log /root/weston11-stdout.log /root/weston11-seatd.log /root/weston11-simple-shm.log \
        /root/prop2.log /root/prop2.out /root/prop3.log /root/prop3.out \
        /root/single-initial.log /root/single-initial.csv /root/single-chromium.log \
        /root/single-weston.log /root/single-weston-stdout.log /root/single-seatd.log \
        /root/single-udevd.log /root/single-udev-trigger.log /root/single-udev-settle.log \
        >> "$SUMMARY" 2>&1
else
    say "!! pull_guest_logs.sh 缺失，跳过"
fi
GUEST="$EV/guest"
ls -la "$GUEST" 2>/dev/null | tail -20 >> "$SUMMARY" 2>&1

# ---------------------------------------------------------------- ③.5 探针必验项（分层判据）
# 为什么单列一节（2026-09-22 阶段0.4）：
#   历史事故 —— 探针的 GETPLANE 已经 rc=-1（关键步骤失败），但它的汇总行仍打
#   PLANE_OK，整轮被读成"plane 面正常"。探针现在固定输出机器行：
#       [PROBE_EXIT] <code> verdict=<V>     （0 = 关键 ioctl 全通过；非 0 = 必验项失败）
#       [PROBE_ABI]  ...                    （探针自身结构体是否与标准 uapi 一致）
#       [PLANESUM]   ...                    （逐项计数）
#   这里把它们汇总成**逐条必验项**，并在 --strict 下纳入门禁，
#   堵住"探针失败却被整体判为成功"的假绿。
say ""
say "--- ③.5 探针必验项（PROBE_EXIT / PLANESUM / PROBE_ABI）---"
N_PROBE_FAIL=0
PROBE_SRC=$(ls "$GUEST"/_root_*.log "$GUEST"/_root_*.out 2>/dev/null || true)
if [ -z "$PROBE_SRC" ]; then
    say "  (guest 目录下无 _root_*.log / *.out —— 无探针输出可判)"
else
    PROBE_LINES=$(grep -ahE '^\[PROBE_EXIT\]|^\[PLANESUM\]|^\[PROBE_ABI\]' $PROBE_SRC 2>/dev/null || true)
    if [ -z "$PROBE_LINES" ]; then
        say "  (本轮 guest 日志中未出现探针机器行 —— 无必验项)"
    else
        printf '%s\n' "$PROBE_LINES" | sed 's/^/  /' >> "$SUMMARY"
        N_PROBE_FAIL=$(printf '%s\n' "$PROBE_LINES" | grep -cE '^\[PROBE_EXIT\] [1-9]' || true)
        say "  探针条目数   : $(printf '%s\n' "$PROBE_LINES" | grep -c . || true)"
        say "  探针必验失败 : $N_PROBE_FAIL"
    fi
fi

# ---------------------------------------------------------------- ④ 逐张像素判据
say ""
say "--- ④ 逐张像素判据（ppm_assert.py） ---"
N_ASSERT=0
N_ASSERT_FAIL=0
N_SIZE_MISMATCH=0
for f in $PPM_LIST; do
    base="$(basename "$f" .ppm)"
    out="$EV/ppm-assert-$base.json"
    N_ASSERT=$((N_ASSERT + 1))
    $RUNTO $PY "$ASSERT" "$f" --profile "$ASSERT_PROFILE" --expect-size "$DOM_SZ" --strict --quiet \
        --json "$out" >> "$SUMMARY" 2>&1
    rc=$?
    # ⚠️ 退出码 ≠ 严格集结论：--expect-size 不符时也会 exit 1。
    # 所以必须从 JSON 里的 strict_fail_count 判严格集，否则尺寸不符会被误记成"渲染不正确"。
    sfc=$(grep -o '"strict_fail_count": [0-9]*' "$out" 2>/dev/null | head -1 | grep -o '[0-9]*$')
    [ -n "$sfc" ] || sfc=1
    if [ "$sfc" -gt 0 ]; then
        N_ASSERT_FAIL=$((N_ASSERT_FAIL + 1))
        say "  $base: 严格集未通过 $(grep -o '"strict_fail_names": \[[^]]*\]' "$out" 2>/dev/null | head -1)"
    elif [ "$rc" -ne 0 ]; then
        N_SIZE_MISMATCH=$((N_SIZE_MISMATCH + 1))
        say "  $base: 尺寸校验未通过（严格集本身全过；本图与首图尺寸不同）"
    fi
done
say "判定张数     : $N_ASSERT"
say "严格集未通过 : $N_ASSERT_FAIL"
say "尺寸不符张数 : $N_SIZE_MISMATCH"

# ---------------------------------------------------------------- ⑤ 相邻帧心跳判据
say ""
say "--- ⑤ 相邻帧心跳判据（两帧必须有局部差异） ---"
PREV=""
N_DIFF=0
N_DIFF_OK=0
for f in $PPM_LIST; do
    if [ -n "$PREV" ]; then
        a="$(basename "$PREV" .ppm)"
        b="$(basename "$f" .ppm)"
        out="$EV/ppm-diff-${a}__${b}.json"
        N_DIFF=$((N_DIFF + 1))
        if $RUNTO $PY "$ASSERT" "$PREV" --diff "$f" --min-changed 200 --quiet \
                --json "$out" >> "$SUMMARY" 2>&1; then
            N_DIFF_OK=$((N_DIFF_OK + 1))
        fi
    fi
    PREV="$f"
done
say "帧对数       : $N_DIFF"
say "心跳成立对数 : $N_DIFF_OK"
if [ "$N_DIFF" -gt 0 ] && [ "$N_DIFF_OK" -eq 0 ]; then
    say "→ 所有相邻帧完全相同 ⇒ renderer 未在重绘 / JS 未在执行 / 画面已冻结"
fi

# ---------------------------------------------------------------- ⑥ 关键证据行摘录
say ""
say "--- ⑥ 关键证据行摘录 ---"
for f in "$EV/console.log" "$GUEST/_root_full.log" "$GUEST/_root_chrome-full.log" "$GUEST/_root_a0.log"; do
    [ -f "$f" ] || continue
    say "### $(basename "$f")"
    grep -aE "VARIANT|type=renderer|type=gpu-process|type=\(browser/none\)|已退出 rc=|gl_factory|not found in allowed|gl=none|swiftshader|ZygoteMain|FileURLLoader|FATAL|A0 Ozone|allowed implementations" \
        "$f" 2>/dev/null | tail -40 | sed 's/^/  /' >> "$SUMMARY"
done

say ""
say "--- ⑦ type= 直方图（renderer / gpu-process 是否出现过）---"
if [ -f "$GUEST/_root_chrome-snap.log" ]; then
    grep -aoE 'type=[a-z_-]+|type=\(browser/none\)' "$GUEST/_root_chrome-snap.log" 2>/dev/null \
        | sort | uniq -c | sort -rn | sed 's/^/  /' >> "$SUMMARY"
else
    say "  (缺 guest/_root_chrome-snap.log，无法统计)"
fi

# ---------------------------------------------------------------- ⑧ X11 启动链判定摘录
# 2026-09-22 新增：X11 路线的失败点此前只能靠"手动探针"定位（report/25），
# 因为轮后只回收了 chromium 系日志。这里把 X11 链的关键判据固定进轮后摘要，
# 使"Xorg 到底起没起、卡在哪一步"成为每轮自动产出，而不是靠人肉复现。
say ""
say "--- ⑧ X11 启动链判定摘录 ---"
if [ -f "$GUEST/_root_autorun-x11.log" ]; then
    say "### STAGE 打点（卡在哪一步）"
    grep -aE 'STAGE=' "$GUEST/_root_autorun-x11.log" | sed 's/^/  /' >> "$SUMMARY"
    say "### Xorg 变体与会话结果"
    grep -aE 'Xorg try|socket /tmp/.X11-unix/X0|Xorg 进程在|超时，未出现|Xorg UP|Xorg 未就绪' \
        "$GUEST/_root_autorun-x11.log" | tail -25 | sed 's/^/  /' >> "$SUMMARY"
    say "### chromium 存活结论 / 对照组"
    grep -aE 'chromium 存活|chromium 30s 内退出|对照组|进程快照|/dev/shm|kiosk home' \
        "$GUEST/_root_autorun-x11.log" | tail -20 | sed 's/^/  /' >> "$SUMMARY"
else
    say "  !! 缺 guest/_root_autorun-x11.log ⇒ /etc/profile.d/99-autostart.sh 钩子"
    say "     未生效或 /root/autorun.sh 未执行（整轮「静默空跑」的典型特征）"
fi
if [ -f "$GUEST/_root_xorg.log" ]; then
    say "### Xorg 决定行（xorg.log 中 EE/WW/modeset/Output）"
    grep -aE '\(EE\)|\(WW\)|modeset|Output|Depth|Virtual|glx' "$GUEST/_root_xorg.log" \
        | tail -25 | sed 's/^/  /' >> "$SUMMARY"
else
    say "  (缺 guest/_root_xorg.log ⇒ Xorg 未产出自己的日志)"
fi
if [ -f "$GUEST/_root_chromium.log" ]; then
    say "### chromium 进程类型直方图（X11 轮）"
    grep -aoE 'type=[a-z_-]+|type=\(browser/none\)' "$GUEST/_root_chromium.log" 2>/dev/null \
        | sort | uniq -c | sort -rn | sed 's/^/  /' >> "$SUMMARY"
fi

say ""
say "=================================================================="
say "SUMMARY_END tag=$TAG  ppm=$N_PPM  严格集未通过=$N_ASSERT_FAIL  尺寸不符=$N_SIZE_MISMATCH  心跳=$N_DIFF_OK/$N_DIFF  探针必验失败=$N_PROBE_FAIL"
say "=================================================================="

# 门禁（--strict 才生效）：像素严格集失败 **或** 探针必验项失败 ⇒ 本轮不通过。
# 固定输出 GATE 行，便于机器读取与跨轮比较。
say "GATE  strict_fail=$N_ASSERT_FAIL  probe_fail=$N_PROBE_FAIL"
if [ -n "$STRICT" ]; then
    if [ "$N_ASSERT_FAIL" -gt 0 ] || [ "$N_PROBE_FAIL" -gt 0 ]; then
        say "GATE: FAIL"
        exit 1
    fi
    say "GATE: PASS"
fi
exit 0
