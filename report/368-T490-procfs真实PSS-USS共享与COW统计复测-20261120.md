# T490 procfs真实 RSS/PSS/USS 共享与COW统计复测（2026-11-20）

## 结论

R1使用候选内核 `ac1032fe98c382cc37646a12453b7141b789c9abfe1651ff5f8f1e0263767fa2`，在2 GiB AArch64纯TCG guest中复跑 `procfs_memory_probe.c`。`/proc/<pid>/smaps_rollup` 的 `Rss/Pss/USS/Shared` 九个阶段都返回数值，匿名页、文件页、共享映射、fork/COW和unmap变化均有响应，探针RC=0。

内存变化与Linux参考一致：

| 阶段/变化 | RSS | PSS | USS | Shared | 结果 |
|---|---:|---:|---:|---:|---|
| baseline | 128 | 128 | 128 | 0 | 数值可用 |
| anon touched | 256 | 256 | 256 | 0 | +128/+128/+128/0 |
| file-private touched | 384 | 384 | 384 | 0 | 再+128/+128/+128/0 |
| file-shared touched | 512 | 384 | 256 | 256 | 相对前阶段+128/0/−128/+256，匹配Linux参考 |
| parent before COW → after COW | 512→512 | 281→285 | 52→60 | 460→452 | +0/+4/+8/−8 |
| after unmap | 128 | 128 | 128 | 0 | 回到本轮baseline；VmHWM仍为512 |

子进程COW阶段也保留在完整日志与总结表里。Linux参考测量本身有较大的动态装载基线，因此这里按同一探针内的阶段增量比较，不比较绝对RSS值。增量与 [report 336](336-T490-native-Linux-procfs-memory-parser-r2-20261119.md) 和 [report 338](338-MAP_PRIVATE页缓存共享与PSS-USS%20guest复测-20261119.md)一致。

## 口径边界

该探针只覆盖一个小进程的固定32页构造，证明 `/proc/<pid>/smaps_rollup` 提供了真实数字并反映共享映射/COW/unmap。它没有采集Chromium完整进程树的每秒RSS/PSS/USS，没有覆盖页面完成后的60秒峰值窗口，不能填充 `collect_metrics.py` 所需的 `memory-samples.csv`。Chromium进程树峰值样本仍无效，四项性能指标和优化前后统计仍未完成。

完整原始材料见 [procfs memory evidence](../evidence/2026-11-20_t490-procfs-memory-r1/)。8张原始PPM保留在T490，仓库保存SHA清单；本轮未用空白GUI画面作为视觉验收结论。
