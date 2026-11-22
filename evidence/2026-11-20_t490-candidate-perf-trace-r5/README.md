# T490 Chromium startup trace 试采 R5（2026-11-20）

## 结论

R5 是首个通过完整串口、gzip、块序、长度、SHA-256 和 JSON 结构校验的 Chromium startup trace。实际 argv 显式包含 `--trace-startup-format=json`，抽取器恢复15,474,459字节 JSON，包含60,878个 `traceEvents`。这是一份有效的原始事件样本，但当前还没有完成与 guest 单调时钟、导航编号、renderer 身份及页面首帧判据的关联，四项性能指标仍为0个有效样本。

## 会话结果

| 项目 | 结果 |
|---|---|
| 平台 | T490 `10.249.11.192`；AArch64；2 GiB；纯 TCG；Chromium 149.0.7827.53 |
| 页面与重载 | 首页严格通过于 590,704.849 ms；QMP 重载 1/1 PASS |
| 保持与事件 | driver PASS；保持550秒；事件归一化372/372 PASS |
| 周期截图 | 1张/1张成功，位于240秒、页面严格通过之前；post-pass失败0。该轮不构成正式稳定性通过 |
| trace | JSON格式；21,535个序号块0–21,534；gzip、长度、SHA和 `traceEvents` 校验通过 |
| 正式计数 | diagnostic-only，gate RC 78；性能指标和before/after样本仍为0 |

## Trace event 初步盘点

trace包含 Browser、Renderer、Extension Renderer、NetworkService、StorageService 和 TracingService 元数据；还包含导航、DocumentLoader、FirstContentfulPaint、BeginMainFrame、SubmitCompositorFrame、Graphics.Pipeline 等事件。可复核计数见 `trace-events-inventory.txt`；这些只是事件存在性和数量，尚未作为延迟指标。

## 文件与复核

- 原始 trace JSON 在 `remote/mp-perf-trace.json`，SHA-256 `3eee58e70673189a330d06d1ad67bcd272a7f5baca4fbb7f8d385a5c2e7d587f`。
- 完整串口、事件、QMP transcript、命令及环境在 `remote/`；压缩归档 SHA-256 为 `ae7042e382d1fd9faa4261897d3223889d10cbfa6b029d427cce12624fed2eba`，共36项、不含PPM。
- 3张原始PPM保留在T490，SHA清单见 `ppm-sha256.txt`；仓库保存三张PNG预览。
- [报告367](../../report/367-T490性能trace试采r5有效JSON事件样本但四项指标尚未映射-20261120.md) 记录指标映射缺口和后续工作。
