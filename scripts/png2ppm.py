#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
png2ppm.py — 把 PNG 转成 PPM(P6)（零第三方依赖）

为什么需要
----------
判据工具 `scripts/t490/ppm_assert.py` 只吃 **PPM(P6)**（那是 QEMU monitor
`screendump` 的原生格式，见 `report/20`）。而"页面应该长什么样"的参照图是用
**本机无头 Chrome** 渲染出来的 PNG。要把两侧放进同一个判据里比对，就必须有一个
PNG → PPM 的方向。

同时它也补上了流程里的一个缺口：此前只有 `scripts/ppm2png.py`（PPM→PNG，为了
报告/PPT 好看），反过来那一半一直靠 ImageMagick/Pillow 手工凑。

实现说明
--------
只用标准库（zlib + struct）手写 PNG 解码器：解 IDAT → 逐行反滤波（filter 0–4）。
支持 8 bit 的灰度/灰度+Alpha/RGB/RGBA，也就是 Chrome、QEMU 转出的常见形态。
**明确不支持**调色板(indexed)、16 bit、隔行(Adam7) —— 遇到就直接报错而不是
猜着解，避免"图看着对、像素其实错位"这类最贵的假阳性。

用法
----
    python3 scripts/png2ppm.py shot.png                 # 生成 shot.ppm
    python3 scripts/png2ppm.py shots/*.png              # 批量
    python3 scripts/png2ppm.py --out-dir ppm/ *.png     # 指定输出目录
    python3 scripts/png2ppm.py --json *.png             # 额外输出尺寸/统计信息

退出码
------
    0 = 全部成功
    1 = 有文件转换失败
    2 = 参数错误
"""

import argparse
import glob
import json
import os
import struct
import sys
import zlib

PNG_SIG = b"\x89PNG\r\n\x1a\n"
# 每像素字节数：color_type -> bpp（仅 8 bit）
BPP = {0: 1, 2: 3, 4: 2, 6: 4}


class PngError(Exception):
    pass


# ---------------------------------------------------------------- PNG 解析

def read_png(path: str):
    """返回 (width, height, rgb_bytes)。只支持 8 bit 非隔行。"""
    with open(path, "rb") as fh:
        blob = fh.read()

    if blob[:8] != PNG_SIG:
        raise PngError("不是 PNG 文件（signature 不匹配）")

    pos = 8
    width = height = None
    bit_depth = color_type = interlace = None
    idat = bytearray()
    while pos + 8 <= len(blob):
        (length,) = struct.unpack(">I", blob[pos:pos + 4])
        tag = blob[pos + 4:pos + 8]
        payload = blob[pos + 8:pos + 8 + length]
        pos += 12 + length                       # 4(len)+4(tag)+len+4(crc)
        if tag == b"IHDR":
            (width, height, bit_depth, color_type,
             _comp, _filt, interlace) = struct.unpack(">IIBBBBB", payload)
        elif tag == b"IDAT":
            idat += payload
        elif tag == b"IEND":
            break

    if width is None:
        raise PngError("缺少 IHDR")
    if bit_depth != 8:
        raise PngError(f"只支持 8 bit，实际 {bit_depth} bit")
    if color_type not in BPP:
        raise PngError(f"不支持的 color_type={color_type}"
                       "（支持 0=灰度 2=RGB 4=灰度+A 6=RGBA；调色板/16bit 请先转换）")
    if interlace != 0:
        raise PngError("不支持隔行(Adam7) PNG")
    if not idat:
        raise PngError("缺少 IDAT 数据")

    bpp = BPP[color_type]
    stride = width * bpp
    raw = zlib.decompress(bytes(idat))
    need = (stride + 1) * height
    if len(raw) < need:
        raise PngError(f"解压后数据不足：需要 {need} 字节，只有 {len(raw)}")

    # ---- 逐行反滤波 ----
    out = bytearray(stride * height)
    prev = bytearray(stride)                    # 上一行（首行视为全 0）
    src = 0
    dst = 0
    for _ in range(height):
        ft = raw[src]
        src += 1
        line = bytearray(raw[src:src + stride])
        src += stride
        if ft == 0:
            pass
        elif ft == 1:                           # Sub
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ft == 2:                           # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:                           # Average
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ft == 4:                           # Paeth
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        else:
            raise PngError(f"未知 filter type {ft}（第 {dst // stride} 行）")
        out[dst:dst + stride] = line
        prev = line
        dst += stride

    # ---- 归一化为 RGB ----
    if color_type == 2:
        rgb = bytes(out)
    else:
        rgb = bytearray(width * height * 3)
        step = bpp
        j = 0
        for i in range(0, len(out), step):
            if color_type == 0:
                v = out[i]
                rgb[j] = rgb[j + 1] = rgb[j + 2] = v
            elif color_type == 4:
                v = out[i]
                rgb[j] = rgb[j + 1] = rgb[j + 2] = v
            else:                               # 6 = RGBA
                rgb[j] = out[i]
                rgb[j + 1] = out[i + 1]
                rgb[j + 2] = out[i + 2]
            j += 3
        rgb = bytes(rgb)
        # 说明：PNG 是"非预乘"alpha，此处**不做**合成；带 alpha 的图会有透明区被
        # 当成原始颜色。判据场景里双方都是不透明截图，不需要合成；真遇到透明图，
        # 报出来的像素值会与实际观感不同 —— 遇到就换工具，别在这上面猜。
    return width, height, rgb


def write_ppm(path: str, width: int, height: int, rgb: bytes) -> None:
    with open(path, "wb") as fh:
        fh.write(b"P6\n%d %d\n255\n" % (width, height))
        fh.write(rgb)


def stats(rgb: bytes):
    """粗略统计，用于自动判断截图是不是全黑/全白（与 ppm2png.py 同口径）。"""
    n = len(rgb) // 3
    if n == 0:
        return {}
    step = max(1, n // 20000)
    total = samples = 0
    mn, mx = 255, 0
    hist = {}
    for i in range(0, n, step):
        o = i * 3
        lum = (rgb[o] * 299 + rgb[o + 1] * 587 + rgb[o + 2] * 114) // 1000
        total += lum
        samples += 1
        mn = min(mn, lum)
        mx = max(mx, lum)
        hist[lum >> 5] = hist.get(lum >> 5, 0) + 1
    top = max(hist.items(), key=lambda kv: kv[1])[0]
    mean = total / samples
    return {"mean_luma": round(mean, 2), "min_luma": mn, "max_luma": mx,
            "dominant_band": f"{top*32}-{top*32+31}",
            "likely_blank": mean < 6 or mean > 250}


# ---------------------------------------------------------------- main

def convert_one(src: str, dst: str):
    w, h, rgb = read_png(src)
    write_ppm(dst, w, h, rgb)
    return {"src": src, "dst": dst, "width": w, "height": h,
            "png_bytes": os.path.getsize(src), "ppm_bytes": os.path.getsize(dst),
            "stats": stats(rgb)}


def main() -> int:
    ap = argparse.ArgumentParser(
        description="把 PNG 转成 PPM(P6)，供 ppm_assert.py 判据使用（纯标准库实现）")
    ap.add_argument("files", nargs="+", help="PNG 文件（支持 shell 通配符）")
    ap.add_argument("--out-dir", default=None, help="PPM 输出目录（默认：源文件同目录）")
    ap.add_argument("--json", action="store_true", help="输出转换报告 JSON")
    args = ap.parse_args()

    expanded: list[str] = []
    for pat in args.files:
        hits = glob.glob(pat)
        expanded.extend(hits if hits else [pat])
    if not expanded:
        print("错误: 没有匹配到任何文件", file=sys.stderr)
        return 2

    if args.out_dir:
        os.makedirs(args.out_dir, exist_ok=True)

    results, failed = [], 0
    for src in expanded:
        if not os.path.isfile(src):
            print(f"[SKIP] 不是文件: {src}", file=sys.stderr)
            failed += 1
            continue
        base = os.path.splitext(os.path.basename(src))[0] + ".ppm"
        dst = (os.path.join(args.out_dir, base) if args.out_dir
               else os.path.join(os.path.dirname(src) or ".", base))
        try:
            info = convert_one(src, dst)
            flag = "  ⚠️ 疑似空白" if info["stats"].get("likely_blank") else ""
            print("[ OK ] %-46s %dx%d  %d B -> %d B  均值亮度=%-6s%s"
                  % (os.path.basename(src), info["width"], info["height"],
                     info["png_bytes"], info["ppm_bytes"],
                     info["stats"].get("mean_luma"), flag))
            results.append(info)
        except (PngError, OSError, ValueError, zlib.error) as exc:
            print(f"[FAIL] {src}: {exc}", file=sys.stderr)
            failed += 1

    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=2))
    print("-" * 72)
    print(f"成功 {len(results)} 个，失败 {failed} 个")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
