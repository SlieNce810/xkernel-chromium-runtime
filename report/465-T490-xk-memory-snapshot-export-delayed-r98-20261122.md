# T490 R98 延迟完整进程树快照导出（2026-11-22）

R98 在 Browser 启动后延迟约 300 秒，再使用 R97 的压缩串口导出协议读取快照。目标是让 Browser、Zygote 和 Renderer 进程树先建立，再验证完整进程树上的 1 Hz 前置采样。

## 传输完整性

host extractor 对 R98 console 完成二次校验：

- 原始 tar：`27136` bytes；SHA-256 `106a0069434c97ce1eaf89c0cebc1a36095305c60bc9cf2dcb48318d1e62d715`；
- gzip：`1662` bytes；SHA-256 `77d920e824b499d20265a4f57a54f2ccd693602ecdeb7ec7bfa6d928bece75c2`；
- 9 个 base64 chunk，序号、长度、begin/end 数量全部通过；
- tar 只有预期的 `xk-memory-snapshot-samples.log` 成员；
- `integrity=PASS`。

本轮 guest exporter 沿用了 R97 默认 payload run ID `r97-xk-snapshot-export`，而 evidence 目录和 host 解析标签为 `r98-xk-snapshot-export-delayed`；两者的映射已在命令和导出 JSON 中保留，后续脚本应把 run ID 作为注入参数而不是默认常量。

## 完整进程树结果

恢复的 20 个快照全部 `complete=1`，每个快照都有 7 行进程树数据；没有 `tree_changed` 或缺失样本。

| 指标 | 结果 |
|---|---:|
| 完整快照 | 20/20 |
| 进程树行数 | 7/7 |
| 读取耗时中位数 | 582.5 ms |
| 读取耗时 P95 | 610.9 ms |
| begin 间隔中位数 | 877 ms |
| begin 间隔 P95 | 929 ms |
| resident walk 中位数 | 138.880968 ms |
| mapcount 中位数 | 7.088448 ms |
| rollup 中位数 | 2.747088 ms |

完整原始 console、恢复的快照日志、导出校验 JSON、解析 JSONL、命令和哈希材料在 [R98 evidence](../evidence/2026-11-22_t490-r98-xk-snapshot-export-delayed/)。原始 PPM 仍只保留 SHA-256 清单。

## 判定

R98 是目前最接近完整内存采集口径的一轮：进程树完整、20/20 快照有效，begin 间隔中位数低于 1 秒，且传输完整性可独立复核。它仍是单轮诊断，尚未完成 60 秒峰值窗口、before/after 各五轮，也没有 renderer-ready/first-valid-frame 事件，因此不改变正式性能 0/0 审计。
