#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ppm_assert.py 官方页判据的**三重对照自检**（M2：未验证的门禁比没门禁更危险）。

为什么必须有这个脚本
--------------------
判据的价值全在"它会不会在**该失败的时候失败**"。legacy 那套谓词就是反面教材：
换到官方页后严格集 1/7，而唯一通过的那项 `js_executed_green_text` 还是**假阳性**
（无脚本的 index.html 被判成"JS 已执行"）。只测正对照永远发现不了这种事。

四类对照（全部可复现，不依赖 QEMU）：
  1. 正对照      参考图 × 各自 profile              → 严格集必须**全绿**
  2. 跨页负对照  参考图 × **别的页** profile        → 严格集必须**失败**
                 （否则判据根本分不出页面，等于没有判据）
  3. 合成负对照  在正对照图上做**定向破坏**          → 指定谓词必须翻成 FAIL
                 （破坏方式用判据自己的检测结果定位，不硬编码坐标）
  4. 真实负对照  guest 历史 screendump（别的画面）  → 严格集必须**失败**

用法
----
    # 参考 PPM 从 Chrome 无头渲染的 PNG 转来（png2ppm.py），或直接给 .ppm
    python3 scripts/t490/ppm_assert_selftest.py \
        --refs tmp/ref-ppm/ref-official-*.ppm \
        --real 'evidence/2026-09-2*/screenshots/shot-*.ppm' \
        [--real-limit 6] [--json tmp/selftest.json]

退出码：0 = 全部对照符合预期；1 = 有对照不符（判据不可信）
"""

import argparse
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ppm_assert as pa            # noqa: E402

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                    "..", ".."))


# --------------------------------------------------------------------------- #
# 图像工具（对 RGB 缓冲直接改像素；一律用 build-in loop 之后的 bytes 操作）
# --------------------------------------------------------------------------- #

def load(path):
    return pa.read_ppm(path)


def save(img, path):
    with open(path, "wb") as fh:
        fh.write(b"P6\n%d %d\n255\n" % (img.width, img.height))
        fh.write(img.raster)


def blank_like(img, rgb=(255, 255, 255)):
    return pa.PPM(img.width, img.height, 255, bytes(rgb) * (img.width * img.height), 0, "synthetic")


def paint_rect(img, x0, y0, x1, y1, rgb):
    """把 [x0,x1]×[y0,y1] 涂成 rgb（闭区间，越界自动裁剪）。"""
    buf = bytearray(img.raster)
    w, h = img.width, img.height
    x0, x1 = max(0, x0), min(w - 1, x1)
    y0, y1 = max(0, y0), min(h - 1, y1)
    row = bytes(rgb) * (x1 - x0 + 1)
    for y in range(y0, y1 + 1):
        o = (y * w + x0) * 3
        buf[o:o + len(row)] = row
    return pa.PPM(w, h, 255, bytes(buf), img.header_bytes, img.path)


def shift_band(img, x0, y0, x1, y1, dy, fill=(255, 255, 255)):
    """把矩形 [x0,x1]×[y0,y1] 整体下移 dy 行（原位置填 fill）。

    注意必须按**矩形**而不是整行带平移：index 页的四个色块共享同一条行带，
    平移整行会把四块一起搬走，"同行"关系毫发无损 —— 第一版对照就是这么写的，
    于是"破坏了却仍通过"，白跑一轮（自检脚本实测教训）。
    """
    buf = bytearray(img.raster)
    w, h = img.width, img.height
    stride, rw = w * 3, (x1 - x0 + 1) * 3
    rect = [bytes(buf[(y * w + x0) * 3:(y * w + x0) * 3 + rw])
            for y in range(y0, y1 + 1)]
    frow = bytes(fill) * (x1 - x0 + 1)
    for y in range(y0, y1 + 1):
        buf[(y * w + x0) * 3:(y * w + x0) * 3 + rw] = frow
    for i, row in enumerate(rect):
        ty = y0 + dy + i
        if 0 <= ty < h:
            buf[(ty * w + x0) * 3:(ty * w + x0) * 3 + rw] = row
    return pa.PPM(w, h, 255, bytes(buf), img.header_bytes, img.path)


# --------------------------------------------------------------------------- #
# 对照项
# --------------------------------------------------------------------------- #

def run_profile(img, profile, expect_input=False):
    checks = pa.analyze_official(img, profile, expect_input)
    res = {c.name: c.passed for c in checks}
    need_h = {c.name: (c.min_h or pa.FULL_PAGE_MIN_H) for c in checks}
    strict = [c.name for c in checks
              if c.group == "core"
              or (c.group == "viewport" and img.height >= need_h[c.name])
              or (c.group == "input" and expect_input and img.height >= need_h[c.name])]
    fails = [n for n in strict if not res[n]]
    return res, strict, fails


def checks_of(img, profile):
    return pa.analyze_official(img, profile, False)


def main() -> int:
    ap = argparse.ArgumentParser(description="官方页判据三重对照自检")
    ap.add_argument("--refs", nargs="+", required=True,
                    help="参考 PPM（正对照），支持通配符")
    ap.add_argument("--real", default=None,
                    help="真实历史 screendump（负对照），支持通配符")
    ap.add_argument("--real-limit", type=int, default=6, help="真实负对照最多取几张")
    ap.add_argument("--work-dir", default=os.path.join(REPO, "tmp", "selftest"),
                    help="合成对照图的落盘目录")
    ap.add_argument("--json", dest="json_out", default=None)
    args = ap.parse_args()

    refs = sorted(f for pat in args.refs for f in glob.glob(pat))
    if not refs:
        print("!! 没匹配到参考图", file=sys.stderr)
        return 2
    os.makedirs(args.work_dir, exist_ok=True)

    # 参考图 → 页面 → 画幅（从文件名解析：ref-official-<page>-<W>x<H>.ppm）
    positives = []
    for f in refs:
        base = os.path.basename(f)
        if "official-" not in base:
            continue
        page = base.split("official-")[1].split("-")[0]
        positives.append((f, f"official-{page}"))
    if not positives:
        print("!! 参考图文件名里没有 official-<page>-<W>x<H> 结构", file=sys.stderr)
        return 2

    report = {"positives": [], "cross_page": [], "synthetic": [], "real": []}
    bad = 0

    # ---- 1. 正对照 -------------------------------------------------------- #
    print("=" * 78)
    print("1. 正对照（参考图 × 各自 profile）—— 严格集必须全绿")
    print("=" * 78)
    for path, profile in positives:
        img = load(path)
        res, strict, fails = run_profile(img, profile)
        ok = not fails
        bad += 0 if ok else 1
        print(f"{'OK  ' if ok else 'BAD '} {os.path.basename(path):44s} {profile:22s} "
              f"严格集 {len(strict) - len(fails)}/{len(strict)}"
              + (f"  失败={fails}" if fails else ""))
        report["positives"].append({"file": path, "profile": profile,
                                    "strict": strict, "fails": fails, "ok": ok})

    # ---- 2. 跨页负对照 ---------------------------------------------------- #
    print("\n" + "=" * 78)
    print("2. 跨页负对照（参考图 × 别的页 profile）—— 严格集必须失败")
    print("=" * 78)
    for path, profile in positives:
        img = load(path)
        for other in ("official-index", "official-layout", "official-interaction"):
            if other == profile:
                continue
            _, strict, fails = run_profile(img, other)
            ok = bool(fails)                       # 必须失败
            bad += 0 if ok else 1
            print(f"{'OK  ' if ok else 'BAD '} {os.path.basename(path):44s} 用 {other:22s} "
                  f"→ 严格集失败 {len(fails)}/{len(strict)} {fails[:3]}")
            report["cross_page"].append({"file": path, "profile": other,
                                         "fails": fails, "ok": ok})

    # ---- 3. 合成负对照（定向破坏） ---------------------------------------- #
    print("\n" + "=" * 78)
    print("3. 合成负对照（定向破坏 → 指定谓词必须翻 FAIL）")
    print("=" * 78)

    def synth_case(name, img, profile, must_fail, must_pass=(), out=None):
        nonlocal bad
        res, strict, fails = run_profile(img, profile)
        f_ok = all(not res.get(n, True) for n in must_fail)
        p_ok = all(res.get(n, False) for n in must_pass)
        ok = f_ok and p_ok
        bad += 0 if ok else 1
        if out:
            save(img, os.path.join(args.work_dir, out))
        print(f"{'OK  ' if ok else 'BAD '} {name:52s} "
              f"应失败={list(must_fail)} 实际={'全FAIL' if f_ok else '有PASS!'}"
              + (f"  应通过={list(must_pass)} {'OK' if p_ok else '未通过!'}"
                 if must_pass else ""))
        report["synthetic"].append({"name": name, "profile": profile,
                                    "must_fail": list(must_fail),
                                    "must_pass": list(must_pass),
                                    "result": res, "ok": ok})
        return img

    ref_index = next((p for p, pr in positives if "index" in pr), None)
    ref_layout = next((p for p, pr in positives if "layout" in pr), None)

    # 3a 全白：所有形状类谓词都该失败
    if ref_index:
        img0 = load(ref_index)
        synth_case("全白画面（无任何特征）", blank_like(img0), "official-index",
                   must_fail=["official_banner", "index_blocks_shape",
                              "index_blocks_same_row", "index_blocks_equal_width",
                              "index_blocks_order", "index_table_rules"],
                   must_pass=["index_is_static"], out="s01_blank.ppm")

        # 3b 把绿块涂白 → 形状/等宽/顺序都必须失败
        green = pa.detect_official_block(img0, img0.channels(), "green")
        if green["valid"]:
            img1 = paint_rect(img0, green["x0"], green["y0"], green["x1"], green["y1"],
                              (255, 255, 255))
            synth_case("index 绿块被涂白（缺一块）", img1, "official-index",
                       must_fail=["index_blocks_shape", "index_blocks_equal_width",
                                  "index_blocks_order", "index_blocks_same_row"],
                       out="s02_green_missing.ppm")

        # 3c 把黄块**矩形**下移 25px → "同行"必须失败（其余仍成立）
        yel = pa.detect_official_block(img0, img0.channels(), "yellow")
        if yel["valid"]:
            img2 = shift_band(img0, yel["x0"], yel["y0"], yel["x1"], yel["y1"], 25)
            synth_case("index 黄块下移 25px（破坏同行）", img2, "official-index",
                       must_fail=["index_blocks_same_row"],
                       must_pass=["index_blocks_shape"], out="s03_yellow_shift.ppm")

        # 3d 抹掉 3 条表格横线 → 等间距签名必须失败
        ch = img0.channels()
        rows = [y for y, _ in pa.detect_long_lines(img0, ch, pa.OFFICIAL_RULE_RGB,
                                                   max(120, int(0.30 * img0.width)))]
        rows = pa.collapse_lines(rows)
        run = pa.even_pitch_run(rows)
        if len(run["lines"]) >= 4:
            img3 = img0
            for y in run["lines"][1:4]:
                img3 = paint_rect(img3, 0, y - 1, img0.width - 1, y + 1, (255, 255, 255))
            synth_case("index 抹掉表格中段 3 条横线", img3, "official-index",
                       must_fail=["index_table_rules"], out="s04_rules_broken.ppm")

    # 3e 在 index 上注入"未通过"红 → verdict_fail_absent 必须失败（三页共用谓词）
    if ref_index:
        img0 = load(ref_index)
        img4 = paint_rect(img0, 40, 430, 600, 470, (255, 235, 233))     # #ffebe9 条底
        img4 = paint_rect(img4, 60, 445, 200, 455, (201, 60, 55))       # #c93c37 文字
        synth_case("index 被注入「未通过」红条", img4, "official-index",
                   must_fail=["verdict_fail_absent"], out="s05_fail_injected.ppm")

    # 3f 在 index 上注入"通过"绿条 → index_is_static 哨兵必须失败（串页保护）
    if ref_index:
        img0 = load(ref_index)
        img5 = paint_rect(img0, 40, 430, 600, 466, (218, 251, 225))
        img5 = paint_rect(img5, 60, 445, 200, 455, (26, 127, 55))
        res, _, _ = run_profile(img5, "official-index")
        ok = not res.get("index_is_static", True)
        bad += 0 if ok else 1
        print(f"{'OK  ' if ok else 'BAD '} {'index 被注入「通过」绿条（串页保护）':52s} "
              f"应失败=['index_is_static'] 实际={'FAIL' if ok else 'PASS!'}")
        save(img5, os.path.join(args.work_dir, "s06_pass_injected.ppm"))
        report["synthetic"].append({"name": "index 注入通过绿条（串页保护）",
                                    "profile": "official-index",
                                    "must_fail": ["index_is_static"],
                                    "result": res, "ok": ok})

    # 3g 高画幅上合成"通过"绿条 → layout_verdict_pass 必须能 PASS（不能是恒失败谓词）
    if ref_layout:
        src = load(ref_layout)
        W, H = src.width, 1700
        rows = bytearray()
        blank = pa.PPM(W, H, 255, b"\xff" * (W * H * 3), 0, "synthetic")
        blank = paint_rect(blank, 216, 20, 1063, 103, (23, 69, 107))       # banner
        blank = paint_rect(blank, 233, 1450, 1046, 1486, (218, 251, 225))  # #dafbe1
        blank = paint_rect(blank, 250, 1460, 700, 1476, (26, 127, 55))     # #1a7f37
        res, strict, fails = run_profile(blank, "official-layout")
        ok = res.get("layout_verdict_pass", False)
        bad += 0 if ok else 1
        print(f"{'OK  ' if ok else 'BAD '} {'合成高画幅「通过」绿条（谓词可触发）':52s} "
              f"应通过=['layout_verdict_pass'] 实际={'PASS' if ok else 'FAIL!'}")
        save(blank, os.path.join(args.work_dir, "s07_tall_pass.ppm"))
        report["synthetic"].append({"name": "合成高画幅通过绿条", "profile": "official-layout",
                                    "must_pass": ["layout_verdict_pass"],
                                    "result": res, "ok": ok})

    # ---- 4. 真实负对照 ---------------------------------------------------- #
    if args.real:
        reals = sorted(glob.glob(args.real))[: args.real_limit]
        print("\n" + "=" * 78)
        print(f"4. 真实负对照（guest 历史 screendump，{len(reals)} 张）—— 严格集必须失败")
        print("=" * 78)
        for path in reals:
            img = load(path)
            for profile in ("official-index", "official-layout", "official-interaction"):
                _, strict, fails = run_profile(img, profile)
                ok = bool(fails)
                bad += 0 if ok else 1
                print(f"{'OK  ' if ok else 'BAD '} {os.path.basename(path)[:36]:38s} "
                      f"{os.path.basename(os.path.dirname(os.path.dirname(path)))[:22]:24s} "
                      f"{profile:22s} 失败 {len(fails)}/{len(strict)}")
                report["real"].append({"file": path, "profile": profile,
                                       "fails": fails, "ok": ok})

    # ---- 汇总 ------------------------------------------------------------- #
    print("\n" + "=" * 78)
    total = sum(len(v) for v in report.values())
    print(f"对照小结：{total - bad}/{total} 符合预期" + ("" if bad == 0
          else f"；⚠️ {bad} 项不符 → 判据不可信，必须先修"))
    print("=" * 78)
    report["summary"] = {"total": total, "bad": bad}
    if args.json_out:
        with open(args.json_out, "w", encoding="utf-8") as fh:
            json.dump(report, fh, ensure_ascii=False, indent=2)
        print(f"JSON 已写入 {args.json_out}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
