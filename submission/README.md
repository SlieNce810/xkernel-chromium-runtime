# x-kernel Chromium 运行环境 · 初赛材料

提交范围：T490 原生 Linux，AArch64 QEMU 纯 TCG，Weston + Chromium 142 单进程运行。

| 材料 | 位置 |
|---|---|
| 技术方案及已知限制 | `技术方案.md` |
| 内核源码 / 构建配置 | `assets/x-kernel-source-2a1b101.tar.gz` / `config/xkernel.config` |
| T490 自动化运行和测试脚本 | `scripts/` |
| 唯一提交证据集 | `evidence/t490-final/`，索引见 `证据说明.md` |
| 完整演示录像 | `video/full-flow.mp4`，730 秒 |
| 文件来源、大小、SHA-256 | `manifest.csv`、`SHA256SUMS` |

内核提交：`2a1b101ccf97ed255821b85628f366700089cda3`。源码归档含 Git 元数据，可回读版本及基线 tag。内核仓库：<https://gitee.com/mofan0810/x-kernel/tree/t490-chromium-runtime>；材料仓库：<https://github.com/SlieNce810/xkernel-chromium-runtime>。

## T490 复现

依赖：x86_64 Linux、QEMU ≥ 8（原始证据为 10.2.1）、Rust 1.95.0/Cargo、GNU make、AArch64 musl GCC、Python 3、e2fsprogs、xz、tar、Git；可选 Linux 兼容性对照另需 native GCC 和 `qemu-aarch64`。用户级工具默认位于 `~/.cargo/bin`、`~/qemu-root/usr/bin`、`~/musl/aarch64-linux-musl-cross/bin`。Rust 目标由源码的 `rust-toolchain.toml` 指定。

在新目录解压提交 ZIP 后，进入解压根目录执行：

```bash
sha256sum -c SHA256SUMS
bash scripts/t490/reproduce_submission.sh --prepare
bash scripts/t490/reproduce_submission.sh --check
bash scripts/t490/reproduce_submission.sh --dry-run
bash scripts/t490/reproduce_submission.sh --run
```

`--prepare` 从随包源码构建内核，默认使用提交目录旁的 `x-kernel-final/`，并从固定 Release 获取基础镜像（下载约 344 MiB，解压 2 GiB）。已有下载可用 `BASE_IMAGE_XZ=/path/to/agentos-weston.img.xz` 指定；已解压镜像可用 `BASE_IMG=/path/to/agentos-weston.img` 指定，均核对 SHA-256。准备和运行时应使用相同的环境变量；源码位置可用 `KERNEL_REPO` 指定。

平台固定 `GRAPHIC=y ACCEL=n MEM=2g SMP=4 VSOCK=n`，保留 virtio GPU、键鼠、块设备、网卡。运行前不得有其他 QEMU 会话。脚本从基础镜像新建工作盘，注入三张测试页及 guest 启动脚本，运行 900 秒；每次使用新的场景目录，原件保存在当前提交目录的 `evidence/<date>_t490-<tag>/`。

通过条件：平台 `PASS=15/15`，guest `SINGLE_GATE=1`、保持至少 600 秒，定时截图通过 official-index 严格判据。`*-final.ppm` 是退出后的诊断帧，独立保留和判定。

需要复测其他项目时，使用与准备阶段相同的源码和基础镜像位置。下例对应默认位置：

```bash
export XK6_ROOT="$PWD"
export KERNEL_REPO="$(dirname "$PWD")/x-kernel-final"
export BASE_IMG="$KERNEL_REPO/images/agentos-weston.img"
export PKG_TARBALL="$PWD/guest-overlays/eudev-seatprobe-libinput-swiftshader-p31.tar.gz"
# 浏览器级 JS/页面交互；CDP 输入不等价于内核硬件输入链。
bash scripts/t490/run_interaction_round.sh "interaction-$(date +%H%M%S)" 300 30
# 当前原始运行栈的五次性能观测。
MEASURE_TAG_PREFIX="perf-$(date +%H%M%S)" bash scripts/t490/measure-single-initial.sh
# 原生 Linux 与 AArch64 qemu-user 的兼容性对照。
python3 scripts/t490/run_linux_gap_baselines.py --out "evidence/$(date +%F)_t490-linux-gaps-$(date +%H%M%S)"
# Guest 探针专项；不以图形截图判定 syscall 语义。
FIRST_SHOT=120 STRICT_GATE=0 bash scripts/t490/t490_round.sh \
  "gaps-$(date +%H%M%S)" 360 120 autorun_submission_gaps.sh \
  submission_gap_probe.c compatprobe.c sandboxipcprobe.c fdprobe.c seqpacketprobe.c evprobe.c
```

报名表按队伍要求另行处理；本包为技术提交材料。
