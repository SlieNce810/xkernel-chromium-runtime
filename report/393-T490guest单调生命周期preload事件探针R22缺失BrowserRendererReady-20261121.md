# T490 guest 单调生命周期 preload 探针 R22（2026-11-21）

## 结论

R22 在统一 2 GiB AArch64 纯 TCG 平台完成 Chromium 149 首页、1 次真实重载和 800 秒保持。首页严格判据在 guest 589.127 秒通过，重载 1/1 通过，Weston 与 Chrome 在保持阶段持续存活；本轮为 diagnostic-only，`STABILITY_GATE_RC=78` 是正式稳定性 gate 按配置跳过的标记。

新增的 `LD_PRELOAD` 小型事件探针没有阻断浏览器，但只记录到指定 HTML 文件打开和 Zygote fork 边界：6 条 probe 事件中 1 条 `navigation_requested`、5 条 fork 事件。**没有** `browser_main_loop_ready`、`renderer_ready` 或 `first_valid_frame`；proc-tree sampler 观察到的 Zygote 子进程仍被标为 zygote，尚未和 Renderer 身份配对。合并器据此将 ledger 标为无效，`collect_metrics.py` 也拒绝样本。

这轮验证了 Browser 文件打开 hook 与 Zygote fork hook 能在真实 Chromium 会话中写出 guest `LINUX_CLOCK_MONOTONIC` 事件；它没有打通完整生命周期，也没有四项有效性能数据。

## 运行条件和实现

- T490：`mo-ThinkPad-T490`、Ubuntu 26.04.1、QEMU 10.2.1；AArch64 guest `-m 2g -smp 4 -cpu cortex-a76`、纯 TCG、virtio GPU/键盘/鼠标。
- Chromium 149.0.7827.53，镜像 SHA-256 `bab5c9f5dbf1e4a910bab569635bb9e44fe38c3b8cea94ae8eae4ce3f7a9fdb1`；kernel.bin SHA-256 `da0c3802afed33a60faba5e1cbdfee6cd888e191c45e958c58cc01f0350de07f`。
- 只有设定 `STABILITY_LIFECYCLE_PRELOAD=1` 才会将 preload 注入 Chromium；默认 runner 参数不变。memory export 会附带可选 `lifecycle-probe-events.jsonl`。
- C preload 源 SHA-256 `3c2f63ca24339c9083fca14ad049be7418ddc5dbb4a5175cd5a4cdc0114b9904`，运行 `.so` SHA-256 `93864e7743a7b885fcf425b92349f12a160b003d1cda3e27ea19b0b36e26915f`；采样器源 SHA-256 `d947024b2dae2a0c9c7494b6d396f7976bf2a2c974e4a19c0b68acccb6795ded`。身份记录见 [lifecycle-probe-identities.txt](../evidence/2026-11-21_t490-r22-lifecycle-events/lifecycle-probe-identities.txt)。
- 首屏 deadline 1,200 秒、采样 900 秒/1 秒间隔；1 次真实 Ctrl+R、30 秒 settle、800 秒保持。QEMU 命令、平台检查和运行环境见 [R22 evidence](../evidence/2026-11-21_t490-r22-lifecycle-events/)。

## 事件结果

guest probe 的 `navigation_requested` 为 Browser PID 72、实例 `72-4211`，时间 `150.599192608 s`，来源是打开 `/usr/share/html-test/index.html`。五条 Zygote fork 边界时间为 `107.366`、`128.941`、`130.633`、`146.719` 和 `150.769 s`。前四条早于 file URL open；第五条晚于 file URL open，但对应 child 仍没有 Renderer ready 事件，不能计作 renderer-create/ready 配对。

生命周期合并器使用 346 个 host/guest clock-sync anchors 将 QMP strict 截图事件映射至 guest 单调时钟，并将误差上界标为 unknown，因为串口接收延迟没有独立测界。QMP 首屏轮询间隔为 30 秒；截图只给出保守画面上界。

[lifecycle-merge-validation.json](../evidence/2026-11-21_t490-r22-lifecycle-events/lifecycle-merge-validation.json) 记录三个缺项：缺少 `browser_main_loop_ready`、缺少 `first_valid_frame`、无法选择与该页面匹配的 `renderer_ready`。同一缺口由 [`collect-metrics-validation.json`](../evidence/2026-11-21_t490-r22-lifecycle-events/collect-metrics-validation.json) 复核，结果是 `expected one browser_main_loop_ready event, found 0`。

## 内存和稳定性状态

| 项目 | R22 |
|---|---:|
| sampler status | `FAIL` |
| sample ID / CSV 行 | 253 / 1,572 |
| process instances / missed | 11 / 225 |
| memory sampling errors | 283 |
| overrun 次数 / min / median / P95 / max | 131 / 1.501 / 2.102 / 13.758 / 24.281 s |
| process tree unavailable | 36 |
| bulk unavailable / incomplete | 58 / 58 |
| 可用进程树 RSS/PSS/USS 峰值 | 否 |

提取 JSON 保留原数据并标记 `valid=false`；详见 [memory-export/extraction.json](../evidence/2026-11-21_t490-r22-lifecycle-events/memory-export/extraction.json)。R22 不能作为峰值内存或正式性能样本。页面 ready 与 R21 只差约 0.060 秒，单次诊断没有证明性能变化。

## 验证与下一步

- memory export、`collect_metrics.py`、lifecycle merge 和 proc-tree smoke 的回归分别为 10/10、11/11、3/3、7/7。
- T490 原生 x86 preload 自测输出 `LIFECYCLE_PRELOAD_NATIVE_SMOKE=PASS`；AArch64 preload/sampler 均通过 `-Wall -Wextra -Werror` 编译。native smoke 只验证拦截器能写事件，不代表 guest Chromium hook 已命中。
- runner `bash -n`、稳定性 dry-run 和 trace 参数 guard 通过，未在 dry-run 中启动 QEMU。R22 driver 返回 `pass=1 duration=800.0 reloads=1/1`；正式 gate 按 diagnostic-only 跳过。
- 下一轮应以 `/proc/<pid>/task/<pid>/comm` 识别 `CrBrowserMain` / `CrRendererMain`，并覆盖 `poll` / `ppoll` 等可能的主线程等待入口。fork 事件先保留为 `zygote_fork_boundary`；只有与同一 request ID 的 Renderer ready 配对后，才作为 renderer-create 样本。Frame 时间仍需独立有效来源。

原始 PPM 保留在 T490，SHA-256 索引见 [`evidence/_ppm-sha256-r22-lifecycle-events.txt`](../evidence/_ppm-sha256-r22-lifecycle-events.txt)；仓库提供 [初始严格帧 PNG](../evidence/2026-11-21_t490-r22-lifecycle-events/stability/load-00-initial.png) 和 [重载严格帧 PNG](../evidence/2026-11-21_t490-r22-lifecycle-events/stability/load-01-reload.png)。
