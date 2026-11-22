# 性能采集与跨层优化复核 R79–R85（2026-11-22）

## 结论

四项性能指标仍为 **0/0 有效 before/after 批次**。采集器确实取得了真实 Chromium 生命周期和内存原始数据，但当前 c80 guest 的 procfs 树统计在 1 Hz 固定口径下持续超时或返回不可用，collect_metrics.py 正确拒绝这些轮次。没有把 invalid 数据写进正式性能 CSV。

## 采集器改进

- autorun_mp_score_observe6.sh 已产生 Browser launch、Browser main-loop、zygote fork、renderer ready、guest 单调 clock-sync、1 Hz RSS/PSS/USS 和完整 gzip/base64 导出。
- R79 的内存导出与周期 screendump 并发，serial monitor 丢失中间 chunks，作为导出完整性失败样本保留。
- R80/R81 修正为首帧附近单次 screendump，R81 导出完整，原始内存 bundle 含 254 个 sample IDs、1607 行 process rows，但 sampler status FAIL、212 个 memory/tree errors、82 个 overrun；sample-work 中位 1.229 s、P95 2.534 s。
- merge_lifecycle_events.py 增加了缺失 native first-frame callback 时的保守派生事件：最早严格 screendump（或 page verdict）作为 first-frame upper bound，保留采样间隔和 source 字段，不伪造精确 compositor 时间。

## 优化候选

### 页表物理基址直传

候选在页表一次遍历中直接传递 leaf physical base，去掉 resident frame 的二次 query。R83/R84 使用该候选 hash 4fab1add…：

- R83 页面 smoke/采样仍为 invalid，memory 219 errors、74 overrun，sample-work 中位 1.206 s、P95 2.759 s。
- 与 R81 的 resident-walk 中位 185.8 ms/P95 696.7 ms 相比，R83 观测到 161.4 ms/P95 684.9 ms；这只是单轮诊断方向，页面/内存门禁未通过，不能作为可靠性能收益。
- R82 页面 smoke 在 650 秒内 0/8 strict，候选未进入最终版本。

### 串行 per-PID 与并行 per-PID sampler

R84 串行 per-PID 读 smaps_rollup、R85 并行 per-PID 读均未通过：

- R84：112 errors、96 overrun，overrun 中位 3.589 s。
- R85：154 errors、130 overrun，仍无法形成连续 1 Hz 有效时间序列。

这些实验验证了 guest procfs 读取和 TCG 调度是主要热点；它们未被接纳为正式优化。

## 证据

- R79：evidence/2026-11-22_t490-r79-perf-before-r1/
- R80：evidence/2026-11-22_t490-r80-perf-before-r2/
- R81：evidence/2026-11-22_t490-r81-perf-before-r3/
- R82：evidence/2026-11-22_t490-r82-fastpath-smoke/
- R83：evidence/2026-11-22_t490-r83-perf-after-r1/
- R84：evidence/2026-11-22_t490-r84-perf-after-r2/
- R85：evidence/2026-11-22_t490-r85-perf-after-r3/

每个目录提交 PNG 预览、命令/环境、console、memory export 摘要、PPM SHA-256；原始 PPM 保留在 T490。正式审计继续报告 performance INCOMPLETE，不把这些 invalid 轮次充当四指标样本。

