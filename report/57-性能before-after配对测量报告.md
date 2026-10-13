# 57 · 性能 before/after 配对测量报告（首个可运行版本 vs 当前版本）

> 2026-10-13 后续状态：65 张 PPM、两份 console、录制轮 12 份 guest 文件已恢复，详见 [report/59](59-T490原始证据回传与校验报告.md)；八条缺口附件已整理，详见 [report/60](60-八条兼容性缺口复现与Linux对照附件.md)。下文相应缺项为此前审计快照。行政报名与盖章资料按用户要求跳过；新性能对照独立归档，不改写历史失败轮。

> 测量日期：2026-10-13｜主机：T490（i7-8665U / 14.7 GiB / Ubuntu 26.04.1 / QEMU 10.2.1 纯 TCG）
> 基线（before）：内核 tag **`v0.1-first-runnable`** = `f8b9224`（构建 `af009c42`，`git_describe=v0.1-first-runnable`）
> 当前（after）：内核 **`2a1b101`**（构建 `d58ba99b`，分支 `t490-chromium-runtime`）
> 控制变量：同一基础镜像 `bb25e0b2`、同一 overlay `56dba17c`、同一页面 `index.html`、
> 同一测量脚本与判据（`measure-baseline-first-runnable.sh` / `measure-single-initial.sh`，
> `official-index`，FIRST_SHOT=180，HOLD=120，每轮新 QEMU/新 profile）。
> 原始数据：`evidence/2026-10-13_measure-baseline-v01/`、`evidence/2026-10-13_measure-current-2a1b101/`
> （各含 raw.csv、summary.json、host.txt、observer-runNN.*、evidence-0N.txt 与配对轮目录）。

## 1. 当前版本（after）五轮结果

| 指标 | 中位数 | 最小 | 最大 | 极差 | 样本 |
|---|---:|---:|---:|---:|---:|
| 单进程 gate `single_gate` | 1 | 1 | 1 | 0 | 5 |
| 首个页面导航 `FileURLLoader::Start` | 75.0 s | 75.0 | 75.0 | 0 | 5 |
| 首张通过官方判据的 screendump | 180.2 s | 180.2 | 180.2 | 0 | 5 |
| 单进程保持 `single_hold` | 135 s | 135 | 135 | 0 | 5 |
| 官方页面严格判据 `page_assertion` | 1 | 1 | 1 | 0 | 5 |
| **QEMU 峰值 RSS（host 观测）** | **1,695,736 kB** | 1,681,484 | 1,699,284 | 17,800 | 5 |
| **QEMU CPU%（host /proc，单核尺度）** | **176.8%** | 173.0 | 178.5 | 5.5 | 5 |

口径说明：`first_navigation` 是 15 s 采样粒度的真实观测（TCG 下同负载确定性高，五轮同值属预期）；
`screendump`/`hold` 由脚本固定窗口决定；RSS 与 CPU 为 host 侧 QEMU 进程观测
（guest `/proc` VmRSS 不可用），两者呈现真实波动（极差非零）。

## 2. 基线版本（before）五轮结果

| 指标 | 中位数 | 样本 | 说明 |
|---|---:|---:|---|
| `single_gate` | 0 | 5 | Chromium 启动后中止，功能门禁未过 |
| `page_assertion` | 0 | 5 | 页面加载未完成 |
| 其余指标 | — | — | 基线无法产出（见 §3） |

每轮失败现场（console.log + `guest/_root_single-chromium.log`）已归档，典型签名：

```text
[43:91:...] ERROR:dbus/bus.cc:408] Failed to connect to the bus: /run/dbus/system_bus_socket
[43:91:...] WARNING:ui/ozone/platform/wayland/... Failed to find drm render node path.
Assertion (r == 0 || r == 95) failed at ../src/pulsecore/mutex-posix.c:57, function pa_mutex_new(). Aborting.
[...ERROR:third_party/crashpad/crashpad/util/linux/socket.cc:177] missing credentials
```

Weston 本身在基线内核上可以起来（本轮为公平对比统一启用 `--continue-without-input`；
不启用时基线还会因无输入设备直接 fatal——x-kernel 的 evdev sysfs 投影是 2a1b101 才具备的）。

## 3. before/after 对比与口径（重要）

`summary-baseline-compared.json`（由 `measure.py --baseline` 生成）的注解结果：

| 指标 | after 中位数 | before 中位数 | 改善 |
|---|---:|---:|---|
| `single_gate` | 1 | 0 | 0 → 1（功能性跃迁；基线为 0 时百分比不可计算） |
| `page_assertion` | 1 | 0 | 同上 |
| 延迟/内存/CPU 类 | 见表 1 | 无（基线未完成加载） | 基线无法产出页面加载指标，非"慢"而是"未完成" |

**诚实结论**：基线版本（首个可运行版本 tag）在当前用户态组合下**不能完成指定页面加载**——
Chromium 主进程启动后即被 PulseAudio mutex 断言与 crashpad 凭据缺失打断（均对应 8 项缺口中的
Unix socket ancillary / ppoll 分派等修复点）。因此性能改善呈现为**从"不可用"到"可用"**：
修复后采样计数 75 s 首次发现导航开始日志、180.2 s 取得首张通过严格像素判据的定时截图、会话保持 135 s（功能轮 615 s）。
绝对性能数字以 after 五轮中位数呈现；before 的五轮失败原始数据同样归档，供组委会复核存档代码
（tag `v0.1-first-runnable` 指向 `f8b9224`）。

## 4. 指标覆盖（赛题"不少于 4 类"）

本报告列出 **5 组观测值**：① 首次发现导航开始日志的采样计数 ② 首张通过判据的定时 screendump 时刻
③ 稳定保持时长 ④ 峰值内存（host QEMU RSS）⑤ CPU 使用率（host /proc 单核尺度）。
renderer 创建延迟在单进程路线下不适用（无 renderer 子进程），已在 [核对矩阵](55-初赛提交物严格核对矩阵.md) 的场景覆盖表如实标注。

“保持时长”是稳定性窗口，不自动算作评分表中的独立性能类别；75 s 是采样发现导航开始日志的时间，180.2 s 是固定截图通过时刻，不分别等同于真实启动首帧与页面加载耗时。类别认定以评审为准。before 没有有效延迟样本，基线 CPU/RSS 仅一次，不满足资源指标各五次对比要求；现有结果不能据此主张 5%/15%/30% 改善分。

## 5. 已知瑕疵（如实记录）

- 2026-10-13 提交分支逐文件复核：before 与 after 各五轮的 timestamps.csv 各引用 15 张 PPM，仓库内没有同轮 PPM 或 PNG（合计 30 张）；perf3 另缺 15 张。需从 T490 回传后复核，不能以判据 JSON 替代原始像素帧。详见 report/58。

- 基线轮次中仅第 1 轮产出 host 观测指标（`peak_qemu_rss_kb=773,616 kB`、
  `qemu_cpu_percent=120.1%`，单样本，仅作上下文）：第 2–5 轮因当时测量脚本的
  `set -e`/`pipefail` 与 pgrep 轮询的交互缺陷丢失观测器。该缺陷已于同日修复
  （观测器子 shell 入口 `set +e`），after 五轮观测完整。基线侧内存/CPU 不参与中位数比较。
- 内核二进制哈希随构建变化（内嵌 build_time），基线轮实际哈希 `af009c42`、
  当前轮 `d58ba99b`，均记录于各轮 `build-manifest.txt` 与 `host.txt`。
