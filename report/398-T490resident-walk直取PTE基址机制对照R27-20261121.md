# T490 resident-walk 直取 PTE 物理基址机制对照 R27（2026-11-21）

## 变更与单测

R26 阶段计时显示 `resident_page_frames()` 对每个已遍历的 present leaf 又调用 `PageTable64::query(leaf_base)` 取物理基址，造成重复页表遍历。R27 新增 `visit_present_mappings_in_range()`，在遍历 leaf PTE 时一并返回该 PTE 的物理基址；procfs resident walker 复用该值，移除每个 leaf 的第二次 query。现有 `visit_present_in_range()` API 保留为兼容 wrapper。

新增 4 KiB 与 2 MiB leaf 物理基址测试。T490 AArch64 guest page-table 单测 `make unittest UNITTEST_CRATE=page_table MEM=2g VSOCK=n` 结果 **11 passed, 0 failed**，覆盖报告也生成。增量补丁在 [`patches/t490-procfs-resident-walk-direct-pte-r27.patch`](../patches/t490-procfs-resident-walk-direct-pte-r27.patch)；将它在当前 R26 dirty kernel worktree 上反向校验成功。patch 的目标父状态是该 worktree 的兼容性改动集，不能单独应用到干净 `b73e581`。

## 同条件单轮机制对照

R26 与 R27 均为 T490、AArch64 pure TCG、2 GiB、Chromium 149.0.7827.53、同一 base image、页面、1 Hz sampler、900秒窗口、一次重载与420秒诊断保持。R27 只改 resident leaf 物理基址获取路径。R26 kernel SHA-256 为 `da0c3802…de07f`；R27 为 `95db6f57…de34db`。

| 指标 | R26 before | R27 after | 变化 |
|---|---:|---:|---:|
| resident walk 中位 / P95 | 206.379 / 1,906.268 ms | 185.688 / 1,399.518 ms | -10.03% / -26.58% |
| tree snapshot 总耗时中位 / P95 | 227.123 / 1,964.148 ms | 208.269 / 1,471.916 ms | -8.30% / -25.06% |
| sampler sample-work 中位 / P95 | 1,402.324 / 10,586.355 ms | 1,356.863 / 8,977.207 ms | -3.24% / -15.20% |
| sample IDs / missed | 220 / 213 | 225 / 210 | 样本略增、missed 略降 |
| memory/tree errors | 271 | 277 | 增加6 |
| overrun 中位 / P95 / 最大 | 2.621 / 14.217 / 22.384 s | 2.046 / 15.873 / 59.825 s | 中位下降，尾部与最大值退化 |
| sampler status | `FAIL` | `FAIL` | 无变化 |

R27 的 resident-walk 与 tree-snapshot 中位/P95 方向向好，但只有每侧一轮；sample-work 仍超过1秒，sampler 错误更多，最大 overrun 达59.825秒。该候选仅保留为实验补丁，**不计为可靠性能收益**，不生成正式 RSS/PSS/USS peak，也不纳入四指标 CSV。需要在修复1 Hz完整采样后做至少五次交替 before/after 复测。

## 功能与采集结果

R27 官方首页 strict、1/1真实 Ctrl+R 重载和420秒诊断保持通过。Browser launch `43.680251488 s` 到 main-loop-ready `85.012754304 s` 为单轮 **41.333 s**。导航请求 `157.167639248 s` 到 strict screenshot guest-clock 上界 `651.385587458 s` 为 **494.218 s**，QMP采样间隔30秒；该上界不是精确 first-frame。`renderer_ready` 与 `first_valid_frame` 仍缺。

collector 正确拒收 R27：除生命周期/首帧缺项外，还报告 `PID reuse without an observed exit: pid=474, old=474-15478, new=474-15776`。不能通过放宽 PID 复用校验把该轮改成有效样本。

完整 before/after 单轮原始计时和错误字段见 [`mechanism-comparison-r26-r27.json`](../evidence/2026-11-21_t490-r27-resident-walk-fastpath/mechanism-comparison-r26-r27.json)；R27 的 sampler 导出、merged ledger、collector拒收、单测日志和环境指纹见 [R27 evidence](../evidence/2026-11-21_t490-r27-resident-walk-fastpath/)。原始 PPM 留在T490，对应 [SHA-256索引](../evidence/_ppm-sha256-r27-resident-walk-fastpath.txt)。
