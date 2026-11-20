# T490 Chromium startup trace 试采 R3（2026-11-20）

## 结论

本轮在 2 GiB、AArch64 纯 TCG 会话中完成了首页与一次真实 QMP 重载诊断，并从 guest 串口开始转发 Chromium startup trace。页面首次严格判据在 558.842 秒通过，重载 1/1 通过，driver 完成 550 秒保持；本轮以 diagnostic-only 运行，不作为正式稳定性或性能样本。

串口导出 BEGIN/END 均出现，trace 头记录原始 JSON 3,920,137 字节、SHA-256 `3a342f89aa4a51095ecea45d04a23fd283fe4c8dce3d0f7b05a9de0e802b6990`。抽取时发现一条 `MP_PERF_TRACE_DATA` 被同一控制台流中的 `screendump OK` 状态文字打断；gzip 在第 10,808 个零基数据块处损坏，长度、SHA 和 JSON 校验未通过。因此不生成有效 trace，也不接受任何性能指标。

## 会话结果

| 项目 | 结果 |
|---|---|
| 主机与平台 | T490 `10.249.11.192`；AArch64；2 GiB；纯 TCG；Chromium 149.0.7827.53 |
| trace 参数 | trace-startup 参数在 Browser 启动记录中出现；时长 500 秒 |
| 首屏与重载 | 首页严格通过于 558,841.591 ms；QMP 重载 1/1 通过 |
| 保持与截图 | driver 保持 550 秒；周期截图 29/29；PPM 共 29 张 |
| 画面稳定判据 | 周期图像严格失败 11 张（含 10 张 warm-up、1 张 post-pass）；最后一帧通过。连续稳定性验收仍不通过 |
| 事件归一化 | 372 个事件，无解析错误；因完整进程族快照陈旧 37.041 秒（上限 35 秒）返回失败 |
| 正式计数 | diagnostic-only；gate RC 78；性能有效样本 0 |

## trace 传输诊断

串口头的原始长度和 SHA-256 见 `remote/console.log` 中 `MP_PERF_TRACE_EXPORT_BEGIN`。总日志包含 12,259 行 DATA 标记，其中只有 12,258 行可解析为完整数据块。控制台第 170,709 行显示一个 DATA 标记在 payload 前被 `screendump OK` 文本打断；重组数据在零基块 10,807 处触发 `invalid stored block lengths`。QEMU 停机后，修正过路径的 guest 文件回收也未找到 `/root/mp-perf-trace.json`，说明 trace 文件只在 guest 运行期可见。

R4 将把周期截图间隔移出本次串口传输窗口，并为数据块加入连续序号及末尾块数校验。该设计用于让丢块可定位；R3 数据本身保持原样，不修补或重新解释为有效 trace。

## 文件与复核

- `remote-archive-no-ppm.tgz` 包含完整非 PPM 日志和判据；SHA-256 为 `bf9deefcbed57de2d979eaa5560b1a4a6014bc91c2597fd44cf7d100f28251e5`，共 87 项，不含 PPM。
- `ppm-sha256.txt` 列出 T490 上保留的 31 张原始 PPM；本地仅保存 PNG 预览。
- `screenshots/` 是首页、重载和最后周期帧的可查看 PNG。
- `trace-extraction-result.txt` 记录串口重组失败位置；原始串口日志和事件文件在 `remote/`。
- [报告 365](../../report/365-T490性能trace试采r3串口数据受截图状态串扰-20261120.md) 汇总原因和 R4 修正方案。
