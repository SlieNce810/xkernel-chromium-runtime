#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""QEMU monitor `screendump` 产出的 PPM 自动判据。

为什么需要它
------------
赛题第七节(一)3 规定：功能证据**只认 QEMU monitor 的 `screendump`**。
而"截图上能看到页面"这件事，靠人眼判读有三个问题：
  1. 无法在批量轮次里自动判定，轮次多了必然漏看；
  2. 主观描述（"看起来是对的"）不是可复核的证据；
  3. 本项目历史上出现过"证据被截断 / 被误读"的伪证据事故（见 report/19 §1）。

本工具把"渲染正确"翻译成一组**可复核的像素谓词**，输入是原始 PPM（不经任何
转码，避免中间环节引入失真），输出是：
  - 每个特征是否检出 + 检出位置 bbox + 像素计数 → 可人工复核数字
  - `--strict` 下全绿才 exit 0 → 可作为轮次门禁
  - `--json` 落盘 → 进证据目录，供后续比对

设计原则
--------
1. **只做特征检测，绝不硬编码绝对坐标。** guest 内没有窗口管理器保证窗口位置/
   尺寸，devicePixelRatio 也可能不是 1；硬编码 ROI 会在不同轮次间产生假阳性。
2. **必须是 C 级速度。** 一张 1280x800 图有 102 万像素，一轮要判 10 张。
   纯 Python 逐像素循环会到分钟级，因此全部谓词走
   `bytes.translate` + 大整数按位运算（见 `interval_mask` / `xor_count`），
   定位走 `bytes.find/rfind`。单图判定目标 < 1 s。

两个模式
--------
1) 单图模式（判页面渲染是否正确）
       ppm_assert.py shot.ppm --json out.json [--strict]
       ppm_assert.py shot.ppm --profile official-index --strict      # 官方三页套
   `--profile legacy`（默认）判自建页 v1.1（scripts/testpage/local-check.html）；
   `--profile official-index|official-layout|official-interaction` 判组委会三页套，
   常量全部来自参考图实测（scripts/testpage/reference/），详见下文"官方测试页"一节。

2) 差图模式（判 renderer 是否还活着 / JS 是否还在跑）
       ppm_assert.py a.ppm --diff b.ppm --min-changed 200
   legacy 页有每秒自增的帧计数器 ⇒ 两个不同时刻的截图必然不同。
   同时报告变化像素的 bbox：bbox 小 = 心跳在跳；bbox 铺满全屏 = 整屏重绘 / 闪屏。
   这是"renderer 存活 ≥60 s"在没有 OCR 时的**硬证据**。
   ⚠️ 官方 index.html 是**无脚本静态页**（页面自己写明"无时间依赖，截图结果应逐队
   一致"），对它做双帧差分必然 0 差异 —— 那不是 renderer 死了。官方页的 JS 证据
   改用**结论条颜色**（见 `analyze_official` 的 verdict 判据）。

依赖：仅 Python 3 标准库（不需要 Pillow）。要求 QEMU 写出 P6 / maxval=255。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass, field


# --------------------------------------------------------------------------- #
# PPM 读取
# --------------------------------------------------------------------------- #

class PPMError(Exception):
    pass


@dataclass
class PPM:
    """P6 二进制 PPM。`raster` 为紧密排列的 RGB 三元组字节。"""

    width: int
    height: int
    maxval: int
    raster: bytes
    header_bytes: int
    path: str

    # -- 通道视图（C 级切片，各 1 字节/像素） ------------------------------- #
    def channels(self) -> tuple[bytes, bytes, bytes]:
        return self.raster[0::3], self.raster[1::3], self.raster[2::3]


def read_ppm(path: str) -> PPM:
    with open(path, "rb") as fh:
        data = fh.read()
    if not data.startswith(b"P6"):
        raise PPMError(f"{path}: 不是 P6 PPM（前 8 字节 {data[:8]!r}）")

    # header: magic / width / height / maxval；允许 '#' 注释与任意空白
    pos = 2
    tokens: list[bytes] = []
    while len(tokens) < 3:
        while pos < len(data) and data[pos:pos + 1].isspace():
            pos += 1
        if pos < len(data) and data[pos:pos + 1] == b"#":
            while pos < len(data) and data[pos:pos + 1] not in (b"\n", b"\r"):
                pos += 1
            continue
        start = pos
        while pos < len(data) and not data[pos:pos + 1].isspace():
            pos += 1
        if start == pos:
            raise PPMError(f"{path}: header 解析卡住（pos={pos}）")
        tokens.append(data[start:pos])
    pos += 1  # P6 规范：maxval 后恰好一个空白字符

    try:
        width, height, maxval = (int(t) for t in tokens)
    except ValueError as exc:
        raise PPMError(f"{path}: header 数值非法 {tokens!r}") from exc
    if maxval != 255:
        raise PPMError(f"{path}: 只支持 maxval=255，实际 {maxval}")

    need = width * height * 3
    raster = data[pos:pos + need]
    if len(raster) < need:
        raise PPMError(
            f"{path}: 光栅数据不足，期望 {need} B，只有 {len(raster)} B"
            f"（文件共 {len(data)} B，header {pos} B）"
            "——QEMU 被 Ctrl-A c 打断或 screendump 未写完时会这样")
    return PPM(width, height, maxval, raster, pos, path)


# --------------------------------------------------------------------------- #
# 掩码原语：bytes.translate + 大整数按位运算（全部 C 级）
# --------------------------------------------------------------------------- #

_TABLES: dict[tuple[int, int], bytes] = {}


def _interval_table(lo: int, hi: int) -> bytes:
    """256 字节布尔表：v ∈ [lo,hi] → 0x01，否则 0x00。"""
    key = (lo, hi)
    t = _TABLES.get(key)
    if t is None:
        t = bytes(1 if lo <= v <= hi else 0 for v in range(256))
        _TABLES[key] = t
    return t


def interval_mask(ch: tuple[bytes, bytes, bytes], rng_r, rng_g, rng_b) -> bytes:
    """三个通道各自的取值区间同时成立 → 该像素掩码为 0x01。

    用大整数按位与替代逐像素循环：1 MB 的掩码运算耗时在毫秒级。
    """
    rm = ch[0].translate(_interval_table(*rng_r))
    gm = ch[1].translate(_interval_table(*rng_g))
    bm = ch[2].translate(_interval_table(*rng_b))
    n = len(rm)
    if n == 0:
        return b""
    mi = (int.from_bytes(rm, "big") & int.from_bytes(gm, "big")
          & int.from_bytes(bm, "big"))
    return mi.to_bytes(n, "big")


def longest_run(mask: bytes) -> int:
    """掩码中 0x01 的最长连续长度（C 级 split）。"""
    if not mask:
        return 0
    return max(len(seg) for seg in mask.split(b"\x00"))


@dataclass
class Blob:
    count: int = 0
    x0: int = 1 << 30
    y0: int = 1 << 30
    x1: int = -1
    y1: int = -1

    @property
    def valid(self) -> bool:
        return self.x1 >= self.x0 and self.y1 >= self.y0 and self.count > 0

    @property
    def w(self) -> int:
        return self.x1 - self.x0 + 1

    @property
    def h(self) -> int:
        return self.y1 - self.y0 + 1

    def as_dict(self):
        if not self.valid:
            return None
        return {"count": self.count, "bbox": [self.x0, self.y0, self.x1, self.y1],
                "w": self.w, "h": self.h}


def mask_blob(mask: bytes, w: int, h: int) -> Blob:
    """整体的并集 bbox + 计数（不做连通域划分）。

    ⚠️ 只适合**差图**场景：那里"两图差异散布很远"本身就是有意义的信息。
    单图特征检测请用 `dominant_bbox`——真实截图上会有 ClearType 次像素抗锯齿
    之类的零星彩色像素，它们会把并集 bbox 撑到满屏（实测 #c8102e 的 bbox
    被拉成 0,0,1279,799，直接毁掉形状判据）。
    """
    b = Blob(count=mask.count(1))
    if b.count == 0:
        return b
    for y in range(h):
        row = mask[y * w:(y + 1) * w]
        i = row.find(1)
        if i < 0:
            continue
        if y < b.y0:
            b.y0 = y
        b.y1 = y
        if i < b.x0:
            b.x0 = i
        j = row.rfind(1)
        if j > b.x1:
            b.x1 = j
    return b


def dominant_bbox(mask: bytes, w: int, h: int,
                  min_frac: float = 0.25, min_px: int = 8) -> Blob:
    """最大"主色块"的 bbox：先按行投影取最长高位段，再在该段内按列投影取最长段。

    对实心矩形（banner / 三原色块）会精确还原矩形；对零星噪声像素免疫。
    """
    row_counts = [0] * h
    total = 0
    for y in range(h):
        c = mask[y * w:(y + 1) * w].count(1)
        if c:
            row_counts[y] = c
            total += c
    if total == 0:
        return Blob()

    peak = max(row_counts)
    thr = max(min_px, int(peak * min_frac))

    best_len, y0, y1 = 0, -1, -1
    i = 0
    while i < h:
        if row_counts[i] >= thr:
            j = i
            while j + 1 < h and row_counts[j + 1] >= thr:
                j += 1
            if j - i + 1 > best_len:
                best_len, y0, y1 = j - i + 1, i, j
            i = j + 1
        else:
            i += 1
    if best_len == 0:
        return Blob()

    col_counts = [0] * w
    for y in range(y0, y1 + 1):
        row = mask[y * w:(y + 1) * w]
        k = row.find(1)
        while k >= 0:
            col_counts[k] += 1
            k = row.find(1, k + 1)

    peak_c = max(col_counts)
    thr_c = max(min_px, int(peak_c * min_frac))
    bx_len, x0, x1 = 0, -1, -1
    i = 0
    while i < w:
        if col_counts[i] >= thr_c:
            j = i
            while j + 1 < w and col_counts[j + 1] >= thr_c:
                j += 1
            if j - i + 1 > bx_len:
                bx_len, x0, x1 = j - i + 1, i, j
            i = j + 1
        else:
            i += 1
    if bx_len == 0:
        return Blob()

    return Blob(count=total, x0=x0, y0=y0, x1=x1, y1=y1)


# --------------------------------------------------------------------------- #
# 页面特征几何常量（来自 scripts/testpage/local-check.html 的 CSS，
# 单位是 CSS px；仅用于**形状合理性判断**，绝不作为定位依据）
# --------------------------------------------------------------------------- #

BANNER_C8102E = (150, 80, 80)          # r>=150, g<=80, b<=80
# 纯色块必须比 banner 更严：banner 底色 #c8102e 的 (r=200,g=16,b=46) 也满足
# "r≥200,g≤60,b≤60"，若用同一谓词，dominant_bbox 会选中 1280x64 的 banner
# 而不是 120x72 的红色块（正向对照实测 red ✗，bbox 被 banner 顶掉）。
PURE_RED = (200, 30, 30)
PURE_GREEN = (60, 200, 30)             # 顺序是 (r,g,b) 的上下界
PURE_BLUE = (60, 30, 200)
# 色块是 CSS 固定尺寸（.sw = 120x72），**不随屏宽变**，所以这里保持绝对像素带，
# 只把上界放宽以容忍 DPR>1（0.32*W*0.24*H 之类的相对化会造成量纲错配）。
SWATCH_BOX = dict(w_lo=80, w_hi=300, h_lo=40, h_hi=180, aspect_max=3.0)

# "暗"的定义要容得下表格边框的 #444444(=68) 而不是只认纯黑：
# 页面里 .checker td.a / .footer / 各边框都是 #111111，但 table.data 的边框是
# 1px #444444（=68）。阈值 60 会把表格线全部漏掉（正向对照实测 h_lines=0）。
DARK_MAX = 100

# ---- 相对化阈值 ---------------------------------------------------------- #
# 实测历史 351 张 screendump 里有两种画幅：640x480 与 1280x800。banner 与
# table.data 是**流体宽度**（随窗口宽变），必须按屏宽取比例；而色块/棋盘/心跳盒
# 是 CSS 固定尺寸，不能相对化。
BANNER_W_FRAC = 0.35        # banner 宽 ≥ 0.35*W（另设绝对下限 240）
BANNER_W_MIN = 240
BANNER_H_LO_FRAC = 0.04     # 64/800=0.08、64/480=0.13 都落带内
BANNER_H_HI_FRAC = 0.30
TABLE_HLINE_FRAC = 0.28     # 表格横线 ≥ 0.28*W（另设绝对下限 160）
TABLE_HLINE_MIN = 160
TABLE_VLINE_MIN = 40        # 表高由字号行数决定，与屏高无关，保留绝对值

# 整页高约 1080 px（1280 宽时）。画幅不够高时，③表格 ②棋盘 会落在视野之外，
# "检不到"不等于"没渲染"。低于此高度就把这些谓词降级为 INFO（只报告不卡关）。
FULL_PAGE_MIN_H = 700


@dataclass
class Check:
    name: str
    passed: bool
    detail: str
    data: dict = field(default_factory=dict)
    # core     : 首屏即可判（banner / 三色块 / JS 绿字）—— 任何画幅下都是硬判据
    # viewport : 只有画幅足够高（H ≥ FULL_PAGE_MIN_H）才在视野内 —— 否则降级为 INFO
    # info     : 永远只作参考，无鉴别力（实测非白占比、原色占比都会被纯色桌面/ banner 骗过）
    # input    : 需要真实输入（点击/键入）才可能出现 —— 未声明 --expect-input 时降级为 INFO。
    #            官方 interaction.html 的结论条就是这一类（实测：点击后绿底 60056 px，
    #            不点击 36 px），把它当 core 会在"只截图不输入"的轮次里造成假阴性。
    group: str = "core"
    # 该判据在**多高的画幅**下才可能落在视野内。0 = 用 --full-page-min-height。
    # 为什么需要它：官方 layout.html 的结论条在整页 y≈1450 处，1280x800 的
    # screendump 里**根本看不到**（实测绿字只有 30 px 的噪声）—— 用统一的 700px
    # 阈值会把"取景不够"误判成"自检没通过"。
    min_h: int = 0

    def as_dict(self):
        return {"check": self.name, "pass": self.passed, "group": self.group,
                "detail": self.detail, **self.data}


# --------------------------------------------------------------------------- #
# 各特征检测
# --------------------------------------------------------------------------- #

def detect_non_white(img: PPM, ch) -> tuple[float, int]:
    """非白像素占比。白定义：三通道均 ≥231（容忍 JPEG 类噪声，PPM 无压缩）。"""
    white = interval_mask(ch, (231, 255), (231, 255), (231, 255))
    wc = white.count(1)
    total = img.width * img.height
    return (total - wc) / total, total - wc


def detect_banner(img: PPM, ch) -> Blob:
    return dominant_bbox(interval_mask(ch, (150, 255), (0, 80), (0, 80)),
                         img.width, img.height)


def detect_swatch(img: PPM, ch, which: str) -> Blob:
    if which == "red":
        m = interval_mask(ch, (200, 255), (0, 30), (0, 30))
    elif which == "green":
        m = interval_mask(ch, (0, 60), (200, 255), (0, 30))
    else:
        m = interval_mask(ch, (0, 60), (0, 30), (200, 255))
    return dominant_bbox(m, img.width, img.height)


def _swatch_shaped(b: Blob) -> bool:
    return (b.valid and SWATCH_BOX["w_lo"] <= b.w <= SWATCH_BOX["w_hi"]
            and SWATCH_BOX["h_lo"] <= b.h <= SWATCH_BOX["h_hi"]
            and round(b.w / max(1, b.h), 2) <= SWATCH_BOX["aspect_max"])


# 棋盘格的"暗块"游程长度故意放宽 —— 真正的判据不是绝对像素数，而是
# **暗块长度 ≈ 亮块间距 ≈ 行高**三者自洽（见 detect_checker），故 DPR≠1 也成立。
_RUN_RE = re.compile(rb"\x01{6,200}")


def _run_starts(row: bytes) -> list[tuple[int, int]]:
    """一行掩码里所有 0x01 游程 → [(start, end)]（bytes 正则，C 级）。"""
    return [(m.start(), m.end()) for m in _RUN_RE.finditer(row)]


def _equal_pitch_group(runs: list[tuple[int, int]],
                       tol: int = 4) -> list[tuple[int, int]]:
    """从暗游程里挑出**等间距**的最长子序列（同色间距就是 2×格宽）。

    为什么必须先做这一步：同一行里除了棋盘，还可能有标题文字、表格线等别的
    暗像素。实测直接把全行游程拿去做"交替性"判断，会被 30px 间距的文字游程
    打断，导致 candidate_rows=0（正向对照实测）。
    """
    if not runs:
        return []
    best: list[tuple[int, int]] = []
    cur = [runs[0]]
    pitch = 0
    for a, b in zip(runs, runs[1:]):
        gap = b[0] - a[0]
        if pitch == 0:
            ok = gap >= 8
        else:
            ok = abs(gap - pitch) <= tol
        if ok:
            pitch = gap if pitch == 0 else pitch
            cur.append(b)
        else:
            if len(cur) > len(best):
                best = cur
            cur, pitch = [b], 0
    if len(cur) > len(best):
        best = cur
    return best


def detect_checker(img: PPM, dark: bytes, bright: bytes) -> dict:
    """黑白棋盘检测（尺度无关）。

    核心判据是**三个量的自洽**，而不是任何绝对像素数：
      设某行里等间距的暗块序列，格宽 = 暗块长度 ≈ 相邻暗块之间的亮块间距，
      且相邻棋盘行的 y 间距也 ≈ 格宽。
    对 24px 棋盘即：暗块 24 / 亮块 24 / 行高 24，同色间距 48。
    DPR=2 时变成 48/48/48，同一套判据依然成立。

    行间还要求**相位翻转**（相距一个格宽的两行，其暗块起点集合互不相交），
    以排除"竖直条纹"这类同样满足间距自洽但并非棋盘的图案。
    """
    w, h = img.width, img.height
    lines: list[dict] = []
    for y in range(h):
        dr = _equal_pitch_group(_run_starts(dark[y * w:(y + 1) * w]))
        if len(dr) < 3:
            continue
        cell_w = dr[0][1] - dr[0][0]                 # 暗块长度
        gaps = [b[0] - a[1] for a, b in zip(dr, dr[1:])]
        if not gaps:
            continue
        gap_typ = sorted(gaps)[len(gaps) // 2]       # 亮块间距（中位数）
        if gap_typ < 6 or abs(cell_w - gap_typ) > 6:
            continue
        # 亮块必须真的是亮的（抽检每个间隙的中点）
        ok_bright = all(bright[y * w + (a[1] + b[0]) // 2] == 1
                        for a, b in zip(dr, dr[1:]))
        if not ok_bright:
            continue
        lines.append({"y": y, "x0": dr[0][0], "x1": dr[-1][1],
                      "cell": cell_w, "gap": gap_typ,
                      "starts": tuple(s for s, _ in dr)})
    if not lines:
        return {"found": False, "candidate_rows": 0}

    # 同一条棋盘行 → 相邻 y 且几何一致
    groups: list[list[dict]] = [[lines[0]]]
    for ln in lines[1:]:
        p = groups[-1][-1]
        if (ln["y"] - p["y"] <= 2 and abs(ln["x0"] - p["x0"]) <= 3
                and abs(ln["cell"] - p["cell"]) <= 3):
            groups[-1].append(ln)
        else:
            groups.append([ln])
    bands = [g for g in groups if len(g) >= 6]        # 每条棋盘行至少 6px 高
    if len(bands) < 3:
        return {"found": False, "candidate_rows": len(lines),
                "bands": len(bands), "reason": "等距暗块行不足 3 条棋盘行"}

    cells = [b[0]["cell"] for b in bands]
    cell = sorted(cells)[len(cells) // 2]
    # 行高自洽：相邻棋盘行的 y 间距 ≈ 格宽
    y_steps = [b[1][0]["y"] - b[0][0]["y"] for b in zip(bands, bands[1:])]
    step_ok = bool(y_steps) and all(abs(s - cell) <= 6 for s in y_steps)

    # 相位翻转：相距一格宽的两条棋盘行，暗块起点互不相交
    phase_ok = False
    for b1, b2 in zip(bands, bands[1:]):
        if abs((b2[0]["y"] - b1[0]["y"]) - cell) <= 6:
            if not (set(b1[0]["starts"]) & set(b2[0]["starts"])):
                phase_ok = True
                break

    x0 = min(b[0]["x0"] for b in bands)
    x1 = max(b[0]["x1"] for b in bands)
    y0 = bands[0][0]["y"]
    y1 = bands[-1][-1]["y"]
    return {
        "found": True,
        "candidate_rows": len(lines),
        "checker_bands": len(bands),
        "cell_px": cell,
        "same_color_pitch": 2 * cell,
        "y_steps": y_steps,
        "y_step_matches_cell": step_ok,
        "phase_alternates": phase_ok,
        "bbox": [x0, y0, x1, y1],
    }


def detect_lines(img: PPM, dark: bytes, y_from: int, y_to: int,
                 min_h_len: int = TABLE_HLINE_MIN,
                 min_v_len: int = TABLE_VLINE_MIN) -> dict:
    """统计长横线 / 长竖线。表格边框 + footer 上边框都是 1–2px 实线。

    min_h_len 由调用方按屏宽算出（表格是流体宽度），min_v_len 保持绝对值。
    """
    w, h = img.width, img.height
    y_to = min(y_to, h)

    h_rows = [y for y in range(y_from, y_to)
              if longest_run(dark[y * w:(y + 1) * w]) >= min_h_len]
    v_cols = [x for x in range(w)
              if longest_run(dark[x::w][y_from:y_to]) >= min_v_len]

    def collapse(vals: list[int]) -> list[int]:
        groups: list[list[int]] = []
        for v in vals:
            if groups and v - groups[-1][-1] <= 2:
                groups[-1].append(v)
            else:
                groups.append([v])
        return [int(round(sum(g) / len(g))) for g in groups]

    hl, vl = collapse(h_rows), collapse(v_cols)
    return {"h_lines": hl, "v_lines": vl,
            "h_count": len(hl), "v_count": len(vl),
            "min_h_len": min_h_len, "min_v_len": min_v_len}


def detect_js_green(img: PPM, ch, r_hi=189, g_lo=96, g_hi=214, b_hi=200,
                    min_px=15) -> dict:
    """#0b6b2f 系绿字像素 —— 这是 JS 执行过的**像素级硬证据**。

    依据：自检页 CSS 把 `#runtime` 的默认颜色写成红 #b3261e，只有 JS 会把它
    改成绿 #0b6b2f。所以"截图里出现绿字"⇒ JS 跑过；"只有红字"⇒ JS 没跑。

    跨通道条件 `g > r+25 且 g > b+25` 不是逐通道区间，无法用位与表达；
    因此先用**区间超集**做 C 级预筛（候选极少），再在候选上逐点精判。
    实测基准：本机 Chrome 无头 1280x800 渲染本页 → 24 px。
    """
    pre = interval_mask(ch, (0, r_hi), (g_lo, g_hi), (0, b_hi))
    w, h = img.width, img.height
    gch, bch = ch[1], ch[2]
    cnt = 0
    x0, y0, x1, y1 = 1 << 30, 1 << 30, -1, -1
    for y in range(h):
        row = pre[y * w:(y + 1) * w]
        i = row.find(1)
        while i >= 0:
            x = i
            g = gch[y * w + x]
            r = ch[0][y * w + x]
            b = bch[y * w + x]
            if g > r + 25 and g > b + 25:
                cnt += 1
                if x < x0:
                    x0 = x
                if x > x1:
                    x1 = x
                if y < y0:
                    y0 = y
                y1 = y
            i = row.find(1, i + 1)
    return {"count": cnt, "pass": cnt >= min_px,
            "bbox": [x0, y0, x1, y1] if cnt else None}


def detect_primary_area(img: PPM, ch) -> float:
    """高饱和原色像素占比（红/绿/蓝各≥180 且其余通道≤120）。

    用于区分"真的画了彩色内容"与"只有灰度文字的白屏 / Weston 纯色桌面"。
    三类掩码互斥（同一像素不可能同时满足两个），故可直接相加。
    """
    total = img.width * img.height
    n = 0
    n += interval_mask(ch, (180, 255), (0, 120), (0, 120)).count(1)   # 红系
    n += interval_mask(ch, (0, 120), (180, 255), (0, 120)).count(1)   # 绿系
    n += interval_mask(ch, (0, 120), (0, 120), (180, 255)).count(1)   # 蓝系
    return n / total


# --------------------------------------------------------------------------- #
# 差图模式
# --------------------------------------------------------------------------- #

def diff_exact(a: PPM, b: PPM, x0: int, y0: int, x1: int, y1: int) -> dict:
    """逐字节差异判定（等价于"阈值 = 1"）。

    心跳场景下帧计数器数字会整块变化（黑↔白，Δ=255），远超任何实用阈值，
    所以用精确差异既够用又能全程走大整数运算：
      1. 把 ROI 按行拼成紧凑 bytes（避免把整幅图 3 MB 都拿来做异或）
      2. 异或 → 逐字节"是否不同"
      3. 每行内三通道按位或 → 该像素"是否不同"
    """
    w = a.width
    roi_w, roi_h = x1 - x0, y1 - y0
    if roi_w <= 0 or roi_h <= 0:
        return {"comparable": False, "reason": "ROI 为空"}
    rowbytes = roi_w * 3

    ca: list[bytes] = []
    cb: list[bytes] = []
    for y in range(y0, y1):
        s = (y * w + x0) * 3
        ca.append(a.raster[s:s + rowbytes])
        cb.append(b.raster[s:s + rowbytes])
    ra, rb = b"".join(ca), b"".join(cb)
    n = len(ra)

    xor_bytes = (int.from_bytes(ra, "big") ^ int.from_bytes(rb, "big")).to_bytes(n, "big")
    # 逐字节打标：0 → 0，非 0 → 1
    marked = xor_bytes.translate(bytes(0 if v == 0 else 1 for v in range(256)))

    # 逐行合并三通道（⚠️ 必须按行做：把整个 ROI 当成一"行"会把宽度算错，
    # 实测会直接 OverflowError）
    parts: list[bytes] = []
    for yy in range(roi_h):
        s = yy * rowbytes
        r = marked[s:s + rowbytes]
        parts.append((int.from_bytes(r[0::3], "big")
                      | int.from_bytes(r[1::3], "big")
                      | int.from_bytes(r[2::3], "big")).to_bytes(roi_w, "big"))
    px_mask = b"".join(parts)

    changed = px_mask.count(1)
    total = roi_w * roi_h
    bb = mask_blob(px_mask, roi_w, roi_h)     # 差图要的就是**散布** bbox，故用 union
    if bb.valid:
        bb.x0, bb.x1 = bb.x0 + x0, bb.x1 + x0
        bb.y0, bb.y1 = bb.y0 + y0, bb.y1 + y0
        bb.count = changed

    return {
        "comparable": True, "mode": "exact",
        "roi": [x0, y0, x1, y1],
        "changed_pixels": changed,
        "roi_pixels": total,
        "changed_ratio": round(changed / total, 6) if total else 0.0,
        "changed_bbox": bb.as_dict(),
        "changed_bbox_coverage": round((bb.w * bb.h) / total, 4)
        if (bb.valid and total) else 0.0,
    }


# --------------------------------------------------------------------------- #
# 单图判据总装
# --------------------------------------------------------------------------- #

def analyze(img: PPM, non_white_min: float = 0.05,
            full_page_min_h: int = FULL_PAGE_MIN_H) -> list[Check]:
    """单图判据。

    分组（决定 `--strict` 是否卡关）：
      core     — 首屏即可判，任何画幅下都是硬判据
      viewport — 只有 H ≥ full_page_min_h 才在视野内，否则降级为 INFO
      info     — 永远只作参考

    为什么必须有分组：页面整页高约 1080 px，而历史 screendump 里有 640×480 与
    1280×800 两种画幅。画幅不够高时"③表格/②棋盘检不到"是**取景问题**而不是
    渲染失败，把它当 FAIL 会产生假阴性。
    """
    ch = img.channels()
    W, H = img.width, img.height
    tall = H >= full_page_min_h
    checks: list[Check] = []

    # --- A. 画面非空白（INFO：实测负对照也能过，无鉴别力） ----------------- #
    ratio, npx = detect_non_white(img, ch)
    checks.append(Check(
        "non_white_ratio", ratio >= non_white_min,
        f"非白像素 {npx}/{W * H} = {ratio:.4f}（阈值 {non_white_min}）；"
        "⚠️ 参考项：Weston 纯色桌面实测也能 PASS，故不参与卡关",
        {"ratio": round(ratio, 5)}, group="info"))

    # --- B. banner 品牌红 #c8102e（CORE；阈值按屏宽/屏高相对化） ------------ #
    banner = detect_banner(img, ch)
    bw_req = max(BANNER_W_MIN, int(BANNER_W_FRAC * W))
    bh_lo, bh_hi = int(BANNER_H_LO_FRAC * H), int(BANNER_H_HI_FRAC * H)
    banner_ok = banner.valid and banner.w >= bw_req and bh_lo <= banner.h <= bh_hi
    checks.append(Check(
        "banner_c8102e", banner_ok,
        f"#c8102e 色条 {banner.as_dict()}；要求 宽≥{bw_req}(=max({BANNER_W_MIN},"
        f"{BANNER_W_FRAC}·W)) 且 高∈[{bh_lo},{bh_hi}](=[{BANNER_H_LO_FRAC}H,"
        f"{BANNER_H_HI_FRAC}H])",
        {"bbox": banner.as_dict(), "w_req": bw_req, "h_band": [bh_lo, bh_hi]}))

    # --- C. 三原色块 + 左→右顺序 + 同一水平带（CORE；CSS 固定尺寸，不相对化） #
    blobs = {n: detect_swatch(img, ch, n) for n in ("red", "green", "blue")}
    shaped = {n: _swatch_shaped(b) for n, b in blobs.items()}
    ok3 = all(shaped.values())
    checks.append(Check(
        "swatches_3channels", ok3,
        "120x72 级纯色块（CSS 固定尺寸，绝对像素带）：" + "；".join(
            f"{n} " + ("✓" if shaped[n] else f"✗ {blobs[n].as_dict()}") for n in blobs),
        {"blobs": {n: blobs[n].as_dict() for n in blobs}}))

    order_ok = align_ok = False
    if ok3:
        x0 = {n: blobs[n].x0 for n in blobs}
        yc = {n: (blobs[n].y0 + blobs[n].y1) // 2 for n in blobs}
        order_ok = x0["red"] < x0["green"] < x0["blue"]
        align_ok = max(yc.values()) - min(yc.values()) <= 8
        detail = (f"x0 红/绿/蓝 = {x0['red']}/{x0['green']}/{x0['blue']}；"
                  f"y 中心 = {yc['red']}/{yc['green']}/{yc['blue']}")
    else:
        detail = "未检出三个形状合理的纯色块，顺序判据不适用"
    checks.append(Check("swatches_left_to_right", order_ok,
                        "水平顺序应为 红→绿→蓝。" + detail))
    checks.append(Check("swatches_same_row", align_ok,
                        "三色块应在同一水平带（y 中心差 ≤8px）。" + detail))

    # --- D. 棋盘格（VIEWPORT：尺度无关判据本身不动，只是画幅不够时可能在视野外） #
    dark = interval_mask(ch, (0, DARK_MAX), (0, DARK_MAX), (0, DARK_MAX))
    bright = interval_mask(ch, (200, 255), (200, 255), (200, 255))
    checker = detect_checker(img, dark, bright)
    checker_ok = bool(checker.get("found")) and checker.get("phase_alternates", False) \
        and checker.get("y_step_matches_cell", False)
    checks.append(Check(
        "checkerboard_24px", checker_ok,
        f"黑白棋盘（暗块长≈亮块间距≈行高，尺度无关）：{checker}",
        {"checker": checker}, group="viewport"))

    # --- E. 表格线（VIEWPORT；横线阈值按屏宽相对化） ------------------------ #
    y_floor = max((b.y1 for b in blobs.values() if b.valid), default=0)
    hline_min = max(TABLE_HLINE_MIN, int(TABLE_HLINE_FRAC * W))
    lines = detect_lines(img, dark, y_floor, H, min_h_len=hline_min)
    lines_ok = lines["h_count"] >= 4 and lines["v_count"] >= 4
    checks.append(Check(
        "table_borders", lines_ok,
        f"长横线 {lines['h_count']} 条 {lines['h_lines'][:8]}（长度阈值 "
        f"{hline_min}=max({TABLE_HLINE_MIN},{TABLE_HLINE_FRAC}·W)），"
        f"长竖线 {lines['v_count']} 条 {lines['v_lines'][:8]}（高度阈值 "
        f"{TABLE_VLINE_MIN}）；要求各 ≥4",
        {"lines": lines}, group="viewport"))

    # --- F. JS 执行证据：绿字 #0b6b2f（CORE；v1.2 起搬到首屏状态条） -------- #
    js = detect_js_green(img, ch)
    checks.append(Check(
        "js_executed_green_text", js["pass"],
        f"#0b6b2f 绿字像素 {js['count']}（阈值 15；文字像素量，不随屏宽变）→ "
        + ("JS 已执行（CSS 默认红 #b3261e 被 JS 改绿）"
           if js["pass"] else "未检出绿字：JS 未执行 / 页面未渲染到首屏"),
        {"count": js["count"], "bbox": js["bbox"]}))

    # --- G. 是否真的画了彩色内容（INFO：banner 本身就满足，无鉴别力） ------ #
    pa = detect_primary_area(img, ch)
    checks.append(Check(
        "primary_color_area", pa >= 0.01,
        f"高饱和原色像素占比 {pa:.4f}（阈值 0.01）；"
        "⚠️ 参考项：#c8102e 的 banner 自身即满足该谓词，故不参与卡关",
        {"ratio": round(pa, 5)}, group="info"))

    for c in checks:
        if c.group == "viewport" and not tall:
            c.data["viewport_note"] = (
                f"H={H} < {full_page_min_h}：该项可能在视野之外，"
                "不作为硬判据（须人工目视复核）")
    return checks


# --------------------------------------------------------------------------- #
# 官方测试页（组委会三页套）· 判据常量与检测
#
# 为什么单开一套：`legacy` 那 9 条谓词全部锚在自建页 local-check.html 的
# CSS 上（#c8102e banner / 120x72 三原色块 / 24px 棋盘 / #444 表格线 / #0b6b2f 绿字）。
# 2026-09-22 官方三页套到位后，用 legacy 判据实测官方页：**严格集 1/7**，
# 而且仅剩的那 1 项还是**假阳性** —— index.html 是无脚本静态页，却因为
# "绿块 #2da44e 落在 detect_js_green 的区间超集里"被判成"JS 已执行 13614 px"。
# 这正是 M2 说的"未验证的门禁比没门禁更危险"，所以官方页必须有自己的判据。
#
# 下面所有常量都来自**参考图实测**（本机无头 Chrome 渲染三页，见 scripts/testpage/
# reference/），不是从 CSS 反推的。实测记录（2026-09-22，Chrome 无头 DPR=1）：
#
#   banner #17456b   640x480: 608x84     1280x800: 848x84   （w/W = 0.95 / 0.66）
#   index 四色块     640: 131x64 ×4 同带 y196..259，间隙 17    1280: 192x64 ×4
#   layout C1 三块   640: 182x56 ×3 同带 y167..222            1280: 262x56 ×3
#   layout C2 网格   640: 287x48，两行 y299..346 / y357..404   1280: 407x48，同两行 y
#   layout C3 盒模型 1280: 上下各 5px 边框带 y481..485 / y626..630，x 宽 250，跨距 150
#   表格横线         index 640: 5 条等距 31   1280: 6 条等距 31
#                    interaction 640: 9 条等距 29   1280: 9 条等距 29
#   verdict 绿字     自动 6/6：1483 px（layout）/ 1899 px（interaction 点击后）/ 0（未点击）
#   verdict 条底     同左：30489 px / 60056 px / 36 px（36 = 抗锯齿噪声）
#
# 两条设计约束（沿用 legacy 的教训）：
#   1. **尺度无关优先**：屏幕宽 640 与 1280 下内容宽度不同（wrap 有 max-width:880），
#      所以"表格横线"判的是**线长自相等 + 等间距自洽**，而不是"线长 ≥ 0.28·W"；
#   2. **同色元素必须分带**：index 页 #17456b 同时是 banner、SVG 的 rect、按钮底色，
#      整体 bbox 会被撑成 848x692 —— 必须先用行带把结构分开再判形状。
# --------------------------------------------------------------------------- #

OFFICIAL_BANNER_RGB = ((10, 45), (50, 90), (85, 130))        # #17456b
OFFICIAL_PASS_TEXT = ((15, 40), (110, 145), (40, 75))        # #1a7f37 「通过」
OFFICIAL_FAIL_TEXT = ((185, 215), (45, 75), (40, 70))        # #c93c37 「未通过」
OFFICIAL_PASS_BG = ((205, 232), (240, 255), (215, 238))      # #dafbe1 结论条底
OFFICIAL_FAIL_BG = ((244, 255), (228, 245), (225, 242))      # #ffebe9 结论条底
OFFICIAL_RULE_RGB = ((190, 214), (196, 218), (203, 226))     # #c7cdd4 / #d0d7de 表格线
OFFICIAL_BOX_RGB = ((212, 226), (228, 240), (248, 255))      # #dbeafe C3 盒模型内容区

# 四个色块的区间（banner #17456b 兼作 layout C2 的第一格）
OFFICIAL_BLOCK_RGB = {
    "blue":   OFFICIAL_BANNER_RGB,
    "red":    ((215, 245), (70, 100), (60, 90)),             # #e5534b
    "green":  ((30, 65), (150, 180), (60, 95)),              # #2da44e
    "yellow": ((175, 210), (120, 150), (0, 15)),             # #bf8700
    "purple": ((115, 145), (65, 95), (205, 240)),            # #8250df
}
OFFICIAL_BANNER_H_BAND = (40, 140)          # 实测 84；留字体回退余量
OFFICIAL_BANNER_W_FRAC = 0.60               # 实测 0.95(640) / 0.66(1280)
OFFICIAL_VERDICT_TEXT_MIN = 300             # 实测 正 1483/1899，负 0
OFFICIAL_VERDICT_BG_MIN = 5000              # 实测 正 30489/60056，负 36
OFFICIAL_FAIL_TEXT_MAX = 300                # 实测 0
OFFICIAL_FAIL_BG_MAX = 2000                 # 实测 37
OFFICIAL_RULE_GROUP_TOL = 8                 # 线长分桶宽度（px）
OFFICIAL_RULE_PITCH_TOL = 2                 # 等间距容差（px）


def row_bands(mask: bytes, w: int, h: int, min_count: int,
              y_from: int = 0, y_to: int | None = None,
              gap: int = 2) -> list[tuple[int, int, int]]:
    """按行投影切出连续"行带"：`[(y0, y1, 行内峰值像素数)]`。

    与 `dominant_bbox` 的区别：那个只返回**最长的一条**带，这个返回全部带 ——
    官方页上同一颜色常常出现在多处（banner / SVG / 按钮），必须先把每一处分开。
    """
    y_to = h if y_to is None else min(y_to, h)
    bands: list[tuple[int, int, int]] = []
    start = prev = None
    for y in range(y_from, y_to):
        c = mask[y * w:(y + 1) * w].count(1)
        if c >= min_count:
            if start is None:
                start = y
            prev = y
        elif start is not None and y - prev > gap:
            bands.append((start, prev, max(
                mask[t * w:(t + 1) * w].count(1) for t in range(start, prev + 1))))
            start = None
    if start is not None:
        bands.append((start, prev, max(
            mask[t * w:(t + 1) * w].count(1) for t in range(start, prev + 1))))
    return bands


def mask_x_extent(mask: bytes, w: int, y0: int, y1: int) -> tuple[int, int]:
    """[y0, y1] 行范围内命中像素的 x 范围（无命中返回 (-1, -1)）。"""
    x0, x1 = w, -1
    for y in range(max(0, y0), y1 + 1):
        row = mask[y * w:(y + 1) * w]
        a = row.find(1)
        if a >= 0:
            x0 = min(x0, a)
            x1 = max(x1, len(row) - 1 - row[::-1].find(1))
    return (x0, x1) if x1 >= 0 else (-1, -1)


def collapse_lines(vals: list[int], tol: int = 2) -> list[int]:
    """把相邻（≤ tol 像素）的行号折成一条线，取中心。"""
    out: list[int] = []
    grp: list[int] = []
    for v in vals:
        if grp and v - grp[-1] <= tol:
            grp.append(v)
        else:
            if grp:
                out.append(int(round(sum(grp) / len(grp))))
            grp = [v]
    if grp:
        out.append(int(round(sum(grp) / len(grp))))
    return out


def detect_long_lines(img: PPM, ch, rng, min_len: int,
                      y_from: int = 0) -> list[tuple[int, int]]:
    """浅灰长横线：`[(y, 该行最长连续命中长度)]`。

    为什么把"长度"一起返回：官方页的判据要靠**线长自相等**（同一条表格的
    所有横线一样长）来分组，而不是靠"≥ 某个屏宽比例"——内容宽度被 CSS 的
    `max-width:880` 截断，1280 下表格线只有屏宽的 0.64 倍，按屏宽取阈值会
    在 1280 上系统性漏检（实测 tall 图 candidate=0）。
    """
    w, h = img.width, img.height
    mask = interval_mask(ch, *rng)
    out = []
    for y in range(y_from, h):
        ln = longest_run(mask[y * w:(y + 1) * w])
        if ln >= min_len:
            out.append((y, ln))
    return out


def even_pitch_run(lines: list[int], tol: int = OFFICIAL_RULE_PITCH_TOL,
                   min_lines: int = 4) -> dict:
    """从一组线里找**最长等间距子序列**（表格横线的尺度无关签名）。

    为什么不是"数够 4 条就行"：卡片边框、footer 上边框也会被计入。
    实测 index 640 的候选线是 `[122, 274, 291, 336, 367, 398, 429, 460]`，
    只有后 5 条（等距 31）来自表格；等间距自洽性正好把两组分开。
    """
    if len(lines) < min_lines:
        return {"found": False, "lines": lines, "count": len(lines), "pitches": [],
                "first": None, "reason": f"候选线不足 {min_lines} 条"}
    best: list[int] = []
    for i in range(len(lines)):
        run = [lines[i]]
        for j in range(i + 1, len(lines)):
            if not run:
                break
            pitch = lines[j] - run[-1]
            if pitch <= 4:
                continue
            if len(run) >= 2:
                ref = run[-1] - run[-2]
                if abs(pitch - ref) > tol:
                    break
            run.append(lines[j])
        if len(run) > len(best):
            best = run
    pitches = [best[i + 1] - best[i] for i in range(len(best) - 1)]
    ok = len(best) >= min_lines and (not pitches or max(pitches) - min(pitches) <= tol)
    return {"found": ok, "lines": best, "count": len(best),
            "pitches": pitches, "first": best[0] if best else None,
            "reason": "" if ok else f"等间距子序列仅 {len(best)} 条"}


def detect_official_banner(img: PPM, ch) -> Blob:
    """深蓝 banner：只在画面顶部 30% 内取最大实心带。

    为什么要限高：`#17456b` 在 index 页还出现在正文的 SVG 与按钮上，
    不限范围时整体 bbox 是 848x692（实测），完全不能当 banner 形状判据。
    """
    w, h = img.width, img.height
    mask = bytearray(interval_mask(ch, *OFFICIAL_BANNER_RGB))
    y_cut = int(0.30 * h)
    for y in range(y_cut, h):
        mask[y * w:(y + 1) * w] = b"\x00" * w
    return dominant_bbox(bytes(mask), w, h)


def _blob_summary(b: Blob) -> dict:
    """无效块统一写成 0 尺寸。

    为什么必须归一化：`Blob` 的哨兵值是 `x0=1<<30 / x1=-1`，于是"未检出"的块
    会算出 `w = -1073741824`。这些哨兵一旦流进数值比较（"极差 ≤ 4"）就会
    把 `-1073741824, -1073741824, ...` 判成"等宽" —— 自检脚本在**全白图**上
    实测到过这个假阳性。日志里也不该出现 1<<30 这种看着像实测值的数字。
    """
    if not b.valid:
        return {"valid": False, "count": b.count, "w": 0, "h": 0}
    return {"valid": True, "count": b.count, "x0": b.x0, "y0": b.y0,
            "x1": b.x1, "y1": b.y1, "w": b.w, "h": b.h}


def detect_official_block(img: PPM, ch, name: str, y_from: int = 0,
                          y_to: int | None = None) -> dict:
    """单个色块的实测形状：`{valid, y0, y1, x0, x1, w, h}`（可限定行范围）。"""
    w, h = img.width, img.height
    mask = bytearray(interval_mask(ch, *OFFICIAL_BLOCK_RGB[name]))
    if y_from or y_to is not None:
        y_to = h if y_to is None else min(y_to, h)
        if y_from:
            mask[0:y_from * w] = b"\x00" * (y_from * w)
        if y_to < h:
            mask[y_to * w:] = b"\x00" * ((h - y_to) * w)
    return _blob_summary(dominant_bbox(bytes(mask), w, h))


def detect_verdict(img: PPM, ch) -> dict:
    """页面自检结论的像素计数（绿=通过 / 红=未通过，文字与条底各一）。

    这是官方页上的 **JS 执行硬证据**：结论条只有在 JS 跑完 `runChecks()` /
    布局自检之后才会被写成绿或红；页面静态 HTML 里两者都不存在
    （实测未点击时绿字 0 px、绿底 36 px = 抗锯齿噪声）。
    """
    out = {}
    for key, rng in (("pass_text", OFFICIAL_PASS_TEXT),
                     ("fail_text", OFFICIAL_FAIL_TEXT),
                     ("pass_bg", OFFICIAL_PASS_BG),
                     ("fail_bg", OFFICIAL_FAIL_BG)):
        out[key] = interval_mask(ch, *rng).count(1)
    return out


# --------------------------------------------------------------------------- #
# 官方三页套 · 单图判据总装
# --------------------------------------------------------------------------- #

def analyze_official(img: PPM, page: str, expect_input: bool = False,
                     full_page_min_h: int = FULL_PAGE_MIN_H) -> list[Check]:
    """官方测试页（index / layout / interaction）的判据。

    `page` 取 `official-index` / `official-layout` / `official-interaction`。
    """
    ch = img.channels()
    W, H = img.width, img.height
    checks: list[Check] = []

    # --- 0. 画面非空白（INFO） --------------------------------------------- #
    ratio, npx = detect_non_white(img, ch)
    checks.append(Check(
        "non_white_ratio", ratio >= 0.05,
        f"非白像素 {npx}/{W * H} = {ratio:.4f}；⚠️ 参考项，不参与卡关",
        {"ratio": round(ratio, 5)}, group="info"))

    # --- 1. 官方页 banner #17456b（CORE，三页共用） ------------------------ #
    banner = detect_official_banner(img, ch)
    w_req = max(200, int(OFFICIAL_BANNER_W_FRAC * W))
    h_lo, h_hi = OFFICIAL_BANNER_H_BAND
    banner_ok = (banner.valid and banner.w >= w_req
                 and h_lo <= banner.h <= h_hi)
    checks.append(Check(
        "official_banner", banner_ok,
        f"#17456b banner {_blob_summary(banner)}；要求 宽≥{w_req}"
        f"(={OFFICIAL_BANNER_W_FRAC}·W，实测 0.95@640 / 0.66@1280) 且 高∈[{h_lo},{h_hi}]"
        f"（实测 84）",
        {"bbox": _blob_summary(banner), "w_req": w_req}, group="core"))

    # --- 2. 结论条：JS 执行证据 + 失败色缺席（CORE） ----------------------- #
    v = detect_verdict(img, ch)
    fail_ok = (v["fail_text"] <= OFFICIAL_FAIL_TEXT_MAX
               and v["fail_bg"] <= OFFICIAL_FAIL_BG_MAX)
    checks.append(Check(
        "verdict_fail_absent", fail_ok,
        f"失败色：文字 #c93c37 {v['fail_text']} px（上限 {OFFICIAL_FAIL_TEXT_MAX}，"
        f"实测 0）、条底 #ffebe9 {v['fail_bg']} px（上限 {OFFICIAL_FAIL_BG_MAX}，"
        f"实测 37）；出现即说明页面自检判出了「未通过」",
        dict(v), group="core"))

    if page == "official-index":
        # --- index：四个色块同一行、等宽、顺序 红→绿→黄→紫（CORE） -------- #
        order = ("red", "green", "yellow", "purple")
        blobs = {n: detect_official_block(img, ch, n) for n in order}
        shapes = {n: (b["valid"] and 40 <= b["h"] <= 120
                      and b["w"] >= max(60, int(0.08 * W))) for n, b in blobs.items()}
        ok4 = all(shapes.values())
        detail = "；".join(
            f"{n} " + (f"{b['w']}x{b['h']}@({b['x0']},{b['y0']})" if shapes[n]
                       else f"✗ {b}") for n, b in blobs.items())
        same_row = ok4 and (max(b["y0"] for b in blobs.values())
                            - min(b["y0"] for b in blobs.values()) <= 4)
        widths = [b["w"] for b in blobs.values()]
        # ⚠️ 必须先 `ok4` 再用极差：未检出的块在 _blob_summary 里是 0 宽，
        #    `0,0,0,0` 的极差 = 0 ≤ 4，会在**全白图**上被判成"等宽"（自检实测抓到的假阳性）。
        eq_w = bool(ok4 and widths
                    and (max(widths) - min(widths)) <= max(4, int(0.05 * max(widths))))
        left_to_right = ok4 and (blobs["red"]["x0"] < blobs["green"]["x0"]
                                 < blobs["yellow"]["x0"] < blobs["purple"]["x0"])
        checks.append(Check(
            "index_blocks_shape", ok4, f"四色块形状（实测 131x64@640 / 192x64@1280）：{detail}",
            {"blobs": blobs}, group="core"))
        checks.append(Check(
            "index_blocks_same_row", same_row,
            f"四色块同一水平带（y0 极差 ≤4px，实测四块 y 完全相同）：{detail}",
            group="core"))
        checks.append(Check(
            "index_blocks_equal_width", bool(eq_w),
            f"四色块等宽（极差 ≤ max(4, 5%)，实测 131/131/132/131）：{widths}", group="core"))
        checks.append(Check(
            "index_blocks_order", left_to_right,
            "水平顺序 红→绿→黄→紫（实测 x0 = "
            + "/".join(str(blobs[n]["x0"]) if blobs[n]["valid"] else "-"
                      for n in order) + "）", group="core"))

        # --- index：表格横线（VIEW） ------------------------------------- #
        lines = [y for y, _ in detect_long_lines(img, ch, OFFICIAL_RULE_RGB,
                                                 max(120, int(0.30 * W)))]
        lines = collapse_lines(lines)
        run = even_pitch_run(lines)
        checks.append(Check(
            "index_table_rules", bool(run["found"]),
            f"表格横线等间距签名：{len(run['lines'])} 条 {run['lines'][:8]}，"
            f"间距 {run['pitches'][:7]}（实测 640 为 5 条 ×31，1280 为 6 条 ×31）；"
            f"{run['reason']}",
            {"run": run, "all_lines": lines}, group="viewport", min_h=420))

        # --- index：静态页应当**没有**结论条（INFO，反向哨兵） ------------ #
        static_ok = (v["pass_text"] <= 100 and v["pass_bg"] <= OFFICIAL_VERDICT_BG_MIN)
        checks.append(Check(
            "index_is_static", static_ok,
            f"index 是纯静态页（无脚本）：结论条绿字 {v['pass_text']} px / 绿底 "
            f"{v['pass_bg']} px，两者都应为噪声级（实测 0 / 0）。"
            "此项**反向**保护：若这里变成大数，说明判据串页了（把交互页当 index 判）",
            dict(v), group="info"))

    elif page == "official-layout":
        # --- layout C1 弹性布局：三个等宽块同行（CORE） ------------------- #
        c1_names = ("red", "yellow", "purple")
        c1 = {n: detect_official_block(img, ch, n) for n in c1_names}
        shapes = {n: (b["valid"] and 40 <= b["h"] <= 80) for n, b in c1.items()}
        ok3 = all(shapes.values())
        same_row = ok3 and (max(b["y0"] for b in c1.values())
                            - min(b["y0"] for b in c1.values()) <= 4)
        widths = [c1[n]["w"] for n in c1_names]
        eq_w = bool(widths) and (max(widths) - min(widths)) <= max(4, int(0.05 * max(widths)))
        detail = "；".join(
            (f"{n} {c1[n]['w']}x{c1[n]['h']}@y{c1[n]['y0']}" if c1[n]["valid"]
             else f"{n} ✗未检出") for n in c1_names)
        checks.append(Check(
            "layout_c1_flex_row", ok3 and same_row and eq_w,
            f"C1 flex 三块同行等宽（实测 182x56@640 / 262x56@1280，同一 y 带）：{detail}"
            f"；等宽极差 {max(widths) - min(widths) if widths else '-'}",
            {"c1": c1}, group="core"))

        # --- layout C2 网格布局：2 行 2 列（CORE） ------------------------ #
        grid_names = ("blue", "green", "yellow", "purple")
        c1_bottom = max((c1[n]["y1"] for n in c1_names if c1[n]["valid"]), default=0)
        cells = {n: detect_official_block(img, ch, n, y_from=c1_bottom + 5)
                 for n in grid_names}
        # 四格必须都检出，且按 y 归并成两行、每行两块
        ok_cells = all(c["valid"] and 30 <= c["h"] <= 80 for c in cells.values())
        rows: dict[int, list[str]] = {}
        for n, c in cells.items():
            if c["valid"]:
                key = round(c["y0"] / 8)
                rows.setdefault(key, []).append(n)
        two_rows = (ok_cells and len(rows) == 2
                    and all(len(v) == 2 for v in rows.values()))
        # 列对齐：两行的两块 x 起点应当一致（grid 的"两列"由此坐实）
        col_ok = False
        if two_rows:
            keys = sorted(rows)
            row_x = [sorted(cells[n]["x0"] for n in rows[k]) for k in keys]
            col_ok = (abs(row_x[0][0] - row_x[1][0]) <= 4
                      and abs(row_x[0][1] - row_x[1][1]) <= 4)
        grid_detail = "；".join(
            (f"{n} {c['w']}x{c['h']}@({c['x0']},{c['y0']})" if c["valid"]
             else f"{n} ✗未检出") for n, c in cells.items())
        checks.append(Check(
            "layout_c2_grid_2x2", bool(two_rows and col_ok),
            f"C2 grid 2 行 2 列（实测 287x48@640 / 407x48@1280，两行 y 起点相同、列 x 对齐）："
            f"{grid_detail}；行分组 {dict(rows)}；列对齐 {col_ok}",
            {"cells": cells, "rows": rows}, group="core"))

        # --- layout C3 盒模型：上/下 5px 边框带相距 150、宽 250（VIEW） --- #
        mask = interval_mask(ch, *OFFICIAL_BANNER_RGB)
        bands = row_bands(mask, W, H, max(60, int(0.10 * W)))
        thin = [b for b in bands if 3 <= (b[1] - b[0] + 1) <= 9]
        c3 = {"bands": bands, "thin": thin}
        c3_ok = False
        if len(thin) >= 2:
            for i in range(len(thin)):
                for j in range(i + 1, len(thin)):
                    y0i, y1i, _ = thin[i]
                    y0j, _, _ = thin[j]
                    xi = mask_x_extent(mask, W, y0i, y1i)
                    xj = mask_x_extent(mask, W, y0j, y0j)
                    w_i, w_j = xi[1] - xi[0] + 1, xj[1] - xj[0] + 1
                    if (abs(w_i - w_j) <= 4 and 120 <= w_i <= int(0.45 * W)
                            and 100 <= (y0j - y0i) <= 200):
                        c3_ok = True
                        c3.update(gap=y0j - y0i, width=w_i,
                                  top=(y0i, y1i), bottom=y0j)
        checks.append(Check(
            "layout_c3_box_model", c3_ok,
            f"C3 盒模型 5px 边框带：细带 {len(thin)} 条 {[(a, b) for a, b, _ in thin]}；"
            f"实测上下带 y481..485 / y626..630（跨距 150）、宽 250。判据 = 两条细带"
            f"等宽（±4）且跨距 ∈[100,200]px（= content 100 + padding 40 + 边框 10）"
            f"→ {c3.get('gap', '-')}px / {c3.get('width', '-')}px",
            {"c3": {k: v2 for k, v2 in c3.items() if k != "bands"}}, group="viewport"))

        # --- layout 自检结论：6/6 全绿（VIEW，需画幅够高看到结论条） ----- #
        y_needed = 1400                          # 实测：结论条在整页 y≈1450 处
        pass_ok = (v["pass_text"] >= OFFICIAL_VERDICT_TEXT_MIN
                   and v["pass_bg"] >= OFFICIAL_VERDICT_BG_MIN)
        checks.append(Check(
            "layout_verdict_pass", pass_ok,
            f"结论条绿字 {v['pass_text']} px（≥{OFFICIAL_VERDICT_TEXT_MIN}，实测 1483）"
            f"+ 绿底 {v['pass_bg']} px（≥{OFFICIAL_VERDICT_BG_MIN}，实测 30489）"
            "→ JS 已跑完 C1–C6 且 6/6 通过",
            dict(v), group="viewport", min_h=y_needed))

    else:   # official-interaction
        # --- interaction 身份签名：banner 下方没有任何实心色块（CORE） ----- #
        # 为什么必须有它：这个 profile 的另一条硬判据（banner / 失败色缺席）是**三页共用**
        # 的，只靠它们的话 index / layout 的截图也能通过 interaction 档 —— 实测跨页负对照
        # 0/3 失败。身份签名取自三页的结构差异：interaction 页唯一的实心色块是那对按钮
        # #17456b（实测 92x34），高度远小于 index 的 64 与 layout 的 48/56。
        banner_bottom = banner.y1 if banner.valid else 0
        blocks = {}
        for nm in ("blue", "red", "green", "yellow", "purple"):
            b = detect_official_block(img, ch, nm, y_from=banner_bottom + 5)
            if b["valid"] and b["h"] >= 40 and b["w"] >= max(40, int(0.05 * W)):
                blocks[nm] = f"{b['w']}x{b['h']}@({b['x0']},{b['y0']})"
        checks.append(Check(
            "interaction_no_blocks", not blocks,
            f"banner 下方无实心色块（阈值 高≥40 且 宽≥{max(40, int(0.05 * W))}；"
            f"实测页面最大蓝块 = 按钮 92x34）→ 检出 {blocks or '无'}。"
            "此项是跨页鉴别：若列出红/绿/黄/紫块，说明这一帧其实是 index 或 layout 页",
            {"blocks": blocks}, group="core"))

        # --- interaction：自检表横线（VIEW，640x480 下也在框内） ---------- #
        # 为什么要 min_lines=7 而不是 4：index 的表格（6 条 ×31）会满足"≥4 条等距"，
        # 于是 interaction 档在 index 截图上误判通过（实测跨页负对照就是这里漏的）。
        # 官方 interaction 自检表是 8 行（表头 + T1–T6 + F1）→ 实测 9 条 ×29，留 2 条余量。
        lines = [y for y, _ in detect_long_lines(img, ch, OFFICIAL_RULE_RGB,
                                                 max(120, int(0.30 * W)))]
        lines = collapse_lines(lines)
        run = even_pitch_run(lines, min_lines=7)
        checks.append(Check(
            "interaction_checks_table", bool(run["found"]),
            f"自检表横线等间距签名：{len(run['lines'])} 条 {run['lines'][:10]}，"
            f"间距 {run['pitches'][:8]}（实测 640/1280 均为 9 条 ×29；index 只有 6 条 ×31，"
            f"故本项同时承担跨页鉴别）；{run['reason']}",
            {"run": run, "all_lines": lines}, group="viewport", min_h=420))

        # --- interaction 自检结论：需要一次点击（INPUT 组） -------------- #
        pass_ok = (v["pass_text"] >= OFFICIAL_VERDICT_TEXT_MIN
                   and v["pass_bg"] >= OFFICIAL_VERDICT_BG_MIN)
        checks.append(Check(
            "interaction_selfcheck_pass", pass_ok,
            f"结论条绿字 {v['pass_text']} px + 绿底 {v['pass_bg']} px"
            f"（点击「运行自检」后的实测值 1899 / 60056；未点击时 0 / 36）"
            "→ T1–T6 全通过。**本项依赖真实点击输入**",
            dict(v), group="input", min_h=1400))

        # --- interaction 初始态哨兵（INFO） ------------------------------ #
        checks.append(Check(
            "interaction_awaiting_input", v["pass_bg"] <= OFFICIAL_VERDICT_BG_MIN,
            f"未点击时结论条应为灰（绿底 {v['pass_bg']} px ≤ {OFFICIAL_VERDICT_BG_MIN}，"
            f"实测 36）→ 页面处于「待检测」初始态",
            dict(v), group="info"))

    return checks


def color_histogram(img: PPM, step: int = 4, top: int = 6) -> dict:
    """屏幕内容统计：主色占比、不同颜色数、平均色。

    为什么需要它：特征谓词只能回答"页面画出来了吗"，回答不了"屏幕上到底是什么"。
    实践中正是这个统计把两类失败区分开的 —— 例如同一份判据下
    C0（--disable-gpu）出现 66.7% 纯白面（像是有窗口但内容没画），
    C1（angle-vulkan）则是 33% 灰色系、零白像素（窗口/桌面状态完全不同）。
    没有这一步，"没渲染出来"只是结论，不是证据。
    """
    ch = img.channels()
    W, H = img.width, img.height
    cnt: dict[tuple[int, int, int], int] = {}
    sr = sg = sb = 0
    n = 0
    for y in range(0, H, step):
        base = y * W
        for x in range(0, W, step):
            i = base + x
            c = (ch[0][i], ch[1][i], ch[2][i])
            cnt[c] = cnt.get(c, 0) + 1
            sr += c[0]; sg += c[1]; sb += c[2]
            n += 1
    top_list = sorted(cnt.items(), key=lambda kv: -kv[1])[:top]
    return {
        "sampled": n,
        "step": step,
        "distinct_colors": len(cnt),
        "mean_rgb": [round(sr / n), round(sg / n), round(sb / n)] if n else None,
        "top": [{"rgb": list(c), "pct": round(100.0 * k / n, 2)} for c, k in top_list],
    }


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def parse_roi(s: str):
    parts = [int(v) for v in s.replace(" ", "").split(",")]
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("ROI 形如 x0,y0,x1,y1")
    return tuple(parts)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="QEMU screendump PPM 自动判据（页面渲染特征 + 双帧心跳）")
    ap.add_argument("ppm", help="待判定的 PPM（QEMU monitor screendump 产出）")
    ap.add_argument("--profile", default="legacy",
                    choices=["legacy", "official-index", "official-layout",
                             "official-interaction"],
                    help="判据档：legacy = 自建页 local-check.html（历史轮次仍可复现）；"
                         "official-* = 组委会三页套对应页的判据（常量全部来自参考图实测）")
    ap.add_argument("--expect-input", action="store_true",
                    help="本轮包含真实输入（点击/键入）→ 把 input 组判据纳入严格集")
    ap.add_argument("--diff", metavar="PPM2", help="差图模式：与另一张 PPM 比较")
    ap.add_argument("--roi", type=parse_roi, default=None, help="差图 ROI：x0,y0,x1,y1")
    ap.add_argument("--min-changed", type=int, default=200,
                    help="差图模式：变化像素数下限（默认 200）")
    ap.add_argument("--max-bbox-coverage", type=float, default=0.60,
                    help="差图模式：变化 bbox 覆盖率上限（超过视为整屏重绘 / 闪屏）")
    ap.add_argument("--non-white-min", type=float, default=0.05,
                    help="非白像素占比下限（默认 0.05）")
    ap.add_argument("--expect-size", default=None, help="期望尺寸 WxH，如 1280x800")
    ap.add_argument("--full-page-min-height", type=int, default=FULL_PAGE_MIN_H,
                    help=f"画幅高 ≥ 此值才认为 viewport 组（棋盘/表格）在视野内"
                         f"（默认 {FULL_PAGE_MIN_H}）")
    ap.add_argument("--histogram", action="store_true",
                    help="只打印屏幕内容统计（主色占比/不同颜色数/平均色）后退出——"
                         "用于回答'屏幕上到底是什么'，与特征谓词互补")
    ap.add_argument("--histogram-step", type=int, default=4,
                    help="内容统计的采样步长（默认 4 像素）")
    ap.add_argument("--json", dest="json_out", default=None, help="结果落盘为 JSON")
    ap.add_argument("--strict", action="store_true",
                    help="core 组（+ 画幅足够时的 viewport 组）失败则 exit 1")
    ap.add_argument("--quiet", action="store_true", help="只打印结论行")
    args = ap.parse_args(argv)

    try:
        img = read_ppm(args.ppm)
    except (PPMError, OSError) as exc:
        print(f"!! 读取失败: {exc}", file=sys.stderr)
        return 2

    report: dict = {"file": os.path.basename(args.ppm),
                    "size": f"{img.width}x{img.height}",
                    "header_bytes": img.header_bytes,
                    "raster_bytes": len(img.raster)}
    exit_code = 0

    if args.expect_size:
        want = args.expect_size.lower().split("x")
        got = f"{img.width}x{img.height}"
        ok = len(want) == 2 and got == f"{int(want[0])}x{int(want[1])}"
        report["size_check"] = {"pass": ok, "expected": args.expect_size, "got": got}
        if not ok:
            exit_code = 1
        if not args.quiet:
            print(f"{'PASS' if ok else 'FAIL'} size_check: 期望 "
                  f"{args.expect_size}，实际 {got}"
                  f"（header {img.header_bytes} B + raster {len(img.raster)} B）")

    if args.histogram:
        h = color_histogram(img, args.histogram_step)
        report["histogram"] = h
        if not args.quiet:
            print(f"屏幕内容统计（步长 {h['step']}，采样 {h['sampled']} 点）："
                  f"不同颜色 {h['distinct_colors']} 种，平均色 {h['mean_rgb']}")
            for row in h["top"]:
                print(f"  RGB{tuple(row['rgb'])}  {row['pct']:6.2f}%")
    elif args.diff:
        try:
            other = read_ppm(args.diff)
        except (PPMError, OSError) as exc:
            print(f"!! 读取失败({args.diff}): {exc}", file=sys.stderr)
            return 2
        if (img.width, img.height) != (other.width, other.height):
            print(f"FAIL diff: 尺寸不同 "
                  f"{img.width}x{img.height} vs {other.width}x{other.height}")
            return 1
        x0, y0, x1, y1 = args.roi or (0, 0, img.width, img.height)
        x1, y1 = min(x1, img.width), min(y1, img.height)
        d = diff_exact(img, other, x0, y0, x1, y1)
        report["diff"] = d
        alive = d["changed_pixels"] >= args.min_changed
        local = d["changed_bbox_coverage"] <= args.max_bbox_coverage
        if not args.quiet:
            print(f"{'PASS' if alive else 'FAIL'} heartbeat_changed: "
                  f"变化像素 {d['changed_pixels']}（下限 {args.min_changed}，"
                  f"占 ROI {d['changed_ratio']:.4%}）")
            print(f"{'PASS' if local else 'FAIL'} heartbeat_localized: "
                  f"变化 bbox {d['changed_bbox']} 覆盖率 "
                  f"{d['changed_bbox_coverage']}（上限 {args.max_bbox_coverage}）")
        if alive and local:
            print("→ 两帧有局部差异：renderer 存活且 JS 在执行")
        else:
            print("→ 两帧无差异（renderer 已死 / 未绘制）或整屏重绘（闪屏）")
        if not (alive and local):
            exit_code = 1
    else:
        if args.profile == "legacy":
            checks = analyze(img, args.non_white_min, args.full_page_min_height)
        else:
            checks = analyze_official(img, args.profile, args.expect_input,
                                      args.full_page_min_height)
        tall = img.height >= args.full_page_min_height

        # 严格集：core 永远算；viewport 看画幅（且要够到该判据自己的 min_h）；
        # input 只在显式声明本轮有输入时才卡关。
        def _in_strict(c: Check) -> bool:
            need_h = c.min_h or args.full_page_min_height
            if c.group == "core":
                return True
            if c.group == "viewport":
                return img.height >= need_h
            if c.group == "input":
                return args.expect_input and img.height >= need_h
            return False

        strict_set = [c for c in checks if _in_strict(c)]
        info_set = [c for c in checks if c not in strict_set]
        report["profile"] = args.profile
        report["checks"] = [c.as_dict() for c in checks]
        report["strict_set"] = [c.name for c in strict_set]
        report["info_set"] = [c.name for c in info_set]
        report["viewport_in_frame"] = tall

        if not args.quiet:
            for c in checks:
                tag = {"core": "CORE", "viewport": "VIEW",
                       "info": "INFO", "input": "INPUT"}[c.group]
                if c in info_set and not c.passed:
                    tag = {"viewport": "WARN", "input": "SKIP"}.get(c.group, "INFO")
                print(f"{'PASS' if c.passed else 'FAIL'} [{tag}] {c.name}: {c.detail}")
            print("-" * 72)

        s_fail = [c for c in strict_set if not c.passed]
        report["strict_fail_count"] = len(s_fail)
        report["strict_fail_names"] = [c.name for c in s_fail]
        print(f"严格集 {len(strict_set) - len(s_fail)}/{len(strict_set)} 通过"
              + (f"；失败 {[c.name for c in s_fail]}" if s_fail else "")
              + f"｜严格集 = {[c.name for c in strict_set]}")
        if info_set:
            i_fail = [c.name for c in info_set if not c.passed]
            print(f"参考项（不卡关）：{[c.name for c in info_set]}"
                  + (f"；其中未通过 {i_fail}" if i_fail else ""))
        if not tall:
            print(f"⚠️ H={img.height} < {args.full_page_min_height}："
                  "棋盘/表格可能在视野之外，未纳入严格集——须人工目视复核")
        skipped_h = [c.name for c in info_set
                     if c.group in ("viewport", "input") and img.height < (c.min_h or 0)]
        if skipped_h:
            print(f"⚠️ 取景不够：{skipped_h} 需要更高的画幅才可能入镜"
                  f"（当前 H={img.height}）——这不是渲染失败，但**必须**用更高的"
                  "窗口/滚动后重截，否则该页的关键结论没有像素证据")
        if args.strict and s_fail:
            exit_code = 1

    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as fh:
            json.dump(report, fh, ensure_ascii=False, indent=2)
        if not args.quiet:
            print(f"JSON 已写入 {args.json_out}")

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
