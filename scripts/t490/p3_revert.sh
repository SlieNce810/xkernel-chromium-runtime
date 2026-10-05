#!/usr/bin/env bash
# p3_revert.sh — 撤销「缺口 D」的错误修复（GETPLANE 48 字节扩展），**保留**缺口 A 的编号修复
#
# 背景：report/31 → report/32（勘误）
# --------------------------------
# report/31 判定 `DrmModeGetPlane` 少了 mainline uapi 的 crtc_x/crtc_y/x/y 四个 u32、
# sizeof 应为 48 —— **该判定是错的**。标准 uapi 的 `struct drm_mode_get_plane` 是
# 6×u32 + 1×u64 = **32 字节**，没有坐标字段（crtc_x/crtc_y/x/y 属于 drm_mode_set_plane）。
#
# 据此执行的 p3 修改把**本来正确**的内核改成了 48 字节，于是：
#   x-kernel `iowr::<T>()` 把 size_of::<T>() 编进请求值第 16–29 位，
#   `card0.rs` 的分派是 `match cmd` 精确匹配 ⇒ 标准 libdrm 的 32 字节请求必然落空（errno=95）。
#
# 本脚本做三件事（幂等 + 形态断言）：
#   1) drm.rs  ：从 DrmModeGetPlane 移除 crtc_x/crtc_y/x/y（10 字段 → 7 字段）
#   2) card0.rs：移除对应的 4 行赋值
#   3) 断言    ：字段序列 == 标准 uapi；并**确认缺口 A 的 0xA8 / 0xAA 编号仍在**
#
# ⚠️ 禁止用 `git checkout -- <file>` 整文件回退：那会连带丢掉缺口 A 的编号修复
#    （card0.rs 里 0xAA→0xA8 / 0xAC→0xAA 两行是**有效修改**，必须保留）。
set -euo pipefail

XK="$HOME/x-kernel"
DRM="$XK/io/drmdevice/src/drm.rs"
CARD="$XK/io/drmdevice/src/card0.rs"

cd "$XK"
[ -f "$DRM" ] || { echo "FATAL: 找不到 $DRM"; exit 1; }
[ -f "$CARD" ] || { echo "FATAL: 找不到 $CARD"; exit 1; }

echo "=== 回退前：GetPlane 结构体 ==="
grep -n -A 13 'pub struct DrmModeGetPlane {' "$DRM" || true
echo "=== 回退前：handle 里的字段赋值 ==="
grep -n -B2 -A 8 'p.crtc_id = CRTC_ID;' "$CARD" || true

python3 - "$DRM" "$CARD" <<'PYEOF'
import sys, re

drm_path, card_path = sys.argv[1], sys.argv[2]

GOOD_STRUCT = """pub struct DrmModeGetPlane {
    pub plane_id: u32,
    pub crtc_id: u32,
    pub fb_id: u32,
    /* \u2605 2026-09-22 \u52d8\u8bef\uff08report/32\uff09\uff1a\u6807\u51c6 uapi \u7684 drm_mode_get_plane \u662f
     * 6\u00d7u32 + 1\u00d7u64 = 32 \u5b57\u8282\uff0c**\u6ca1\u6709** crtc_x/crtc_y/x/y \u2014\u2014 \u90a3\u56db\u4e2a\u5b57\u6bb5
     * \u5c5e\u4e8e drm_mode_set_plane\u3002\u6b64\u524d\u6309\u201c48 \u5b57\u8282\u201d\u8865\u5b57\u6bb5\u7684\u505a\u6cd5\u4f7f\u6807\u51c6
     * libdrm \u7684 32 \u5b57\u8282\u8bf7\u6c42\u5931\u914d\uff08iowr \u628a size \u7f16\u8fdb\u8bf7\u6c42\u503c\uff09\uff0c\u5df2\u56de\u9000\u3002 */
    pub possible_crtcs: u32,
    pub gamma_size: u32,
    pub count_format_types: u32,
    pub format_type_ptr: UserPtr<u32>,
}"""

WANT = ["plane_id", "crtc_id", "fb_id", "possible_crtcs", "gamma_size",
        "count_format_types", "format_type_ptr"]

with open(drm_path, encoding="utf-8") as f:
    s = f.read()

pat = re.compile(r"pub struct DrmModeGetPlane \{.*?\n\}", re.S)
m = pat.search(s)
if not m:
    print("FATAL: drm.rs 中找不到 DrmModeGetPlane 定义")
    sys.exit(1)

fields = [l.strip().split(":")[0].replace("pub ", "")
          for l in m.group(0).splitlines() if l.strip().startswith("pub ")]

if fields == WANT:
    print("drm.rs   : 已是回退形态（7 字段 32B），无需改动")
else:
    s = s[:m.start()] + GOOD_STRUCT + s[m.end():]
    with open(drm_path, "w", encoding="utf-8") as f:
        f.write(s)
    print("drm.rs   : 已移除 crtc_x/crtc_y/x/y  (%d 字段 -> 7 字段)" % len(fields))

# ---- card0.rs：移除 4 行赋值 ----
BLOCK = """        /* 这四个字段是 mainline uapi 的一部分（结构体布局必须完整），
         * 语义为 plane 当前的裁剪/位置；未启用时全 0。 */
        p.crtc_x = 0;
        p.crtc_y = 0;
        p.x = 0;
        p.y = 0;
"""
with open(card_path, encoding="utf-8") as f:
    c = f.read()

if BLOCK in c:
    c = c.replace(BLOCK, "", 1)
    with open(card_path, "w", encoding="utf-8") as f:
        f.write(c)
    print("card0.rs : 已移除 4 行 crtc_* 赋值")
elif "p.crtc_x = 0;" in c:
    print("FATAL: card0.rs 处于未预期的中间形态（含 p.crtc_x = 0 但注释块不匹配）")
    sys.exit(1)
else:
    print("card0.rs : 已是回退形态，无需改动")
PYEOF

echo
echo "=== 回退后断言 1：字段序列 == 标准 uapi ==="
python3 - "$DRM" <<'PYEOF'
import sys, re
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"pub struct DrmModeGetPlane \{(.*?)\}", src, re.S)
assert m, "找不到 DrmModeGetPlane"
order = [l.strip().split(":")[0].replace("pub ", "")
         for l in m.group(1).strip().splitlines() if l.strip().startswith("pub ")]
want = ["plane_id", "crtc_id", "fb_id", "possible_crtcs", "gamma_size",
        "count_format_types", "format_type_ptr"]
if order != want:
    print("FATAL: 字段序列不符标准 uapi:", order)
    sys.exit(1)
print("  字段序列 OK:", " ".join(order))
print("  预期 sizeof = 6×4 + 8 = 32 字节（AArch64 对齐 8）")
PYEOF

echo
echo "=== 回退后断言 2：缺口 A 的编号修复必须仍在 ==="
grep -n "DRM_TYPE, 0xA8" "$CARD" | head -2 || { echo "FATAL: GETPROPERTY=0xA8 丢失！"; exit 1; }
grep -n "DRM_TYPE, 0xAA" "$CARD" | head -2 || { echo "FATAL: GETPROPBLOB=0xAA 丢失！"; exit 1; }
echo "  缺口 A 完好 ✓"

echo
echo "=== card0.rs 里不得再出现 p.crtc_x ==="
if grep -n "p\.crtc_x\|p\.crtc_y\|p\.x = 0\|p\.y = 0" "$CARD"; then
    echo "FATAL: card0.rs 仍有遗留赋值"
    exit 1
fi
echo "  无遗留 ✓"

echo
echo "=== diff 概览 ==="
git --no-pager diff --stat -- io/drmdevice/src/drm.rs io/drmdevice/src/card0.rs
echo
git --no-pager diff -- io/drmdevice/src/drm.rs | head -50
echo
echo "REVERT_OK"
