#!/usr/bin/env bash
# p2_revert.sh — 撤销「缺口 A」的错误修复（属性面编号），恢复 uapi 编号
#
# 背景（report/33）
# ----------------
# 「缺口 A」判定内核属性面编号与 uapi 不符，做了两处替换：
#     GETPROPERTY 0xAA → 0xA8   ✗ 错：0xA8 是 DRM_IOCTL_MODE_ATTACHMODE（deprecated，从未工作）
#     GETPROPBLOB 0xAC → 0xAA   ✗ 错：0xAA 正是 GETPROPERTY
# 权威编号（对 guest 自带 uapi 头 `drm.h` 逐行核对）：
#     0xA8 ATTACHMODE(deprecated) / 0xA9 DETACHMODE(deprecated)
#     0xAA GETPROPERTY            / 0xAB SETPROPERTY / 0xAC GETPROPBLOB
# ⇒ **HEAD 的原始值才是对的**；p2 的替换把两个正确编号改坏，
#   与「缺口 D」属同一类错误（探针与内核用同一套错约定 ⇒ 自洽变绿）。
#
# 机器证据（prop3 轮，`scripts/t490/proptwostage.c` + `iocspy.c`）
# --------------------------------------------------------------
# 真实 libdrm 的 `drmModeGetProperty` 发出：req=0xc04064aa（nr=0xAA, size=64）
# 当前内核只认 0xc04064a8（nr=0xA8, size=64）⇒ 未命中分派 ⇒ errno=95
# ⇒ Weston 读不到任何属性名 ⇒ `plane->type = COUNT` ⇒ `drm_plane_create()` **静默丢弃**
# ⇒ `Failed to find primary plane for output Virtual-1`。
#
# 幂等 + 形态断言；可反复执行。
set -euo pipefail

XK="$HOME/x-kernel"
CARD="$XK/io/drmdevice/src/card0.rs"

cd "$XK"
[ -f "$CARD" ] || { echo "FATAL: 找不到 $CARD"; exit 1; }

echo "=== 回退前 ==="
grep -nE "DrmModeGetProperty>\(DRM_TYPE|DrmModeGetBlob>\(DRM_TYPE" "$CARD"

python3 - "$CARD" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    s = f.read()

pairs = [
    # (当前错误值, 正确的 uapi 值, 说明)
    ("iowr::<DrmModeGetProperty>(DRM_TYPE, 0xA8)",
     "iowr::<DrmModeGetProperty>(DRM_TYPE, 0xAA)",
     "GETPROPERTY: 0xA8(实为 ATTACHMODE) -> 0xAA(uapi 真值)"),
    ("iowr::<DrmModeGetBlob>(DRM_TYPE, 0xAA)",
     "iowr::<DrmModeGetBlob>(DRM_TYPE, 0xAC)",
     "GETPROPBLOB: 0xAA(实为 GETPROPERTY) -> 0xAC(uapi 真值)"),
]

changed = 0
for bad, good, desc in pairs:
    if bad in s:
        s = s.replace(bad, good, 1)
        print("  ✅ " + desc)
        changed += 1
    elif good in s:
        print("  –  已是回退形态：" + desc.split(":")[0])
    else:
        print("FATAL: 两个形态都找不到（源文件可能已变）：" + desc)
        sys.exit(1)

if changed:
    with open(path, "w", encoding="utf-8") as f:
        f.write(s)
    print("  已写回（%d 处）" % changed)
PYEOF

echo
echo "=== 回退后断言（必须与 uapi 一致）==="
grep -nE "DrmModeGetProperty>\(DRM_TYPE|DrmModeGetBlob>\(DRM_TYPE" "$CARD"
grep -q "DrmModeGetProperty>(DRM_TYPE, 0xAA)" "$CARD" || { echo "FATAL: GETPROPERTY 未回到 0xAA"; exit 1; }
grep -q "DrmModeGetBlob>(DRM_TYPE, 0xAC)"     "$CARD" || { echo "FATAL: GETPROPBLOB 未回到 0xAC"; exit 1; }
echo "  断言通过 ✓（GETPROPERTY=0xAA、GETPROPBLOB=0xAC，与 uapi 头文件逐行一致）"

echo
echo "=== 与 HEAD 的差异（只应剩下 drm.rs 的注释/其它已认可改动）==="
git --no-pager diff --stat -- io/drmdevice/src/card0.rs io/drmdevice/src/drm.rs
echo
echo "P2_REVERT_OK"
