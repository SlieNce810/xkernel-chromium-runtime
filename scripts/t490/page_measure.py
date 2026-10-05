#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""官方测试页几何测量器 —— 新判据常量的取值工具。

为什么需要它
------------
`ppm_assert.py --profile official-*` 里的每个阈值都必须来自**屏上实测**，不能从
CSS 反推（字体回退、DPI、圆角抗锯齿都会让"应该多宽"与"实际多少像素"不一致）。
这个脚本就是"实测"那一步：对手里的参考 PPM 输出色块 bbox / 行带结构 / 颜色计数。

什么时候用
----------
1. 组委会更新页面集（v1.0 → v1.1）→ 重新渲染参考图 → 跑本工具 → 更新常量；
2. 判据某项失败时，先用它看"屏上到底是什么"，再决定是渲染问题还是阈值问题；
3. 新增页面 / 新增断言目标时，先拿它验证"这个特征在两种画幅下都可测"。

用法
----
    python3 scripts/t490/page_measure.py <ref.ppm> [more.ppm ...]
    python3 scripts/t490/page_measure.py --bands ref-*.ppm      # 只做行带扫描
    python3 scripts/t490/page_measure.py --colors ref-*.ppm     # 只做颜色块测量

复用 `ppm_assert.py` 里**已被三重对照验证过**的原语（interval_mask / dominant_bbox /
longest_run），不另写检测逻辑 —— 免得"测量工具"和"判据"对同一特征给出两套口径。
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ppm_assert as pa            # noqa: E402

# 官方三页里出现的全部"判据可能用得上"的颜色（区间略宽于纯色，容忍抗锯齿边缘）
COLORS = {
    "banner #17456b":      ((10, 45), (50, 90), (85, 130)),
    "blk-red #e5534b":     ((215, 245), (70, 100), (60, 90)),
    "blk-green #2da44e":   ((30, 65), (150, 180), (60, 95)),
    "blk-yellow #bf8700":  ((175, 210), (120, 150), (0, 15)),
    "blk-purple #8250df":  ((115, 145), (65, 95), (205, 240)),
    "pass-text #1a7f37":   ((15, 40), (110, 145), (40, 75)),
    "fail-text #c93c37":   ((185, 215), (45, 75), (40, 70)),
    "pass-bg #dafbe1":     ((205, 232), (240, 255), (215, 238)),
    "fail-bg #ffebe9":     ((244, 255), (228, 245), (225, 242)),
    "rule #c7cdd4":        ((190, 214), (196, 218), (203, 226)),
    "box #dbeafe":         ((212, 226), (228, 240), (248, 255)),
    "zebra #f0f3f6":       ((232, 248), (235, 250), (238, 252)),
    "page-bg #f4f6f8":     ((238, 250), (240, 252), (242, 254)),
    "text-dark":           ((0, 100), (0, 100), (0, 100)),
}


def do_colors(path):
    img = pa.read_ppm(path)
    ch = img.channels()
    W, H = img.width, img.height
    print(f"\n{'=' * 78}\n{os.path.basename(path)}  {W}x{H}  · 颜色块\n{'=' * 78}")
    print(f"{'颜色':22s} {'像素数':>9s}  {'bbox (x0,y0,x1,y1)':30s} {'w×h':>11s}  填充率")
    for name, rng in COLORS.items():
        mask = pa.interval_mask(ch, *rng)
        cnt = mask.count(1)
        if not cnt:
            print(f"{name:22s} {0:9d}  -")
            continue
        b = pa.mask_blob(mask, W, H)
        fill = cnt / max(1, b.w * b.h)
        print(f"{name:22s} {cnt:9d}  {str((b.x0, b.y0, b.x1, b.y1)):30s} "
              f"{b.w:5d}×{b.h:<5d}  {fill:5.2f}")


def do_bands(path, min_frac=0.05):
    img = pa.read_ppm(path)
    ch = img.channels()
    W, H = img.width, img.height
    print(f"\n{'=' * 84}\n{os.path.basename(path)}  {W}x{H}  · 行带\n{'=' * 84}")
    for name, rng in COLORS.items():
        mask = pa.interval_mask(ch, *rng)
        total = mask.count(1)
        if total < 50:
            print(f"-- {name:22s} 像素 {total:6d}（太少，跳过）")
            continue
        bands = pa.row_bands(mask, W, H, max(8, int(min_frac * W)))
        print(f"-- {name:22s} 像素 {total:6d}  行带 {len(bands)} 条")
        for y0, y1, peak in bands[:14]:
            x0, x1 = pa.mask_x_extent(mask, W, y0, y1)
            print(f"     y {y0:4d}..{y1:<4d} (h={y1 - y0 + 1:3d})  "
                  f"x {x0:4d}..{x1:<4d} (w={max(0, x1 - x0 + 1):4d})  行内峰值={peak}")


def main() -> int:
    ap = argparse.ArgumentParser(description="官方测试页几何测量（判据常量取值工具）")
    ap.add_argument("files", nargs="+", help="参考 PPM（判据只吃 P6）")
    ap.add_argument("--colors", action="store_true", help="只做颜色块测量（整体 bbox）")
    ap.add_argument("--bands", action="store_true", help="只做行带扫描")
    ap.add_argument("--min-frac", type=float, default=0.05,
                    help="行带判定：行内命中数 ≥ 该比例×屏宽（默认 0.05）")
    args = ap.parse_args()

    both = not (args.colors or args.bands)
    rc = 0
    for path in args.files:
        if not os.path.isfile(path):
            print(f"!! 不是文件: {path}", file=sys.stderr)
            rc = 1
            continue
        if both or args.colors:
            do_colors(path)
        if both or args.bands:
            do_bands(path, args.min_frac)
    return rc


if __name__ == "__main__":
    sys.exit(main())
