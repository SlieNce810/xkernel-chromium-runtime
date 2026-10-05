#!/usr/bin/env bash
# p3_apply.sh — 缺口 D 修复：`drm_mode_get_plane` 结构体缺字段（uapi 契约错位，第二例）
#
# 症状（plane 探针实测）
#   [PLANE] GETPLANE rc=-1 errno=95     ← 未命中分派表
#   [PRES]  GETPLANERESOURCES rc=0      ← 同一族、编号相邻，却是通的
#   ⇒ Weston 的 plane 枚举逐个 drmModeGetPlane() 失败 ⇒ plane_list 为空
#   ⇒ "Failed to find primary plane for output Virtual-1"
#
# 根因（两处结构体对比）
#   内核 io/drmdevice/src/drm.rs:222  DrmModeGetPlane = 6×u32 + UserPtr = **32 B**
#   mainline uapi include/uapi/drm/drm_mode.h:
#       struct drm_mode_get_plane {
#               __u32 plane_id; __u32 crtc_id; __u32 fb_id;
#               __u32 crtc_x; __u32 crtc_y; __u32 x; __u32 y;     ← 内核缺这 4 个
#               __u32 possible_crtcs; __u32 gamma_size;
#               __u32 count_format_types; __u64 format_type_ptr;
#       };                                             // = 10×4 + pad4 + 8 = **48 B**
#
#   而 consts.rs 的 `iowr<T>()` 把 `size_of::<T>()` 编进 ioctl 号
#   ⇒ 内核侧期望 "nr=0xB6 size=32"，libdrm 发出 "nr=0xB6 size=48"
#   ⇒ 编码不等 ⇒ 落到分派表末尾 `_ => OperationNotSupported`（errno=95）。
#
#   ★ 这与缺口 A（属性面**编号**错位）同源 —— 都是 uapi 契约没对齐，
#     只是这次错在**结构体字段**而不是编号。两者合起来说明：
#     `io/drmdevice` 的 uapi 对齐需要做一次**系统性核对**，而不是逐个撞。
#
# 改动
#   1) drm.rs：补回 crtc_x / crtc_y / x / y 四个 u32（位置必须与 mainline 一致：
#      在 fb_id 之后、possible_crtcs 之前），使 sizeof == 48
#   2) card0.rs：handle() 里把这四个字段置 0
#      （mainline 语义是"plane 当前的位置/尺寸"；本实现的 plane 未启用时即为 0。
#       Weston 只读 plane_id / crtc_id / possible_crtcs，其余字段填 0 不影响功能，
#       但**结构体布局必须与 uapi 对齐**，否则 ioctl 号里的 size 对不上。）
#
# 幂等 + 形态断言：已修复则退出 0。
set -euo pipefail

XK="$HOME/x-kernel"
DRM="$XK/io/drmdevice/src/drm.rs"
CARD="$XK/io/drmdevice/src/card0.rs"

cd "$XK"
[ -f "$DRM" ] || { echo "FATAL: 找不到 $DRM"; exit 1; }
[ -f "$CARD" ] || { echo "FATAL: 找不到 $CARD"; exit 1; }

echo "=== 修复前状态（GetPlane 结构体）==="
grep -n -A 9 'pub struct DrmModeGetPlane {' "$DRM" || true

python3 - "$DRM" "$CARD" <<'PYEOF'
import sys

drm_path, card_path = sys.argv[1], sys.argv[2]

OLD_STRUCT = """pub struct DrmModeGetPlane {
    pub plane_id: u32,
    pub crtc_id: u32,
    pub fb_id: u32,
    pub possible_crtcs: u32,
    pub gamma_size: u32,
    pub count_format_types: u32,
    pub format_type_ptr: UserPtr<u32>,
}"""

NEW_STRUCT = """pub struct DrmModeGetPlane {
    pub plane_id: u32,
    pub crtc_id: u32,
    pub fb_id: u32,
    /* mainline uapi 在这四个字段之后才是 possible_crtcs ——
     * 少了它们，sizeof 会从 48 变成 32，而 consts.rs 的 iowr<T>()
     * 会把 size 编进 ioctl 号 ⇒ 与 libdrm 发出的编码不等 ⇒ errno=95。
     * 语义：plane 当前的位置/尺寸；本实现的 plane 未启用时置 0。 */
    pub crtc_x: u32,
    pub crtc_y: u32,
    pub x: u32,
    pub y: u32,
    pub possible_crtcs: u32,
    pub gamma_size: u32,
    pub count_format_types: u32,
    pub format_type_ptr: UserPtr<u32>,
}"""

# ---- 1) drm.rs：补字段 ----
with open(drm_path, encoding="utf-8") as f:
    s = f.read()
if OLD_STRUCT in s:
    s = s.replace(OLD_STRUCT, NEW_STRUCT, 1)
    with open(drm_path, "w", encoding="utf-8") as f:
        f.write(s)
    print("drm.rs:  已补 crtc_x/crtc_y/x/y")
elif "pub crtc_x: u32," in s and "pub struct DrmModeGetPlane {" in s:
    print("drm.rs:  已是修复形态")
else:
    print("FATAL: drm.rs 中未找到预期的 DrmModeGetPlane 定义（结构可能已变）")
    sys.exit(1)

# ---- 2) card0.rs：handle() 里把新字段置 0 ----
with open(card_path, encoding="utf-8") as f:
    c = f.read()

OLD_HANDLE = """        p.crtc_id = CRTC_ID;
        p.fb_id = 0;
        p.possible_crtcs = 1;"""

NEW_HANDLE = """        p.crtc_id = CRTC_ID;
        p.fb_id = 0;
        /* 这四个字段是 mainline uapi 的一部分（结构体布局必须完整），
         * 语义为 plane 当前的裁剪/位置；未启用时全 0。 */
        p.crtc_x = 0;
        p.crtc_y = 0;
        p.x = 0;
        p.y = 0;
        p.possible_crtcs = 1;"""

if OLD_HANDLE in c:
    c = c.replace(OLD_HANDLE, NEW_HANDLE, 1)
    with open(card_path, "w", encoding="utf-8") as f:
        f.write(c)
    print("card0.rs: 已置 crtc_x/crtc_y/x/y = 0")
elif "p.crtc_x = 0;" in c:
    print("card0.rs: 已是修复形态")
else:
    print("FATAL: card0.rs 中未找到预期的 GetPlane handle 片段")
    sys.exit(1)
PYEOF

echo
echo "=== 修复后状态 ==="
grep -n -A 13 'pub struct DrmModeGetPlane {' "$DRM"
echo
echo "=== diff ==="
git --no-pager diff --stat -- io/drmdevice/src/drm.rs io/drmdevice/src/card0.rs
git --no-pager diff -- io/drmdevice/src/drm.rs io/drmdevice/src/card0.rs

echo
echo "=== 断言：结构体字段齐备且顺序正确 ==="
python3 - "$DRM" <<'PYEOF'
import sys, re
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"pub struct DrmModeGetPlane \{(.*?)\}", src, re.S)
assert m, "找不到 DrmModeGetPlane"
body = m.group(1)
order = [l.strip().split(":")[0].replace("pub ", "")
         for l in body.strip().splitlines()
         if l.strip().startswith("pub ")]
want = ["plane_id", "crtc_id", "fb_id", "crtc_x", "crtc_y", "x", "y",
        "possible_crtcs", "gamma_size", "count_format_types", "format_type_ptr"]
if order != want:
    print("FATAL: 字段顺序不符 mainline：")
    print("   实际:", order)
    print("   期望:", want)
    sys.exit(1)
print("字段顺序与 mainline 逐字一致：")
print("   ", " ".join(order))
print("预期 sizeof = 10×4 + pad4 + 8 = 48 字节（由编译器保证）")
PYEOF

echo "APPLY_OK"
