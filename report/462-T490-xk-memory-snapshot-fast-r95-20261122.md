# T490 R95 快速 xk_memory_snapshot 取样（2026-11-22）

R95 去掉 guest sampler 每次读取后的额外 1 秒睡眠，使用与 R93 相同的完整 RSS/PSS/USS 快照接口，验证“约 1 Hz”是否主要被脚本间隔拖慢。kernel 使用 R94 同一构建，SHA-256 为 `188dcc92149c61d2ee1eb16975e8bab7a187fbc59e51fb2e872009ed3975b7ec`。

## 结果

guest 脚本计数为 20 次、19 次 `complete=1`。串口解析受快速连续输出影响，只观察到 18 个 block，其中 17 个完整、1 个 `tree_changed`；两个 marker block 没有在 console 中完整落地。可见样本统计为：

| 项目 | 中位数 | P95 | 最大值 |
|---|---:|---:|---:|
| 读取总耗时 | 323 ms | 834.2 ms | 1051 ms |
| begin 间隔 | 747 ms | 1580.2 ms | 2025 ms |
| resident walk | 25.345872 ms | 172.912714 ms | 592.335920 ms |
| mapcount | 6.480336 ms | 14.992365 ms | 15.432992 ms |
| rollup | 0.367344 ms | 0.645434 ms | 0.985696 ms |

完整原始材料和 parser 输出在 [R95 evidence](../evidence/2026-11-22_t490-r95-xk-snapshot-fast/)。可见完整样本的进程树行数只有 1，说明取样窗口早于 Browser 子进程树完全建立；它不能作为进程树峰值内存数据。

## 判定

去掉脚本睡眠后，begin 间隔确实接近 1 秒，说明前一轮的约 2 秒间隔有一部分来自脚本节奏；但快速输出增加了串口 marker 丢失，且本轮没有覆盖完整 Chromium 进程树。R95 仍是采集器诊断，不写入正式 before/after CSV，也不改变性能 0/0。

后续正式采集必须把快照写入 guest 文件并在安静阶段校验哈希后导出，不能把并发串口输出直接当作完整样本流。
