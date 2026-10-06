#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
evidence_ppm2mp4.py — 把 QEMU monitor screendump 序列合成为演示视频

背景（为什么需要这个工具）
--------------------------
赛题六「演示效果 10 分」里有「完整流程录屏 6 分」。而本项目的 QEMU 是
**无头**跑的（命令行只有 `-vga none -serial mon:stdio`，没有 `-display`），
所以不存在可被桌面录屏软件抓取到的 QEMU 窗口。此时最诚实的「录屏」素材
就是 screendump 序列本身 —— 它是 virtio-gpu 的真实帧缓冲，与 §七(一)3
唯一认可的功能证据**同源**，因此天然满足「现象与数据可复现 4 分」。

本工具把 `evidence/<轮次>/screenshots/*.ppm` + `timestamps.csv` 合成为 mp4，
并把**真实拍摄时刻**烧进画面，使观看者能直接把画面与 timestamps.csv 对齐。

与 `run-session.py --interval` 的关系
------------------------------------
`run-session.py` 的 `screendump()` 每次要 ~3.2 s（Ctrl-A c 切 monitor →
`screendump` → Ctrl-A c 切回，中间有若干固定 sleep），因此**最密采样率约
0.3 fps**，比不了录像。所以本工具不追求平滑，而是追求**可核对**：
每帧按 `timestamps.csv` 的真实间隔停留，时间戳烧进画面。

两种合成模式
------------
1. `--fps N`（默认）：均匀 N fps，忽略真实间隔。适合密集采集，画面最"像录像"。
2. `--realtime [--speed S]`：按 timestamps.csv 的真实间隔播放，再整体加速 S 倍。
   例如 r5 是 60 s/帧共 10 帧（540 s），`--speed 20` → 27 s 视频，节奏与真实一致。

依赖
----
- **Pillow**：用于烧字与 PPM 解码（T490 已装 12.1.1）。若无，可 `pip3 install --user Pillow`。
- **ffmpeg**：用于编码。查找顺序 PATH → `imageio-ffmpeg` 捆绑的静态二进制。
  两者都没有时给出**无需 root** 的获取指引（见 --help 末尾）。

烧字只用 ASCII
--------------
Pillow 的 `load_default()` 位图字体不含 CJK 字形。本脚本的烧字文本一律构造为
ASCII（轮次名、文件名、时间戳本来也是 ASCII）；若系统能找到 CJK 字体则优先使用，
否则自动剥离非 ASCII 字符并告警，**绝不静默输出豆腐块**。

用法
----
    # 均匀 2 fps（最像录像，适合 interval 较小的轮次）
    python3 scripts/evidence_ppm2mp4.py \
        --evidence-dir evidence/2026-10-02_t490-single-initial-r5 --fps 2

    # 按真实间隔播放并加速 20 倍（适合 interval=60 的稀疏轮次）
    python3 scripts/evidence_ppm2mp4.py \
        --evidence-dir evidence/2026-10-02_t490-single-initial-r5 \
        --realtime --speed 20

    # 自检：只打印将要生成的帧表与时长，不编码
    python3 scripts/evidence_ppm2mp4.py --evidence-dir <dir> --dry-run
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PPM_GLOB = "screenshots/*.ppm"

# 查找 CJK 字体的候选路径（找到就用，找不到就只烧 ASCII）
CJK_FONT_CANDIDATES = [
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
    "/usr/share/fonts/truetype/arphic/uming.ttc",
    "C:/Windows/Fonts/msyh.ttc",
    "C:/Windows/Fonts/simhei.ttf",
]


# --------------------------------------------------------------------------- #
# ffmpeg 定位
# --------------------------------------------------------------------------- #
def find_ffmpeg() -> tuple[str | None, str]:
    """返回 (ffmpeg 路径或 None, 说明)。"""
    p = shutil.which("ffmpeg")
    if p:
        return p, "PATH"
    try:
        import imageio_ffmpeg  # type: ignore

        exe = imageio_ffmpeg.get_ffmpeg_exe()
        if exe and os.path.exists(exe):
            return exe, "imageio-ffmpeg 捆绑"
    except Exception:  # noqa: BLE001
        pass
    return None, "未找到"


NO_FFMPEG_HINT = """\
找不到 ffmpeg。两种**不需要 root** 的获取方式（任选其一，在 T490 上执行）：

  方式 A（推荐，静态二进制，约 80 MB，解到 ~/bin 即可）
    mkdir -p ~/bin && cd ~/bin
    wget https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz
    tar xf ffmpeg-release-amd64-static.tar.xz --strip-components=1 \\
        --wildcards '*/ffmpeg' '*/ffprobe'
    export PATH="$HOME/bin:$PATH"        # 建议写进 ~/.bashrc

  方式 B（借用 Python 包捆绑的静态 ffmpeg，更小）
    pip3 install --user imageio-ffmpeg
    # 之后本脚本会自动发现它，无需改 PATH

  方式 C（有 sudo 权限时）
    sudo apt install -y ffmpeg

注：一旦走「OBS / Kooha 录真实桌面」路线，就不需要本脚本了。
"""


# --------------------------------------------------------------------------- #
# 读取轮次证据
# --------------------------------------------------------------------------- #
def load_frames(evidence_dir: Path) -> list[tuple[float, Path]]:
    """返回按时间排序的 [(elapsed_sec, ppm路径), ...]。

    优先用 timestamps.csv 的真实时刻；缺失时退化为按文件名顺序、间隔 0（由
    uniform fps 模式兜底）。
    """
    shots_dir = evidence_dir / "screenshots"
    if not shots_dir.is_dir():
        raise SystemExit(f"[FAIL] 目录不存在：{shots_dir}")

    ts_csv = evidence_dir / "timestamps.csv"
    real: dict[str, float] = {}
    if ts_csv.is_file():
        with ts_csv.open(newline="", encoding="utf-8") as fh:
            for row in csv.reader(fh):
                if len(row) < 2 or row[0].strip().lower() == "elapsed_sec":
                    continue
                try:
                    real[row[1].strip()] = float(row[0])
                except ValueError:
                    continue

    frames: list[tuple[float, Path]] = []
    for ppm in sorted(shots_dir.glob("*.ppm")):
        t = real.get(ppm.name)
        if t is None:
            m = re.search(r"at(\d+)s", ppm.name) or re.search(r"(\d+)", ppm.name)
            t = float(m.group(1)) if m else float(len(frames))
        frames.append((t, ppm))

    if not frames:
        raise SystemExit(f"[FAIL] {shots_dir} 下没有 .ppm 文件")

    frames.sort(key=lambda x: (x[0], x[1].name))
    return frames


def load_font(size: int):
    """返回 (font, 是否含 CJK 字形)。"""
    for cand in CJK_FONT_CANDIDATES:
        if os.path.exists(cand):
            try:
                from PIL import ImageFont

                return ImageFont.truetype(cand, size), True
            except Exception:  # noqa: BLE001
                continue
    from PIL import ImageFont

    try:
        return ImageFont.load_default(size=size), False
    except TypeError:  # Pillow < 10 没有 size 参数
        return ImageFont.load_default(), False


def ascii_only(text: str) -> str:
    return text.encode("ascii", "replace").decode("ascii").replace("?", "-")


def burn_label(src: Path, dst: Path, label: str, has_cjk: bool) -> None:
    """把 label 烧到左上角，存成 PPM（P6），供 ffmpeg 直接吃。"""
    from PIL import Image, ImageDraw

    img = Image.open(src).convert("RGB")
    draw = ImageDraw.Draw(img)

    text = label if has_cjk else ascii_only(label)
    w, h = img.size
    font, _ = load_font(max(18, h // 32))
    pad = max(8, h // 80)

    box = draw.textbbox((0, 0), text, font=font)
    tw, th = box[2] - box[0], box[3] - box[1]

    # 半透明黑底 + 白字：先画到 overlay 再合成，避免破坏原始像素之外的东西
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    od.rectangle([0, 0, tw + 4 * pad, th + 3 * pad], fill=(0, 0, 0, 170))
    od.text((2 * pad, pad), text, font=font, fill=(255, 255, 255, 255))
    img = Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")

    img.save(dst, format="PPM")


# --------------------------------------------------------------------------- #
# 编码
# --------------------------------------------------------------------------- #
def encode_uniform(ffmpeg: str, frames: list[tuple[float, Path]], fps: float,
                   out: Path, tmp: Path, labeler) -> None:
    seq_dir = tmp / "seq"
    seq_dir.mkdir(parents=True, exist_ok=True)
    for i, (t, ppm) in enumerate(frames, 1):
        labeler(ppm, seq_dir / ("frame-%06d.ppm" % i), t)

    cmd = [
        ffmpeg, "-y", "-hide_banner", "-loglevel", "error",
        "-framerate", str(fps),
        "-i", str(seq_dir / "frame-%06d.ppm"),
        "-c:v", "libx264", "-preset", "medium", "-crf", "20",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart",
        str(out),
    ]
    subprocess.run(cmd, check=True)


def encode_realtime(ffmpeg: str, frames: list[tuple[float, Path]], speed: float,
                    out: Path, tmp: Path, labeler) -> float:
    """按真实间隔播放（整体加速 speed 倍）。返回视频总时长秒。"""
    seq_dir = tmp / "seq"
    seq_dir.mkdir(parents=True, exist_ok=True)

    listed: list[tuple[Path, float]] = []
    for i, (t, ppm) in enumerate(frames):
        dst = seq_dir / ("frame-%06d.ppm" % (i + 1))
        labeler(ppm, dst, t)
        if i + 1 < len(frames):
            dt = max(0.04, (frames[i + 1][0] - t) / speed)
        else:
            # 末帧：沿用上一段时长（没有下一帧可推算）
            dt = listed[-1][1] if listed else 1.0
        listed.append((dst, dt))

    concat = tmp / "concat.txt"
    with concat.open("w", encoding="utf-8", newline="\n") as fh:
        for path, dt in listed:
            fh.write("file '%s'\n" % path.as_posix())
            fh.write("duration %.4f\n" % dt)
        # concat demuxer 要求最后一帧再写一次，否则末段时长被丢弃
        fh.write("file '%s'\n" % listed[-1][0].as_posix())

    cmd = [
        ffmpeg, "-y", "-hide_banner", "-loglevel", "error",
        "-f", "concat", "-safe", "0", "-i", str(concat),
        # ★ 必须用 passthrough，不能用 `-r N -fps_mode cfr`。
        #   实测（ffmpeg 7.1，3 段 3.005s，计划 9.015s）：
        #     -r 25 -fps_mode cfr   -> 11.96 s（+33%，每段多约 1 s）
        #     -r 30 -fps_mode cfr   -> 11.97 s（同上）
        #     量化到 25fps 网格再 cfr -> 11.96 s（不是取整问题）
        #     -fps_mode passthrough ->  9.04 s（≈计划值，正确）
        #   concat demuxer 的 duration 与 cfr 重采样叠加会系统性膨胀，
        #   所以这里保留原始时间戳（VFR），让画面节奏与 timestamps.csv 一致。
        "-fps_mode", "passthrough",
        "-c:v", "libx264", "-preset", "medium", "-crf", "20",
        "-pix_fmt", "yuv420p", "-movflags", "+faststart",
        str(out),
    ]
    subprocess.run(cmd, check=True)
    return sum(dt for _, dt in listed)


def probe_duration(ffmpeg: str, path: Path) -> float | None:
    """回探产物真实时长（秒）。imageio-ffmpeg 只带 ffmpeg 不带 ffprobe，
    所以解析 `ffmpeg -i` 的 stderr。解析失败返回 None，绝不编数。"""
    try:
        proc = subprocess.run([ffmpeg, "-hide_banner", "-i", str(path)],
                              capture_output=True, text=True, errors="replace")
    except OSError:
        return None
    m = re.search(r"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)", proc.stderr or "")
    if not m:
        return None
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3))


# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser(
        description="把 QEMU screendump 序列合成为演示视频（零 root 依赖）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=NO_FFMPEG_HINT,
    )
    ap.add_argument("--evidence-dir", required=True,
                    help="证据轮次目录（其下应有 screenshots/*.ppm，可选 timestamps.csv）")
    ap.add_argument("--out", default="",
                    help="输出 mp4 路径（默认 report/rendered-videos/<轮次名>.mp4）")
    ap.add_argument("--fps", type=float, default=2.0,
                    help="均匀合成模式的帧率（默认 2）")
    ap.add_argument("--realtime", action="store_true",
                    help="按 timestamps.csv 的真实间隔播放（默认均匀 fps）")
    ap.add_argument("--speed", type=float, default=1.0,
                    help="realtime 模式下的整体加速倍数（默认 1）")
    ap.add_argument("--no-label", action="store_true", help="不烧时间戳")
    ap.add_argument("--dry-run", action="store_true", help="只打印帧表，不编码")
    args = ap.parse_args()

    ev = Path(args.evidence_dir).resolve()
    frames = load_frames(ev)
    # ★ 默认输出故意**不落在 evidence/ 内**：AGENTS.md 规定 evidence 是
    #   immutable evidence bundle，合成视频是派生产物，另存 report/rendered-videos/。
    out = (Path(args.out).resolve() if args.out
           else (Path.cwd() / "report" / "rendered-videos" / (ev.name + ".mp4")))

    span = frames[-1][0] - frames[0][0]
    print("=" * 68)
    print("证据轮次 :", ev.name)
    print("帧数     :", len(frames))
    print("时间跨度 : %.1f s  (%.1f min)" % (span, span / 60.0))
    if len(frames) > 1:
        gaps = [frames[i + 1][0] - frames[i][0] for i in range(len(frames) - 1)]
        print("帧间隔   : 中位 %.2f s，最小 %.2f s，最大 %.2f s"
              % (sorted(gaps)[len(gaps) // 2], min(gaps), max(gaps)))
    mode = "realtime x%.2f" % args.speed if args.realtime else "uniform %.2f fps" % args.fps
    print("合成模式 :", mode)
    print("输出     :", out)
    print("-" * 68)
    for t, p in frames:
        print("  T+%8.1fs  %s" % (t, p.name))
    print("=" * 68)

    if args.dry_run:
        print("[dry-run] 未编码。")
        return 0

    ffmpeg, how = find_ffmpeg()
    if not ffmpeg:
        print(NO_FFMPEG_HINT, file=sys.stderr)
        return 2
    print("ffmpeg   :", ffmpeg, "(%s)" % how)

    try:
        from PIL import Image  # noqa: F401
    except ImportError:
        print("[FAIL] 缺少 Pillow。执行：pip3 install --user Pillow", file=sys.stderr)
        return 2

    _, has_cjk = load_font(24)
    if not has_cjk and not args.no_label:
        print("[WARN] 未找到 CJK 字体，烧字将退化为 ASCII（丢弃非 ASCII 字符）。")

    def labeler(ppm: Path, dst: Path, t: float) -> None:
        if args.no_label:
            shutil.copy(ppm, dst)
            return
        burn_label(ppm, dst, "T+%04ds  |  %s" % (int(round(t)), ev.name), has_cjk)

    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ppm2mp4-") as td:
        tmp = Path(td)
        if args.realtime:
            planned = encode_realtime(ffmpeg, frames, args.speed, out, tmp, labeler)
            print("[INFO] realtime 计划时长 %.1f s（真实 %.1f s ÷ %.2f 倍速）"
                  % (planned, span, args.speed))
        else:
            encode_uniform(ffmpeg, frames, args.fps, out, tmp, labeler)

    real_dur = probe_duration(ffmpeg, out)
    if real_dur is not None:
        print("[OK] 产物实际时长 %.2f s" % real_dur)
    else:
        print("[WARN] 无法回探产物时长（ffmpeg 未输出 Duration 行）")

    size = out.stat().st_size
    print("[OK] 产物 %s (%.2f MB)" % (out, size / 1024 / 1024))
    return 0


if __name__ == "__main__":
    sys.exit(main())
