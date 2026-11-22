# T490 R99 延迟 60 样本完整进程树内存窗口（2026-11-22）

R99 在启动后延迟约 300 秒，使用已验证的压缩串口导出协议连续采集 60 个快照。每个快照包含 Browser 进程树 7 行，目标是验证完整进程树上的约 1 Hz 采样和 60 秒级内存窗口。

## 传输与样本完整性

host extractor 对 20 个 base64 chunk 做了序号、长度、gzip、tar 和 SHA-256 校验，结果 `integrity=PASS`。guest 报告 60/60 完整，host parser 也恢复并验证 60/60 完整，没有 `tree_changed` 或缺失样本。

R99 复用了 R97 exporter 的默认 payload run ID `r97-xk-snapshot-export`；evidence 目录和解析标签是 `r99-xk-snapshot-export-delayed60`，这一映射保留在导出 JSON 和命令材料中，后续应把 run ID 注入 guest 以消除该标签差异。

## 采样结果

| 指标 | 中位数 | P95 | 最大值 |
|---|---:|---:|---:|
| 快照读取耗时 | 603.5 ms | 678.85 ms | 807 ms |
| begin 间隔 | 911 ms | 1036.1 ms | 1198 ms |
| resident walk | 145.366352 ms | 162.984257 ms | 219.166048 ms |
| mapcount | 7.244288 ms | 7.726762 ms | 7.937888 ms |
| rollup | 2.848104 ms | 3.034775 ms | 3.308176 ms |
| 进程树行数 | 7 | 7 | 7 |

完整证据在 [R99 evidence](../evidence/2026-11-22_t490-r99-xk-snapshot-export-delayed60/)，包括原始 console、导出校验 JSON、恢复的快照日志、解析 JSONL、内存汇总 JSON、命令、artifact SHA-256 和 PPM SHA-256。

## 部分内存汇总

[partial-memory-summary.json](../evidence/2026-11-22_t490-r99-xk-snapshot-export-delayed60/partial-memory-summary.json) 对 60 个完整样本按进程树求和：

- RSS 峰值：`141863` 页，约 `554.15234375 MiB`；
- PSS 峰值：`99176` 页，约 `387.40625 MiB`；
- USS 峰值：`82077` 页，约 `320.61328125 MiB`；
- 共享页：`59786` 页，约 `233.5390625 MiB`。

该汇总的 `formal_valid=false`，因为采样窗口从延迟读取开始，没有覆盖 Chromium 启动到页面完成后 60 秒的全生命周期；它是目前最完整的后置进程树内存证据。

## 判定

R99 证明压缩、带 SHA 的串口导出可以稳定承载完整进程树的 60 个快照，并把采样间隔压到约 1 Hz。它仍不构成正式 before/after 性能批次，也没有提供 renderer-ready 或原生首帧事件；正式性能状态继续为 0/0。
