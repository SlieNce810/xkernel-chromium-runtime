#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
run-session.py — 赛题六 基础任务 · QEMU 会话编排与 screendump 取证

作用
----
1. 在带伪终端(pty)的子进程里启动 `make run ...`，这样 QEMU 的
   `-serial mon:stdio` 复用通道可被程序化控制（真实终端才会正确处理 Ctrl-A）。
2. 把串口 + QEMU 全部输出**带时间戳**落盘成 console.log（= 启动日志证据）。
3. 周期性切到 QEMU monitor 执行 screendump，产出**赛题唯一认可的截图证据**。
4. 支持在指定时刻向 guest 串口"敲命令"（例如手工拉起 xk-weston-start）。
5. 结束时生成 manifest.txt（宿主机指纹 + tag + 完整命令），供评委交叉核验。
6. **落盘字面 QEMU 命令行**（用 `make justrun XKMAKE_ARGS=--dry-run` 抓取，不启动 QEMU），
   使 cmd.txt 里的「完整运行命令」能直接自证第七节(一)3 的设备组合与纯 TCG。
7. **平台合规断言**：对实跑命令行逐条核对赛题第七节(一)1/2/3，产出
   `platform-compliance.txt`；加 `--require-platform-compliance` 可让不达标时直接拒跑。

必须在 Linux 主机运行。

用法示例
--------
# 10 分钟 Weston 长稳 + 每 60s 截图（带键鼠、合规门禁）
python3 scripts/run-session.py \\
    --cwd ~/x-kernel \\
    --make-args 'GRAPHIC=y ACCEL=n MEM=4g SMP=4 VSOCK=n' --with-input \\
    --require-platform-compliance \\
    --duration 660 --interval 60 \\
    --out evidence/s9-weston-10min

# 启动 90 秒后向 guest 敲一条命令
python3 scripts/run-session.py --cwd ~/x-kernel \\
    --make-args 'GRAPHIC=y ACCEL=n MEM=4g' \\
    --duration 300 --interval 60 \\
    --send '90:XK_WESTON_CLIENT=none /usr/local/bin/xk-weston-start' \\
    --out evidence/s8-manual-weston

# 带虚拟键鼠（赛题第七节(一)3 要求的 virtio-input；xkmake 默认不加！）
python3 scripts/run-session.py --cwd ~/x-kernel \\
    --make-args 'GRAPHIC=y ACCEL=n MEM=4g SMP=4' --with-input \\
    --duration 300 --out evidence/s6-with-input

# 只跑已有镜像、不重新编译（用 DISK_IMG 这个 make 变量，别用 XKMAKE_ARGS：
# 带空格的变量值经多层传递极易被拆开、被 make 当成构建目标）
python3 scripts/run-session.py --cwd ~/x-kernel \\
    --make-args 'GRAPHIC=y ACCEL=n MEM=4g DISK_IMG=images/dev-baseline-weston.img'

产物（证据目录）
----------------
env.txt                 宿主机指纹（CPU/内存/QEMU/OS + **git_commit/git_describe**）
console.log             带时间戳的串口 + QEMU 全量输出
cmd.txt                 完整运行命令（含**字面 qemu-system-aarch64 行**）
platform-compliance.txt 赛题第七节平台合规逐条断言
timestamps.csv          截图时间戳
manifest.txt            会话清单
screenshots/*.ppm       QEMU monitor screendump（唯一认可的功能证据）
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import os
import platform
import select
import shlex
import signal
import subprocess
import sys
import time

# pty / termios / tty 都是 Unix 专有模块，Windows 上不存在。
# 这里做**惰性导入**：--dry-run 与参数校验在 Windows 上也能跑，
# 只有真正要启动 QEMU 会话时才需要 Linux。
_PTY_IMPORT_ERROR = None
try:
    import pty  # noqa: F401
except ImportError as exc:  # pragma: no cover - Windows only
    pty = None            # type: ignore[assignment]
    _PTY_IMPORT_ERROR = exc


def require_unix_pty() -> None:
    if pty is None:
        sys.stderr.write(
            "\n".join([
                "",
                "=" * 70,
                " 错误：本脚本需要 Unix 伪终端（pty/termios），当前 Python 环境不支持。",
                f" 原始错误：{_PTY_IMPORT_ERROR}",
                "",
                " 原因：x-kernel 的构建与 QEMU 取证必须在 Linux 上进行",
                "       （Windows 无 debugfs / musl 交叉工具链 / QEMU ≥8.0）。",
                "",
                " 正确做法：把本仓库 rsync/scp 到 Linux 主机后再运行；",
                "           或先用 --dry-run 在当前环境校验参数与输出目录。",
                "=" * 70,
                "",
            ]))
        sys.exit(3)

CTRL_A = b"\x01"
TO_MONITOR = CTRL_A + b"c"
QUIT_QEMU = CTRL_A + b"x"


def ts() -> str:
    return dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def stamp_iso() -> str:
    return dt.datetime.now().isoformat(timespec="milliseconds")


class Session:
    def __init__(self, argv: list[str], cwd: str, log_path: str, verbose: bool = True):
        self.argv = argv
        self.cwd = cwd
        self.verbose = verbose
        self.log_f = open(log_path, "wb", buffering=0)
        self.tail: list[str] = []
        self.master, slave = pty.openpty()
        self.proc = subprocess.Popen(
            argv,
            cwd=cwd,
            stdin=slave,
            stdout=slave,
            stderr=slave,
            close_fds=True,
            start_new_session=True,
        )
        os.close(slave)
        os.set_blocking(self.master, False)
        self.write(f"### [{ts()}] SESSION START\n")
        self.write("### cwd: %s\n" % cwd)
        self.write("### argv: %s\n" % " ".join(shlex.quote(a) for a in argv))

    # ---------- io ----------
    def write(self, data):
        if isinstance(data, str):
            data = data.encode("utf-8", "replace")
        self.log_f.write(data)
        if self.verbose:
            sys.stdout.buffer.write(data)
            sys.stdout.flush()

    def to_child(self, data: bytes):
        try:
            os.write(self.master, data)
        except OSError as exc:  # child 已退出
            self.write("### write to child failed: %s\n" % exc)

    def pump(self, timeout: float = 0.2) -> int:
        """把子进程当前可用输出搬到日志。返回搬运的字节数。"""
        total = 0
        deadline = time.time() + timeout
        while time.time() < deadline:
            r, _, _ = select.select([self.master], [], [], max(0.0, deadline - time.time()))
            if not r:
                break
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                break
            if not chunk:
                break
            self.write(chunk)
            total += len(chunk)
            self._keep_tail(chunk)
        return total

    def _keep_tail(self, chunk: bytes):
        text = chunk.decode("utf-8", "replace")
        self.tail.append(text)
        if len(self.tail) > 400:
            self.tail = self.tail[-200:]

    def tail_text(self, n: int = 4000) -> str:
        return "".join(self.tail)[-n:]

    def alive(self) -> bool:
        return self.proc.poll() is None

    # ---------- monitor ----------
    def screendump(self, host_path: str) -> bool:
        """切到 monitor → screendump → 切回串口。"""
        os.makedirs(os.path.dirname(host_path) or ".", exist_ok=True)
        if os.path.exists(host_path):
            os.unlink(host_path)
        self.write("\n### [%s] MONITOR: screendump %s\n" % (ts(), host_path))
        self.to_child(TO_MONITOR)
        time.sleep(0.6)
        self.pump(0.4)
        self.to_child(("screendump %s\n" % host_path).encode())
        time.sleep(1.0)
        self.pump(0.6)
        self.to_child(TO_MONITOR)          # 切回串口
        time.sleep(0.3)
        self.pump(0.3)
        ok = os.path.exists(host_path) and os.path.getsize(host_path) > 0
        self.write("### [%s] screendump %s (%s)\n" % (
            ts(), "OK" if ok else "FAILED",
            ("%d bytes" % os.path.getsize(host_path)) if ok else "no file"))
        return ok

    def send_guest(self, text: str):
        """向 guest 串口敲一行命令（mux 处于串口一侧时生效）。"""
        self.write("\n### [%s] SEND-GUEST: %s\n" % (ts(), text))
        self.to_child(text.encode() + b"\n")
        time.sleep(0.6)
        self.pump(0.6)

    # ---------- shutdown ----------
    def stop(self, grace: float = 6.0):
        self.write("\n### [%s] stopping session...\n" % ts())
        self.to_child(QUIT_QEMU)           # Ctrl-A x 让 QEMU 正常退出
        end = time.time() + grace
        while time.time() < end and self.alive():
            self.pump(0.3)
        if self.alive():
            self.write("### QEMU 未响应 Ctrl-A x，发送 SIGTERM\n")
            try:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
            except OSError:
                pass
            end = time.time() + grace
            while time.time() < end and self.alive():
                self.pump(0.3)
        if self.alive():
            self.write("### 仍存活，发送 SIGKILL\n")
            try:
                os.killpg(os.getpgid(self.proc.pid), signal.SIGKILL)
            except OSError:
                pass
        self.pump(0.3)
        rc = self.proc.poll()
        self.write("### [%s] SESSION END (exit=%s)\n" % (ts(), rc))
        try:
            os.close(self.master)
        except OSError:
            pass
        self.log_f.close()
        return rc


def host_fingerprint(git_cwd: str = ".") -> list[str]:
    """宿主机指纹 —— 赛题第七节(二)4「注明宿主机 CPU 型号、内存、QEMU 版本与操作系统」。

    ``git_cwd`` 必须是 **x-kernel 仓库目录**（即 ``--cwd``）。
    ⚠️ 历史缺陷（report/14 §4 D2）：此处原为 ``cwd="."``，取的是**启动脚本时的当前目录**，
    而它通常不是 git 仓库 —— git 静默失败、stderr 被丢弃，于是 ``env.txt`` 的
    ``git_describe`` / ``git_commit`` **恒为空**，直接违反第七节(二)3
    「提交时存档 git tag 与原始数据，组委会复核存档代码」。
    """
    lines = [f"timestamp        : {stamp_iso()}",
             f"hostname         : {platform.node()}",
             f"os               : {platform.platform()}",
             f"guest_arch       : aarch64  (赛题第七节(一)1 指定，不接受其他架构)",
             f"git_cwd          : {os.path.abspath(os.path.expanduser(git_cwd))}"]
    try:
        with open("/etc/os-release", encoding="utf-8") as fh:
            for ln in fh:
                if ln.startswith("PRETTY_NAME="):
                    lines.append("os_pretty        : " + ln.split("=", 1)[1].strip().strip('"'))
                    break
    except OSError:
        pass
    lines.append(f"machine          : {platform.machine()}")
    # 赛题第七节(一)2：全部评分数据必须出自纯 TCG。宿主架构 ≠ guest(aarch64) 时
    # xkmake 的 hardware_accel() 天然返回 None，即"不传 ACCEL 也拿不到加速"；
    # 但提交时仍须显式写 ACCEL=n，让判据一眼可见。
    _host_arch = platform.machine()
    lines.append(
        "host_vs_guest    : %s %s aarch64 （%s）"
        % (_host_arch, "==" if _host_arch == "aarch64" else "!=",
           "同架构，必须显式 ACCEL=n 才能保证纯 TCG"
           if _host_arch == "aarch64" else "跨架构，硬件加速不可能生效（仍显式 ACCEL=n）"))
    try:
        with open("/proc/cpuinfo", encoding="utf-8") as fh:
            for ln in fh:
                if ln.lower().startswith("model name"):
                    lines.append("cpu_model        : " + ln.split(":", 1)[1].strip())
                    break
        with open("/proc/cpuinfo", encoding="utf-8") as fh:
            lines.append("cpu_logical      : %d" % sum(1 for l in fh if l.startswith("processor")))
    except OSError:
        pass
    try:
        with open("/proc/meminfo", encoding="utf-8") as fh:
            for ln in fh:
                if ln.startswith("MemTotal"):
                    kb = int(ln.split()[1])
                    lines.append("mem_total        : %.1f GiB" % (kb / 1048576))
                    break
    except OSError:
        pass
    for tool, args in (("qemu-system-aarch64", ["--version"]),):
        try:
            out = subprocess.run([tool] + args, capture_output=True, text=True, timeout=10)
            first = (out.stdout or out.stderr).splitlines()
            lines.append(f"{tool:16s} : " + (first[0] if first else "?"))
        except Exception:
            lines.append(f"{tool:16s} : NOT FOUND")
    try:
        with open("/proc/sys/kernel/osrelease", encoding="utf-8") as fh:
            rel = fh.read().strip()
        if "microsoft" in rel.lower():
            lines.append("wsl              : YES (xkmake 会排除 KVM，但建议用原生 Linux)")
    except OSError:
        pass
    # ---- git 追溯（赛题第七节(二)3）----
    # 用 `git -C <git_cwd>` 显式指定仓库，**不用 cwd=**：本脚本的工作目录是
    # x-kernel 之外的编排目录（T490 上是 ~/xk6），在那里跑 git 会静默失败。
    for sub, label in ((("describe", "--tags", "--always", "--dirty"), "git_describe"),
                       (("rev-parse", "HEAD"), "git_commit")):
        try:
            out = subprocess.run(["git", "-C", git_cwd, *sub],
                                 capture_output=True, text=True, timeout=10)
            lines.append(f"{label:16s} : {out.stdout.strip()}")
        except Exception as exc:  # noqa: BLE001
            lines.append(f"{label:16s} : ? ({exc})")
    try:
        # disk_free 必须是 **镜像所在分区**（x-kernel 仓库目录），不是脚本所在分区
        st = os.statvfs(git_cwd)                   # Unix only
        lines.append("disk_free        : %.1f GiB (%s)"
                     % (st.f_bavail * st.f_frsize / 1073741824,
                        os.path.abspath(os.path.expanduser(git_cwd))))
    except AttributeError:                          # Windows
        try:
            import shutil as _sh
            lines.append("disk_free        : %.1f GiB (%s)"
                         % (_sh.disk_usage(git_cwd).free / 1073741824,
                            os.path.abspath(os.path.expanduser(git_cwd))))
        except Exception:  # noqa: BLE001
            lines.append("disk_free        : ?")
    except OSError:
        lines.append("disk_free        : ?")
    return lines


# 赛题第七节(一)3 要求的设备组合（字面形态，用于对 QEMU 命令行做机器断言）
REQUIRED_DEVICES = ("virtio-gpu-pci", "virtio-blk-pci", "virtio-net-pci",
                    "virtio-keyboard-pci", "virtio-mouse-pci")


def capture_qemu_cmdline(argv: list[str], cwd: str, no_make: bool,
                         timeout: float = 180.0) -> tuple[str, str]:
    """抓取 xkmake 干跑打印的**字面** QEMU 命令行。

    赛题第七节(一)3 要求「提供完整运行命令」，但历史 ``cmd.txt`` 只记 ``make`` 命令
    （report/14 §4 D3）：评委从里面**只能看到 2 类 virtio 设备** ——
    ``virtio-keyboard/mouse-pci`` 来自 ``QEMU_ARGS`` 字面出现在 make 命令行里，
    而 ``virtio-gpu-pci`` / ``virtio-blk-pci`` / ``virtio-net-pci`` 是 xkmake 内部生成的，
    一个都看不到；「无 ``-accel``」也只能间接推断。

    这里用 ``make justrun XKMAKE_ARGS=--dry-run``：
    ``justrun`` = ``xkmake run --no-build``，配 ``--dry-run`` **只打印、不启动 QEMU**。

    返回 ``(命令行文本, 说明)``。命令行文本为空串表示抓取失败（不致命）。
    """
    if no_make:
        return " ".join(shlex.quote(a) for a in argv), "--no-make：argv 即最终命令"
    if any(a.startswith("XKMAKE_ARGS=") for a in argv):
        return "", "make_args 已含 XKMAKE_ARGS，跳过干跑以免与之冲突"
    dry_argv = ["make", "justrun", "XKMAKE_ARGS=--dry-run", *argv[2:]]
    try:
        out = subprocess.run(dry_argv, cwd=cwd, capture_output=True,
                             text=True, timeout=timeout)
    except Exception as exc:  # noqa: BLE001
        return "", "干跑失败: %s" % exc
    block: list[str] = []
    started = False
    for ln in ((out.stdout or "") + (out.stderr or "")).splitlines():
        if not started:
            if ln.startswith("qemu-system-aarch64"):
                started = True
            else:
                continue
        block.append(ln)
        if not ln.rstrip().endswith("\\"):
            break
    if not block:
        return "", "干跑输出中未找到 qemu-system-aarch64 行"
    return "\n".join(block), "ok"


def check_platform_compliance(qemu_cmdline: str, out_dir: str) -> tuple[bool, int, int]:
    """把赛题第七节的平台要求对**实际 QEMU 命令行**逐条断言，结果落盘。

    产出 ``<out_dir>/platform-compliance.txt``（可归档）。
    返回 ``(是否全部通过, PASS 数, FAIL 数)``。
    """
    rows: list[str] = []
    n_pass = 0
    n_fail = 0

    def row(kind: str, text: str) -> None:
        nonlocal n_pass, n_fail
        if kind == "PASS":
            n_pass += 1
        elif kind == "FAIL":
            n_fail += 1
        rows.append("[%s] %s" % (kind, text))

    rows.append("赛题六 · 第七节 统一评测平台 —— 实跑命令行合规断言")
    rows.append("=" * 70)

    if not qemu_cmdline:
        row("FAIL", "无法获得字面 QEMU 命令行 → 无法自证设备组合与纯 TCG")
        rows.append("")
        rows.append("不得用本轮数据作为评分证据。")
        with open(os.path.join(out_dir, "platform-compliance.txt"), "w",
                  encoding="utf-8") as fh:
            fh.write("\n".join(rows) + "\n")
        return False, n_pass, n_fail

    flat = " ".join(qemu_cmdline.split())          # 压平续行
    # xkmake 会给含逗号/冒号的值加单引号（如 -machine 'virt,gic-version=3'、
    # -serial 'mon:stdio'）→ 断言前必须去掉引号，否则会产生**假 FAIL**。
    norm = flat.replace("'", "").replace('"', "")
    rows.append("QEMU 命令行（xkmake --dry-run 抓取的字面行）：")
    rows.append("  " + flat)
    rows.append("")

    # ---- 七(一)2 纯 TCG ----
    row("PASS" if "-accel" not in norm else "FAIL",
        "命令行无任何 -accel（纯 TCG 唯一硬判据）")
    for backend in ("kvm", "hvf"):
        row("PASS" if ("-accel=%s" % backend) not in norm else "FAIL",
            "命令行无 -accel=%s" % backend)
    row("PASS" if "-cpu cortex-a76" in norm else "FAIL",
        "命令行含 -cpu cortex-a76（非 host，本身即 TCG 证据）")
    row("PASS" if "-machine virt,gic-version=3" in norm else "FAIL",
        "命令行含 -machine virt,gic-version=3（AArch64 virt 平台）")

    # ---- 七(一)1 / 内存与 CPU 数 ----
    row("PASS" if "-m 4g" in norm else "FAIL",
        "命令行含 -m 4g（裸 make run 会落到 -m 1g，跑 Chromium 会 OOM）")
    row("PASS" if "-smp 4" in norm else "FAIL", "命令行含 -smp 4")

    # ---- 七(一)3 设备组合 ----
    for dev in REQUIRED_DEVICES:
        row("PASS" if dev in norm else "FAIL", "设备组合含 %s" % dev)

    # ---- 七(一)3 取证通路 ----
    row("PASS" if "-serial mon:stdio" in norm else "FAIL",
        "命令行含 -serial mon:stdio（screendump 取证通路）")
    row("PASS" if "-nographic" not in norm else "FAIL",
        "命令行不含 -nographic（否则无图形窗口）")
    row("PASS" if "-device virtio-gpu-pci" in norm else "FAIL",
        "命令行含 -device virtio-gpu-pci（图形后端）")

    rows.append("")
    rows.append("PASS=%d  FAIL=%d" % (n_pass, n_fail))
    rows.append("PLATFORM_COMPLIANT" if n_fail == 0
                else "PLATFORM_NOT_COMPLIANT")
    with open(os.path.join(out_dir, "platform-compliance.txt"), "w",
              encoding="utf-8") as fh:
        fh.write("\n".join(rows) + "\n")
    return n_fail == 0, n_pass, n_fail


def write_cmd_txt(path: str, cwd: str, make_args: str, argv: list[str],
                  qemu_cmdline: str, qemu_note: str, out: str,
                  duration: float, interval: float,
                  sends: list[tuple[float, str]]) -> None:
    """落盘 cmd.txt —— 赛题要求「提供完整运行命令」。

    必须同时包含：
      ① 人敲的命令（脚本命令行 / make 命令行）
      ② **机器实际执行的命令**（字面 ``qemu-system-aarch64 …``，来自 xkmake 干跑）
    """
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("# 完整运行命令（赛题第六节「浏览器基础功能」要求提供完整运行命令）\n\n")
        fh.write("## ① 本脚本命令行\n")
        fh.write("python3 scripts/run-session.py --cwd %s --make-args %s "
                 "--duration %s --interval %s --out %s\n\n"
                 % (cwd, shlex.quote(make_args), duration, interval, out))
        fh.write("## ② 实际执行的 make 命令\n")
        fh.write(" ".join(shlex.quote(a) for a in argv) + "\n\n")
        fh.write("## ③ QEMU 实际命令行（xkmake 干跑抓取的字面行）\n")
        fh.write("#    来源: make justrun XKMAKE_ARGS=--dry-run  （只打印，不启动 QEMU）\n")
        fh.write("#    说明: %s\n" % qemu_note)
        if qemu_cmdline:
            fh.write(qemu_cmdline + "\n")
            fh.write("\n")
            fh.write("## ③b 同一命令的单行形式（便于直接复制粘贴执行）\n")
            one = " ".join(qemu_cmdline.replace("\\", " ").split())
            fh.write(one + "\n")
        else:
            fh.write("(抓取失败)\n")
        fh.write("\n")
        fh.write("## ④ guest 内需要执行的命令（如适用）\n")
        fh.write("export XDG_RUNTIME_DIR=/run/user/0\n")
        fh.write("export WAYLAND_DISPLAY=wayland-0\n")
        fh.write("chromium --ozone-platform=wayland --no-sandbox --disable-gpu "
                 "--disable-dev-shm-usage file:///usr/share/html-test/index.html\n\n")
        fh.write("## ⑤ 计划向 guest 发送的命令\n")
        if sends:
            for at, cmd in sorted(sends, key=lambda x: x[0]):
                fh.write("  t+%.1fs : %s\n" % (at, cmd))
        else:
            fh.write("  (无)\n")


def parse_send(spec: str) -> tuple[float, str]:
    if ":" not in spec:
        raise argparse.ArgumentTypeError("--send 需要 AT_SECONDS:COMMAND 形式")
    at, cmd = spec.split(":", 1)
    return float(at), cmd


def main() -> int:
    ap = argparse.ArgumentParser(
        description="在 pty 中运行 make run，自动落盘日志并周期 screendump 取证。",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--cwd", default=".", help="x-kernel 仓库根目录（默认当前目录）")
    ap.add_argument("--make-args", default="GRAPHIC=y ACCEL=n MEM=4g SMP=4",
                    help="传给 make 的变量，注意不要包含 'run' 本身")
    ap.add_argument("--no-make", action="store_true",
                    help="直接执行 --make-args 作为命令（供调用裸 qemu 时使用）")
    ap.add_argument("--duration", type=float, default=660.0, help="会话总时长秒（默认 660，>10min）")
    ap.add_argument("--interval", type=float, default=60.0, help="截图间隔秒（0 表示只在首尾各截一张）")
    ap.add_argument("--first-shot", type=float, default=90.0, help="首张截图延迟秒（等内核启动）")
    ap.add_argument("--send", action="append", default=[], type=parse_send,
                    metavar="SEC:CMD", help="在指定秒数向 guest 串口敲一条命令，可重复")
    ap.add_argument("--with-input", action="store_true",
                    help="追加虚拟键鼠设备（对应赛题第七节(一)3 的 virtio-input 要求）。"
                         "xkmake 默认 **不会** 添加任何 virtio-input 设备，必须显式加，"
                         "否则 guest 内没有 /dev/input/event*，决赛「键盘回显/鼠标点击」拿不到分")
    ap.add_argument("--input-devices", default="virtio-keyboard-pci virtio-mouse-pci",
                    help="--with-input 时使用的 QEMU 设备（默认 keyboard+mouse）")
    ap.add_argument("--qemu-args", default="",
                    help="额外传给 QEMU 的参数（会作为单个 QEMU_ARGS 变量传递，"
                         "避免值中的空格被拆成两个 argv）")
    ap.add_argument("--out", required=True, help="证据输出目录")
    ap.add_argument("--quiet", action="store_true", help="不把子进程输出回显到终端")
    ap.add_argument("--dry-run", action="store_true",
                    help="只校验参数、打印将执行的命令并写好输出目录，不启动 QEMU"
                         "（可在 Windows 上运行）")
    ap.add_argument("--require-platform-compliance", action="store_true",
                    help="合规门禁：若实跑命令行不满足赛题第七节的平台要求"
                         "（无 -accel、四类 virtio 设备齐、-serial mon:stdio、-m 4g 等），"
                         "则以退出码 4 拒绝启动会话。默认只告警并写 platform-compliance.txt")
    ap.add_argument("--skip-cmdline-capture", action="store_true",
                    help="跳过 xkmake 干跑抓取字面 QEMU 命令行（默认会抓，用于 cmd.txt 自证合规）")
    args = ap.parse_args()

    out = os.path.abspath(os.path.expanduser(args.out))
    shots_dir = os.path.join(out, "screenshots")
    os.makedirs(shots_dir, exist_ok=True)
    log_path = os.path.join(out, "console.log")

    if args.no_make:
        argv = shlex.split(args.make_args)
    else:
        argv = ["make", "run"] + shlex.split(args.make_args)

    cwd = os.path.abspath(os.path.expanduser(args.cwd))
    if not os.path.isdir(cwd):
        print(f"错误: --cwd 不存在: {cwd}", file=sys.stderr)
        return 2

    # ---- 组装传给 QEMU 的额外参数 ----
    # 关键：QEMU_ARGS 的值里含空格，必须作为**单个 argv 元素**传给 make。
    #   ✅ argv 元素 = "QEMU_ARGS=-device virtio-keyboard-pci -device virtio-mouse-pci"
    #   ❌ 若经 shell 拆成两个 argv，后一个会被 make 当成构建目标
    # 这里直接构造字符串（不经过 shell），因此天然安全。
    extra = args.qemu_args.strip()
    if args.with_input and "virtio-" not in extra:
        # --input-devices 收的是"设备名列表"（如 virtio-keyboard-pci virtio-mouse-pci），
        # 这里逐个补上 -device 前缀；需要更细粒度控制请直接用 --qemu-args。
        parts = []
        for token in args.input_devices.split():
            parts += ["-device", token]
        extra = (extra + " " + " ".join(parts)).strip()
    if extra:
        if args.no_make:
            print("警告: --qemu-args/--with-input 只在非 --no-make 模式下生效，已忽略",
                  file=sys.stderr)
        else:
            argv.append("QEMU_ARGS=" + extra)

    # ---- 抓取字面 QEMU 命令行（赛题第七节(一)3 的"完整运行命令"自证）----
    if args.skip_cmdline_capture:
        qemu_cmdline, qemu_note = "", "已用 --skip-cmdline-capture 跳过"
    else:
        qemu_cmdline, qemu_note = capture_qemu_cmdline(argv, cwd, args.no_make)

    # ---- 平台合规断言（第七节(一)1/2/3）----
    compliant, n_pass, n_fail = check_platform_compliance(qemu_cmdline, out)

    # ---- 先在证据目录里放一份宿主机指纹（git_cwd 必须是 x-kernel 仓库）----
    fp = host_fingerprint(cwd)
    with open(os.path.join(out, "env.txt"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(fp) + "\n")

    # ---- 立刻落一盘 cmd.txt：即便会话中途崩溃/被杀，完整运行命令也已在盘上 ----
    write_cmd_txt(os.path.join(out, "cmd.txt"), cwd, args.make_args, argv,
                  qemu_cmdline, qemu_note, out, args.duration, args.interval,
                  args.send)

    print("=" * 70)
    print(" 赛题六 · 基础任务 · QEMU 会话编排")
    print("=" * 70)
    for ln in fp:
        print("  " + ln)
    print("-" * 70)
    print("  输出目录 :", out)
    print("  工作目录 :", cwd)
    print("  命令     :", " ".join(shlex.quote(a) for a in argv))
    print("  时长     :", args.duration, "秒   截图间隔:", args.interval, "秒")
    if extra:
        print("  额外 QEMU 参数 :", extra)
    else:
        print("  额外 QEMU 参数 : (无)  ← 注意：此时 guest 内不会有 /dev/input/event*，")
        print("                             赛题第七节(一)3 要求的 virtio-input 未满足，")
        print("                             加 --with-input 可补上")
    print("-" * 70)
    if qemu_cmdline:
        print("  QEMU 实际命令行（xkmake --dry-run 抓取）:")
        for ln in qemu_cmdline.splitlines():
            print("   ", ln)
    else:
        print("  QEMU 实际命令行: (抓取失败:", qemu_note, ")")
    print("-" * 70)
    print("  平台合规断言（赛题第七节）: PASS=%d FAIL=%d -> %s"
          % (n_pass, n_fail, "PLATFORM_COMPLIANT" if compliant
             else "PLATFORM_NOT_COMPLIANT"))
    print("  详见:", os.path.join(out, "platform-compliance.txt"))
    print("=" * 70)
    print("  提示: 截图前请确认 guest 内 Weston 已起来；否则会截到启动画面。")
    print("=" * 70)

    if n_fail and args.require_platform_compliance:
        if not qemu_cmdline:
            # 「抓不到命令行」不等于「不合规」—— 只是无法验证。
            # 硬门禁不该因为一次干跑失败就阻断真实工作，降级为告警。
            print("", file=sys.stderr)
            print("[WARN] --require-platform-compliance: 未能抓取字面 QEMU 命令行（%s），"
                  "无法验证合规，**继续执行**。若要严格自证请先修复抓取。"
                  % qemu_note, file=sys.stderr)
        else:
            print("", file=sys.stderr)
            print("[FATAL] --require-platform-compliance: 实跑命令行有 %d 项不满足赛题第七节，"
                  "拒绝启动会话。" % n_fail, file=sys.stderr)
            print("        详见 %s" % os.path.join(out, "platform-compliance.txt"),
                  file=sys.stderr)
            return 4

    if args.dry_run:
        # 注意：cmd.txt 已在上面写好（含字面 QEMU 命令行），此处**不要**覆盖它。
        plan = [
            "赛题六 · 基础任务 · 会话计划 (dry-run)",
            "=" * 60,
            *fp,
            "",
            f"out_dir   : {out}",
            f"cwd       : {cwd}",
            f"argv      : {' '.join(shlex.quote(a) for a in argv)}",
            f"duration  : {args.duration}s",
            f"interval  : {args.interval}s",
            f"first_shot: {args.first_shot}s",
            "",
            "--- 平台合规断言（赛题第七节）---",
            f"PASS={n_pass} FAIL={n_fail} -> "
            + ("PLATFORM_COMPLIANT" if compliant else "PLATFORM_NOT_COMPLIANT"),
            f"qemu_cmdline_capture : {qemu_note}",
            "",
            "--- 产物 ---",
            "cmd.txt                 : 完整运行命令（含字面 qemu-system-aarch64 行）",
            "env.txt                 : 宿主机指纹（含 git_commit / git_describe）",
            "platform-compliance.txt : 第七节平台合规逐条断言",
            "",
            "screenshots: (dry-run 未执行)",
            "",
            "本文件仅用于参数核对，不可作为任何评分证据。",
        ]
        with open(os.path.join(out, "dry-run-plan.txt"), "w", encoding="utf-8") as fh:
            fh.write("\n".join(plan) + "\n")
        print("  --dry-run 完成：已写出 cmd.txt 与 dry-run-plan.txt")
        print("  下一步：去掉 --dry-run 在 Linux 主机上正式执行。")
        return 0

    require_unix_pty()

    sess = Session(argv, cwd, log_path, verbose=not args.quiet)

    schedule = sorted(args.send, key=lambda x: x[0])
    sends_done: set[int] = set()

    started = time.time()
    next_shot = args.first_shot
    shots: list[tuple[float, str, bool]] = []
    shot_idx = 0
    rc = 0
    try:
        while True:
            sess.pump(0.25)
            elapsed = time.time() - started

            if not sess.alive() and elapsed > 3:
                sess.write("\n### [%s] 子进程已退出（elapsed=%.1fs）\n" % (ts(), elapsed))
                rc = sess.proc.poll() or 0
                break

            # 按计划向 guest 发送命令
            for i, (at, cmd) in enumerate(schedule):
                if i not in sends_done and elapsed >= at:
                    sends_done.add(i)
                    sess.send_guest(cmd)

            # 周期性截图
            if elapsed >= next_shot:
                shot_idx += 1
                name = "shot-%02d-at%04ds.ppm" % (shot_idx, int(elapsed))
                path = os.path.join(shots_dir, name)
                ok = sess.screendump(path)
                shots.append((round(elapsed, 1), name, ok))
                next_shot = elapsed + args.interval if args.interval > 0 else float("inf")

            if elapsed >= args.duration:
                break

            time.sleep(0.05)
    except KeyboardInterrupt:
        sess.write("\n### 收到 Ctrl-C，提前结束\n")
        rc = 130

    # 收尾：先补一张最终状态截图，再优雅关停 QEMU
    if sess.alive():
        try:
            shot_idx += 1
            name = "shot-%02d-final.ppm" % shot_idx
            ok = sess.screendump(os.path.join(shots_dir, name))
            shots.append((round(time.time() - started, 1), name, ok))
        except Exception as exc:  # noqa: BLE001
            sess.write("### 收尾截图失败: %s\n" % exc)
    stop_rc = sess.stop()
    if rc == 0:
        rc = stop_rc

    # ---- 落盘时间戳与 manifest ----
    with open(os.path.join(out, "timestamps.csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["elapsed_sec", "file", "result"])
        for row in shots:
            w.writerow(row)

    # 会话结束后重写 cmd.txt（内容与开头一致；此时已知全部产物，语义上更完整）
    write_cmd_txt(os.path.join(out, "cmd.txt"), cwd, args.make_args, argv,
                  qemu_cmdline, qemu_note, out, args.duration, args.interval,
                  args.send)

    ok_shots = [s for s in shots if s[2]]
    manifest = [
        "赛题六 · 基础任务 · 会话清单 (manifest)",
        "=" * 60,
        *fp,
        "",
        "--- 本次会话 ---",
        "out_dir          : %s" % out,
        "cwd              : %s" % cwd,
        "make_argv        : %s" % " ".join(shlex.quote(a) for a in argv),
        "duration_sec     : %s" % args.duration,
        "interval_sec     : %s" % args.interval,
        "actual_sec       : %.1f" % (time.time() - started),
        "screendumps      : %d / %d 成功" % (len(ok_shots), len(shots)),
        "console_log      : console.log (带时间戳的串口+QEMU全量输出)",
        "env_fingerprint  : env.txt",
        "complete_command : cmd.txt (含字面 qemu-system-aarch64 命令行)",
        "",
        "--- 赛题第七节 平台合规 ---",
        "platform_check   : PASS=%d FAIL=%d -> %s"
        % (n_pass, n_fail, "PLATFORM_COMPLIANT" if compliant
           else "PLATFORM_NOT_COMPLIANT"),
        "detail_file      : platform-compliance.txt",
        "guest_arch       : aarch64 (七(一)1)",
        "accel            : 无 -accel（纯 TCG，七(一)2）" if "-accel" not in qemu_cmdline
                            else "!! 命令行出现 -accel，初赛数据不可用（七(一)2）",
        "device_combo     : virtio-gpu-pci + virtio-input(keyboard/mouse) + virtio-blk + virtio-net (七(一)3)",
        "evidence_shots   : QEMU monitor screendump（七(一)3 唯一认可的截图方式）",
        "",
        "--- 证据与评分项映射（请按实际内容改写 name）---",
        "01-weston-start.ppm    -> 图形环境启动与稳定性(20分): 图形会话启动 10分",
        "weston-watch.log       -> 图形环境启动与稳定性(20分): 稳定运行>=10min 10分",
        "       (来源: guest 内 /tmp/weston-watch.log，xk-weston-start 每30s写一次)",
        "chromium-window.ppm    -> 浏览器基础功能(20分): Chromium 创建窗口 10分",
        "html-rendered.ppm      -> 浏览器基础功能(20分): 渲染指定 HTML 10分",
        "",
        "--- 日志尾部(最后 2000 字符，供快速判断是否崩溃)---",
        sess.tail_text(2000),
        "",
    ]
    with open(os.path.join(out, "manifest.txt"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(manifest))

    print()
    print("=" * 70)
    print(" 完成。产物：")
    for fn in ("env.txt", "console.log", "cmd.txt", "timestamps.csv",
               "manifest.txt", "platform-compliance.txt"):
        p = os.path.join(out, fn)
        print("   %-16s %s" % (fn, "OK" if os.path.exists(p) else "MISSING"))
    print("   screenshots/     %d 张 (%d 成功)" % (len(shots), len(ok_shots)))
    print("=" * 70)
    print(" 下一步：")
    print("   python3 scripts/ppm2png.py %s/screenshots/*.ppm" % out)
    print("   然后打开 PNG 逐张确认画面内容。")
    print("=" * 70)
    return rc if isinstance(rc, int) else 0


if __name__ == "__main__":
    sys.exit(main())
