#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
vnc_grab.py — 最小 RFB(VNC) 客户端：从 QEMU 的 `-display vnc=` 抓一帧存为 PNG

为什么需要它
------------
`report/51` 的首选录屏路线是「QEMU 开 `-display vnc=<IP>:0` → 远端 VNC 客户端录制」。
但"VNC 服务在监听"不等于"VNC 真的送出了 virtio-gpu 的画面" —— 在
`-vga none` + `virtio-gpu-pci` 的组合下，VNC 有可能拿到一个空/黑帧。
所以必须有**工具化**的验证手段，而不是靠人肉看一眼客户端。

本脚本实现 RFB 3.8 协议中刚好够用的一条路径：
    握手 → 选 None 安全类型 → 只声明 raw(0) 编码 → 请求整屏 → 收帧 → 存 PNG

**只依赖 Python 标准库**（socket/struct/zlib），无需 Pillow，T490 与 Windows 都能跑。

局限性（如实声明）
------------------
- 只申请 **raw** 编码，不解析 Tight/ZRLE/Hextile；QEMU 会因此用 raw 发全帧
  （1280×800×4 ≈ 4 MB），够用但慢；
- 不处理多屏（`-display vnc` 单屏）、不处理 `DesktopSize` 伪编码（本场景分辨率固定）；
- 不实现 VNC 密码认证（对应 QEMU 未设 `password=on` 的情况）。

用法
----
    # 抓一帧
    python3 scripts/vnc_grab.py --host 192.168.1.217 --port 5900 --out tmp/vnc-frame.png

    # 只做握手探测，不抓帧（CI/冒烟用）
    python3 scripts/vnc_grab.py --host 192.168.1.217 --port 5900 --probe

    # 连续抓 N 帧，每帧间隔秒数
    python3 scripts/vnc_grab.py --host 192.168.1.217 --port 5900 \
        --out tmp/vnc-%02d.png --frames 3 --interval 5
"""

from __future__ import annotations

import argparse
import socket
import struct
import sys
import time
import zlib
from pathlib import Path

# RFB 消息类型（服务端 -> 客户端）
S2C_FRAMEBUFFER_UPDATE = 0
S2C_SET_COLOUR_MAP = 1
S2C_BELL = 2
S2C_SERVER_CUT_TEXT = 3


class RfbError(RuntimeError):
    pass


# --------------------------------------------------------------------------- #
# PNG 写出（纯标准库：zlib + struct）
# --------------------------------------------------------------------------- #
def write_png(path: Path, width: int, height: int, rgb: bytearray) -> None:
    """把 RGB 字节流写成 PNG（每行前置 filter 字节 0）。"""
    raw = bytearray()
    stride = width * 3
    for y in range(height):
        raw.append(0)
        raw += rgb[y * stride:(y + 1) * stride]

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)  # 8bit truecolour RGB
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
           + chunk(b"IEND", b""))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


# --------------------------------------------------------------------------- #
def recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise RfbError("连接在读取 %d 字节时被对端关闭（已收到 %d）" % (n, len(buf)))
        buf += chunk
    return bytes(buf)


def handshake(sock: socket.socket, verbose: bool) -> tuple[int, int, str]:
    """完成版本/安全/初始化握手，返回 (width, height, server_name)。"""
    ver = recv_exact(sock, 12)
    if verbose:
        print("  服务端版本:", ver.decode("ascii", "replace").strip())
    if not ver.startswith(b"RFB "):
        raise RfbError("不是 RFB 协议（首 12 字节=%r）" % ver)

    # 回 3.8；若服务端仅支持 3.3/3.7 也能被接受（QEMU 支持 3.8）
    sock.sendall(b"RFB 003.008\n")

    n_types = recv_exact(sock, 1)[0]
    if n_types == 0:
        reason_len = struct.unpack(">I", recv_exact(sock, 4))[0]
        raise RfbError("服务端拒绝连接: %s"
                       % recv_exact(sock, reason_len).decode("utf-8", "replace"))
    types = list(recv_exact(sock, n_types))
    if verbose:
        print("  安全类型:", types)
    if 1 not in types:  # 1 = None
        raise RfbError("服务端未提供 None(1) 安全类型，本脚本不实现密码认证；类型=%s" % types)
    sock.sendall(bytes([1]))

    result = struct.unpack(">I", recv_exact(sock, 4))[0]
    if result != 0:
        raise RfbError("安全握手失败，SecurityResult=%d" % result)

    sock.sendall(bytes([1]))  # ClientInit: shared=1

    hdr = recv_exact(sock, 24)
    width, height = struct.unpack(">HH", hdr[:4])
    name_len = struct.unpack(">I", hdr[20:24])[0]
    name = recv_exact(sock, name_len).decode("utf-8", "replace") if name_len else ""
    if verbose:
        print("  服务端名称:", name or "(空)")
    if width == 0 or height == 0:
        raise RfbError("服务端报告 %dx%d 尺寸，无法抓帧" % (width, height))
    return width, height, name


def set_pixel_format_and_encodings(sock: socket.socket, verbose: bool) -> None:
    """要求 32bpp / 24depth / 小端 / RGB 顺序，且只声明 raw 编码。"""
    # SetPixelFormat
    sock.sendall(bytes([0, 0, 0, 0]) + struct.pack(
        ">BBBBHHHBBBxxx",
        32,     # bits-per-pixel
        24,     # depth
        0,      # big-endian-flag = 0（小端）
        1,      # true-colour-flag
        255, 255, 255,   # max R/G/B
        # 以下 3 个 shift + 3 pad 由格式串的 BBBxxx 承载
        16, 8, 0,
    ))
    # SetEncodings: raw(0) 一个
    sock.sendall(struct.pack(">BBH", 2, 0, 1) + struct.pack(">i", 0))
    if verbose:
        print("  已声明像素格式 32bpp/24depth/LE 与 raw 编码")


def grab_one(sock: socket.socket, width: int, height: int, verbose: bool) -> bytearray:
    """请求整屏一次，收 raw 帧，返回 RGB 字节流。"""
    sock.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, width, height))

    canvas = bytearray(width * height * 3)

    while True:
        msg = recv_exact(sock, 1)[0]
        if msg == S2C_BELL:
            continue
        if msg == S2C_SET_COLOUR_MAP:
            recv_exact(sock, 3)
            first, num = struct.unpack(">HH", recv_exact(sock, 4))
            recv_exact(sock, 6 * num)
            continue
        if msg == S2C_SERVER_CUT_TEXT:
            # 结构：pad(3) + length(4) + text(length)
            recv_exact(sock, 3)
            n = struct.unpack(">I", recv_exact(sock, 4))[0]
            recv_exact(sock, n)
            continue
        if msg != S2C_FRAMEBUFFER_UPDATE:
            raise RfbError("未知服务端消息类型 %d" % msg)
        break

    recv_exact(sock, 1)  # padding
    n_rects = struct.unpack(">H", recv_exact(sock, 2))[0]
    if verbose:
        print("  收到 FramebufferUpdate，矩形数=%d" % n_rects)

    for i in range(n_rects):
        rx, ry, rw, rh = struct.unpack(">HHHH", recv_exact(sock, 8))
        enc = struct.unpack(">i", recv_exact(sock, 4))[0]
        if enc != 0:
            raise RfbError("矩形 %d 使用非 raw 编码 %d（我们只声明了 raw，不应发生）" % (i, enc))
        data = recv_exact(sock, rw * rh * 4)
        # 小端 32bpp，shift R=16 G=8 B=0  =>  内存序为 B,G,R,X
        for y in range(rh):
            src = y * rw * 4
            dst = ((ry + y) * width + rx) * 3
            for x in range(rw):
                b0 = data[src + x * 4]
                b1 = data[src + x * 4 + 1]
                b2 = data[src + x * 4 + 2]
                canvas[dst + x * 3] = b2      # R
                canvas[dst + x * 3 + 1] = b1  # G
                canvas[dst + x * 3 + 2] = b0  # B
    return canvas


def is_all_black(rgb: bytearray) -> bool:
    return not any(rgb)


def sample_nonblack_ratio(rgb: bytearray, step: int = 997) -> float:
    """抽样统计非黑像素比例（全量遍历在 3 MB 上也很快，但抽样更直观）。"""
    n = 0
    hit = 0
    for i in range(0, len(rgb) - 2, 3 * step):
        n += 1
        if rgb[i] or rgb[i + 1] or rgb[i + 2]:
            hit += 1
    return (hit / n) if n else 0.0


# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser(description="最小 RFB 客户端：抓 QEMU VNC 的一帧")
    ap.add_argument("--host", required=True)
    ap.add_argument("--port", type=int, default=5900)
    ap.add_argument("--out", default="vnc-frame.png", help="输出 PNG（支持 %%02d 占位）")
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--probe", action="store_true", help="只握手，不抓帧")
    ap.add_argument("--frames", type=int, default=1)
    ap.add_argument("--interval", type=float, default=5.0)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()
    v = not args.quiet

    for k in range(args.frames):
        if k:
            time.sleep(args.interval)
        try:
            with socket.create_connection((args.host, args.port), timeout=args.timeout) as s:
                s.settimeout(args.timeout)
                if v:
                    print("[%d/%d] 连接 %s:%d" % (k + 1, args.frames, args.host, args.port))
                w, h, name = handshake(s, v)
                if v:
                    print("  分辨率: %dx%d  (%.2f MB/帧 raw)" % (w, h, w * h * 4 / 1048576))
                if args.probe:
                    print("[OK] RFB 握手成功：%dx%d，名称=%r" % (w, h, name))
                    continue
                set_pixel_format_and_encodings(s, v)
                rgb = grab_one(s, w, h, v)
        except (RfbError, OSError) as exc:
            print("[FAIL] %s" % exc, file=sys.stderr)
            return 2

        out = Path(args.out % k if "%" in args.out else args.out)
        write_png(out, w, h, rgb)
        ratio = sample_nonblack_ratio(rgb)
        verdict = "全黑" if is_all_black(rgb) else "有内容"
        print("[OK] %s  %dx%d  %.2f MB  非黑像素抽样 %.1f%%  -> %s"
              % (out, w, h, out.stat().st_size / 1048576, ratio * 100, verdict))
        if is_all_black(rgb):
            print("[WARN] 该帧全黑。若 screendump 同轮有内容，说明 VNC 通路未取到 "
                  "virtio-gpu 画面（-vga none 下的已知风险），不要当成录屏可用。",
                  file=sys.stderr)
            return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
