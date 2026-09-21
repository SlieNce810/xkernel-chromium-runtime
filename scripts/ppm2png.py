#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ppm2png.py — 把 QEMU screendump 产出的 PPM 转成 PNG（零第三方依赖）

为什么需要
----------
QEMU monitor 的 `screendump` 默认输出 **PPM(P6)** 格式。PPM 不能被普通看图软件
直接打开，也不方便塞进报告和答辩 PPT，因此统一转成 PNG 归档。
本脚本只用 Python 标准库（zlib + struct）手写 PNG 编码器，Windows / Linux 都能跑，
不需要 Pillow / ImageMagick。

用法
----
    python3 scripts/ppm2png.py shot.ppm                  # 生成 shot.png
    python3 scripts/ppm2png.py screenshots/*.ppm          # 批量
    python3 scripts/ppm2png.py --out-dir png/ *.ppm       # 指定输出目录
    python3 scripts/ppm2png.py --inplace *.ppm            # 与源文件同目录
    python3 scripts/ppm2png.py --json *.ppm               # 额外输出尺寸/统计信息

退出码
------
    0 = 全部成功
    1 = 有文件转换失败
    2 = 参数错误
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import struct
import sys
import zlib


# ---------------------------------------------------------------- PPM 解析

class PpmError(Exception):
    pass


def _read_token(fh) -> bytes:
    """跳过空白与 # 注释，读取下一个 token。"""
    while True:
        ch = fh.read(1)
        if not ch:
            raise PpmError("文件在读取 header 时提前结束")
        if ch.isspace():
            continue
        if ch == b"#":
            while ch and ch != b"\n":
                ch = fh.read(1)
            continue
        break
    buf = bytearray(ch)
    while True:
        ch = fh.read(1)
        if not ch or ch.isspace():
            break
        buf += ch
    return bytes(buf)


def read_ppm(path: str):
    """返回 (width, height, rgb_bytes)。支持 P6(二进制) 与 P3(ASCII)。"""
    with open(path, "rb") as fh:
        magic = _read_token(fh)
        if magic not in (b"P6", b"P3"):
            raise PpmError(f"不支持的 PPM 魔数 {magic!r}（只支持 P6/P3）")
        width = int(_read_token(fh))
        height = int(_read_token(fh))
        maxval = int(_read_token(fh))
        if width <= 0 or height <= 0:
            raise PpmError(f"非法尺寸 {width}x{height}")
        if maxval != 255:
            raise PpmError(f"只支持 maxval=255，实际 {maxval}")

        if magic == b"P6":
            data = fh.read(width * height * 3)
            if len(data) < width * height * 3:
                raise PpmError(
                    f"像素数据不足：需要 {width*height*3} 字节，只有 {len(data)}")
            return width, height, data

        # P3: ASCII 十进制三元组
        vals = []
        while len(vals) < width * height * 3:
            tok = fh.read(1)
            if not tok:
                break
            if tok.isspace():
                continue
            if tok == b"#":
                while tok and tok != b"\n":
                    tok = fh.read(1)
                continue
            buf = bytearray(tok)
            while True:
                tok = fh.read(1)
                if not tok or tok.isspace():
                    break
                buf += tok
            try:
                vals.append(int(buf))
            except ValueError as exc:
                raise PpmError(f"P3 数值解析失败: {buf!r}") from exc
        if len(vals) < width * height * 3:
            raise PpmError("P3 数据不足")
        if maxval == 255:
            out = bytes(min(255, max(0, v)) for v in vals[: width * height * 3])
        else:
            scale = 255.0 / maxval
            out = bytes(min(255, max(0, int(v * scale)))
                        for v in vals[: width * height * 3])
        return width, height, out


# ---------------------------------------------------------------- PNG 编码

def _chunk(tag: bytes, payload: bytes) -> bytes:
    return (struct.pack(">I", len(payload)) + tag + payload
            + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))


def write_png(path: str, width: int, height: int, rgb: bytes) -> None:
    stride = width * 3
    raw = bytearray((stride + 1) * height)
    src = 0
    dst = 0
    for _ in range(height):
        raw[dst] = 0                       # filter type 0 = None
        dst += 1
        raw[dst:dst + stride] = rgb[src:src + stride]
        src += stride
        dst += stride

    png = bytearray(b"\x89PNG\r\n\x1a\n")
    png += _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += _chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += _chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)


def stats(rgb: bytes):
    """粗略统计，用于自动判断截图是不是全黑/全白（早期发现故障）。"""
    n = len(rgb) // 3
    if n == 0:
        return {}
    step = max(1, n // 20000)              # 采样即可
    total = 0
    samples = 0
    mn, mx = 255, 0
    hist = {}
    i = 0
    while i < n:
        o = i * 3
        lum = (rgb[o] * 299 + rgb[o + 1] * 587 + rgb[o + 2] * 114) // 1000
        total += lum
        samples += 1
        if lum < mn:
            mn = lum
        if lum > mx:
            mx = lum
        key = lum >> 5                      # 8 档
        hist[key] = hist.get(key, 0) + 1
        i += step
    mean = total / samples
    top = max(hist.items(), key=lambda kv: kv[1])[0]
    return {
        "mean_luma": round(mean, 2),
        "min_luma": mn,
        "max_luma": mx,
        "dominant_band": f"{top*32}-{top*32+31}",
        "likely_blank": mean < 6 or mean > 250,
    }


# ---------------------------------------------------------------- main

def convert_one(src: str, dst: str):
    w, h, rgb = read_ppm(src)
    write_png(dst, w, h, rgb)
    return {"src": src, "dst": dst, "width": w, "height": h,
            "src_bytes": os.path.getsize(src), "png_bytes": os.path.getsize(dst),
            "stats": stats(rgb)}


def main() -> int:
    ap = argparse.ArgumentParser(
        description="把 QEMU screendump 的 PPM 转成 PNG（纯标准库实现）")
    ap.add_argument("files", nargs="+", help="PPM 文件（支持 shell 通配符）")
    ap.add_argument("--out-dir", default=None, help="PNG 输出目录（默认：源文件同目录）")
    ap.add_argument("--inplace", action="store_true", help="与源文件同目录（等价于默认行为）")
    ap.add_argument("--json", action="store_true", help="输出转换报告 JSON")
    ap.add_argument("--keep", action="store_true", help="保留原始 .ppm 文件（默认保留）")
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
        base = os.path.splitext(os.path.basename(src))[0] + ".png"
        dst = os.path.join(args.out_dir, base) if args.out_dir else os.path.join(os.path.dirname(src) or ".", base)
        try:
            info = convert_one(src, dst)
            flag = "  ⚠️ 疑似空白" if info["stats"].get("likely_blank") else ""
            print("[ OK ] %-46s %dx%d  %d B -> %d B  均值亮度=%-6s%s"
                  % (os.path.basename(src), info["width"], info["height"],
                     info["src_bytes"], info["png_bytes"],
                     info["stats"].get("mean_luma"), flag))
            results.append(info)
        except (PpmError, OSError, ValueError) as exc:
            print(f"[FAIL] {src}: {exc}", file=sys.stderr)
            failed += 1

    if args.json:
        print(json.dumps(results, ensure_ascii=False, indent=2))

    print("-" * 72)
    print(f"成功 {len(results)} 个，失败 {failed} 个")
    if any(r["stats"].get("likely_blank") for r in results):
        print("提示: 有截图疑似全黑/全白 —— 通常是截得太早（Weston/Chromium 还没画）"
              "或 compositor 已退出。请结合 console.log 时间戳判断。")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
