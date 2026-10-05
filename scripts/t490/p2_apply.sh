#!/usr/bin/env bash
# p2_apply.sh — 缺口 A 修复（P2 补丁）：KMS 属性面 ioctl 编号对齐 Linux uapi
#
# 改什么（唯一改动点：io/drmdevice/src/card0.rs）
#   DrmModeGetProperty 的 CMD: 0xAA → 0xA8   (mainline DRM_IOCTL_MODE_GETPROPERTY, 64 B)
#   DrmModeGetBlob     的 CMD: 0xAC → 0xAA   (mainline DRM_IOCTL_MODE_GETPROPBLOB,   16 B)
#
# 为什么（report/28 §4.1）
#   io/drmdevice/src/consts.rs:17 的 `iowr<T>()` 把 `size_of::<T>()` 编进 ioctl 号，
#   与 Linux `_IOWR` 语义一致 —— 但两个属性面处理器的编号与 mainline 错位，
#   于是 libdrm / Weston / Xorg 发来的属性查询落不到任何 match 分支，
#   最终命中分派表末尾 `_ => Err(kvfs::VfsError::OperationNotSupported)`（errno=95）。
#   这正是既有缺口清单第 2 条 `WESTON_DISABLE_ATOMIC=1` 的根因。
#
# 安全性前提（本脚本运行前已逐条核对，见 report/29）
#   - 0xA8 在 x-kernel 全仓未被任何 ioctl 占用（扫描 io/ core/ drivers/ 全部 *.rs）
#   - 0xAC 在 mainline 未分配；迁走后不产生新的错位
#   - 结构体大小与 mainline 逐字段一致：DrmModeGetProperty = 64 B、DrmModeGetBlob = 16 B
#     （repr(C) 对齐已核对，见 drm.rs:251 / drm.rs:327）
#
# 幂等 + 形态断言：已修复则退出 0；替换前后都打印实际行，供人工复核。
set -euo pipefail

XK="$HOME/x-kernel"
F="$XK/io/drmdevice/src/card0.rs"

cd "$XK"
[ -f "$F" ] || { echo "FATAL: 找不到 $F"; exit 1; }

echo "=== 修复前状态 ==="
grep -n 'iowr::<DrmModeGetProperty>(DRM_TYPE, 0x' "$F" || true
grep -n 'iowr::<DrmModeGetBlob>(DRM_TYPE, 0x' "$F" || true

python3 - "$F" <<'PYEOF'
import sys

p = sys.argv[1]
with open(p, encoding="utf-8") as f:
    s = f.read()

# 先 blob 后 property：两处替换串都带类型名，顺序不影响正确性
subs = [
    ("iowr::<DrmModeGetBlob>(DRM_TYPE, 0xAC)",
     "iowr::<DrmModeGetBlob>(DRM_TYPE, 0xAA)"),
    ("iowr::<DrmModeGetProperty>(DRM_TYPE, 0xAA)",
     "iowr::<DrmModeGetProperty>(DRM_TYPE, 0xA8)"),
]

changed = 0
for old, new in subs:
    if old in s:
        if s.count(old) != 1:
            print("FATAL: 旧形态出现 %d 次（应为 1 次）: %s" % (s.count(old), old))
            sys.exit(1)
        s = s.replace(old, new, 1)
        changed += 1
        print("  replaced: %s" % old)
    elif new in s:
        print("  already:  %s" % new)
    else:
        print("FATAL: 既无旧形态也无新形态（源码结构已变？）: %s" % old)
        sys.exit(1)

with open(p, "w", encoding="utf-8") as f:
    f.write(s)
print("changed_lines=%d" % changed)
PYEOF

echo "=== 修复后状态（应为 0xA8 / 0xAA）==="
grep -n 'iowr::<DrmModeGetProperty>(DRM_TYPE, 0x' "$F"
grep -n 'iowr::<DrmModeGetBlob>(DRM_TYPE, 0x' "$F"

echo "=== diff（供复核）==="
git --no-pager diff --stat -- io/drmdevice/src/card0.rs
git --no-pager diff -- io/drmdevice/src/card0.rs

echo "=== 断言：属性面新编号与 mainline 一致 ==="
grep -q 'iowr::<DrmModeGetProperty>(DRM_TYPE, 0xA8)' "$F" \
    || { echo "FATAL: property 未到 0xA8"; exit 1; }
grep -q 'iowr::<DrmModeGetBlob>(DRM_TYPE, 0xAA)' "$F" \
    || { echo "FATAL: blob 未到 0xAA"; exit 1; }
echo "APPLY_OK"
