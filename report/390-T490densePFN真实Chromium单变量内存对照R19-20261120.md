# T490 dense PFN 候选真实 Chromium 内存单变量对照 R19（2026-11-20）

## 结论

R19 使用 R18 dense PFN mapcount kernel，在无 startup trace 的条件下复跑 R17 memory-only Chromium 场景。平台、镜像、页面、sampler 900 秒、trace-off、ready deadline1200、1 次真实 Ctrl+R、30 秒 settle、800 秒 diagnostic hold 均与 R17 相同；唯一代码差异是 BTreeMap mapcount 索引替换为 2 GiB PFN dense counter（较大 PFN 范围仍走稀疏回退）。首页 strict 在 `589.244 s` 通过，重载 `1/1` 通过，800 秒保持完成；内存 bundle 也完整传输并解包。

R19 仍是单 pair 的诊断对照，不能作为已验收性能收益。与 R17 相比，sample ID 从218增至298，CSV行从1,329增至1,871，overrun条数从186降至109，中位数从2,387降至1,969 ms，missed从213降至146，错误总数从221降至150；但P95从8,401升至15,885 ms，最大overrun从78,962升至88,210 ms，首屏 strict 也慢了约125.6秒。dense PFN 的几个中位与计数指标方向改善，尾部延迟反而恶化，且 R19 status 仍 `FAIL` (`missed=146`)。因此该优化候选尚未通过重复验证，不进入最终性能收益结论，也不能提供有效Chromium峰值RSS/PSS/USS。

证据：[evidence/2026-11-20_t490-r19-dense-memory-only-ready1200](../evidence/2026-11-20_t490-r19-dense-memory-only-ready1200/)。串口 console 是未修改原文；内存包来自83个校验通过的serial块，但`memory-export/extraction.json`明确为`valid=false`。PPM原件留在T490，SHA-256清单为 [`evidence/_ppm-sha256-r19-dense-memory-only-ready1200.txt`](../evidence/_ppm-sha256-r19-dense-memory-only-ready1200.txt)。

## 单变量数据

| 指标 | R17 parent：BTreeMap | R19 candidate：dense PFN | 变化/判定 |
|---|---:|---:|---|
| Kernel SHA-256 | `f988d68b…` | `beaa8636…` | R19 only changes PFN count index |
| Trace | off | off | 固定 |
| Page strict ready | 463.688 s | 589.244 s | R19 +125.556 s；方向退化 |
| Strict reloads | 1/1 | 1/1 | 两轮通过一次 |
| Memory sample IDs | 218 | 298 | +36.7%，但均非完整1 Hz |
| CSV rows | 1,329 | 1,871 | +40.8%，进程实例数量不同 |
| sampler `missed` | 213 | 146 | −31.5%，仍未通过 |
| Sampling errors | 221 | 150 | −32.1%，仍未通过 |
| Overrun events | 186 | 109 | −41.4% |
| Overrun median | 2,387 ms | 1,969 ms | −17.5% |
| Overrun P95 | 8,401 ms | 15,885 ms | +89.1%，尾部变差 |
| Maximum overrun | 78,962 ms | 88,210 ms | +11.7%，最坏值变差 |

R17 status记`process_instances=9`、CSV内8种身份；R19 status记10、CSV内9种身份，说明部分曾观察到的短命进程没有覆盖完整样本行。R19错误项为186 overrun events、33次进程树读取不可用、4次bulk endpoint不可用、4条sample incomplete，共150条；R17对应为186、19、8、8，共221条。

两轮 `collect_metrics.py` 均未接受为四指标样本，因为采集事件账本缺少 `browser_main_loop_ready`（具体拒绝见各自的 `collect-metrics-validation.json`）。即便关闭 trace，R19仍未能连续每秒采样，也没有可报的60秒页面后峰值。

## 构建与回归

R19使用R18同一内核文件，SHA-256 `beaa86361cdff4a6504d16acbb565c5e598f0095fbccb81565b3a3c2c5ba436f`。dense PFN 补丁见 [`procfs-pfn-count-dense.patch`](../patches/compat/procfs-pfn-count-dense.patch)；其2 GiB guest内存语义9阶段回归 `rc=0` 见 [report 389](389-T490densePFNmapcount候选构建及PSS-COW回归R18-20261120.md)。

## 后续动作

将dense PFN索引保留为候选/回退提交，继续分析R15/R17/R19的`resident_page_frames()`页表遍历耗时和长尾阻塞；增加单次采样阶段计时并确保采样ledger包含Browser ready、renderer request/ready、navigation、first-frame/page verdict。当前候选尚无5+5有效before/after，也未通过四指标收集器，不能宣称正式收益。
