# T490 Chromium 149 多进程基线诊断（2026-11-23）

## 结论

本轮使用 T490 `10.249.11.192` 的 `pkg-installed.img` 和现有 Chromium
149.0.7827.53 预编译二进制，二进制 SHA-256 为
`d7d89bcb466c1d9a7ab209220c8ab997f66c02b77c5e80d3ea10ed64c772a641`。
平台为 2 GiB AArch64、4 vCPU、纯 TCG、Weston 原生 Wayland、默认
Browser→Zygote→Renderer。会话实际运行 363.5 秒，10 个周期截图和最终截图共
12/12 严格判据通过，QEMU 以 `SESSION END (exit=0)` 收尾。

这轮是 Chromium 149 多进程基线诊断，不是生命周期 preload 验证：运行时使用的
T490 autorun 版本还没有把 `MP_LIFECYCLE_PRELOAD_VALUE` 接到 Browser 环境，日志
明确记录 `LD_PRELOAD=<unset>`，没有 `renderer_ready`、`renderer_exec` 或
`preload_attached`。随后已把仓库当前的 autorun、round wrapper 和 preload 源同步
到 T490，下一轮再用相同镜像验证真正的 preload 路径。

## 观测结果

- `CHROMIUM_SHA256=d7d89bcb…`，确认不是镜像内 Chromium 142。
- Browser `pid=70`、Zygote `pid=194/196` 以及后续多个 renderer 进程均被记录。
- renderer 观察事件至少包含 PID 366、434、436、466、471；后段
  `MP_RENDERER_COUNT` 达到 3–4。
- `pages.txt` 注入和读回校验通过；`timestamps.csv` 的 12 个截图每行
  `result=True`。
- 观测关闭了 trace、ledger 和 memory sampler，本轮没有四项性能数据。

## 固定条件与边界

| 项目 | 实际值 |
| --- | --- |
| 基础镜像 | `/home/mo/x-kernel/images/pkg-installed.img`，SHA `bab5c9f5…` |
| Chromium | Chrome/149.0.7827.53，SHA `d7d89bcb…` |
| guest | AArch64，2 GiB，4 vCPU，QEMU 10.2.1，纯 TCG |
| 图形/输入 | Weston 原生 Wayland，virtio-gpu，virtio keyboard/mouse |
| 页面 | `file:///usr/share/html-test/index.html` |
| 会话 | 请求 360 s，周期 30 s，实际 363.5 s |
| preload | 未启用；旧 autorun 在运行期报告 `LD_PRELOAD=<unset>` |

该轮不能替代三次独立冷启动、30 分钟/十次导航稳定性门禁，也不能产生启动、首帧、
renderer 创建或 RSS/PSS/USS 峰值性能样本。它只确认现有 Chromium 149 在当前
冻结内核/镜像上能完成默认多进程页面路径和严格画面判据。

## 原始证据

T490 原始目录：

```text
/home/mo/xk6/evidence/2026-11-23_t490-preload-exec149/
```

仓库保留命令、环境、console、页面清单、12 个判据 JSON、PPM summary 和哈希清单；
原始 PPM 仍只留在 T490。下一轮 `preload-exec149-v2` 使用已同步的新版脚本，
在同一 Chromium 149 二进制上检查 preload attach、exec 继承和 renderer-ready 配对。
