# T490 procfs RSS/PSS/USS guest复测 R1（2026-11-20）

## 结论

在当前 ac1032 候选内核、2 GiB AArch64 纯 TCG guest 中，复跑了32页的独立 procfs 内存探针。九个阶段全部返回数值 `Rss/Pss/USS/Shared`；匿名触页、文件私有/共享映射、fork/COW和unmap变化与此前Linux参考的阶段增量一致。探针返回0。

这关闭的是 procfs 单地址空间驻留统计的复测证据，不是 Chromium 进程树每秒 RSS/PSS/USS 峰值样本；四项性能指标和before/after仍未完成。

## 结果

完整阶段数据见 [`memory-summary.txt`](memory-summary.txt) 和 `remote/console.log`。关键变化：

- 匿名触页：RSS/PSS/USS各增加128 kB；
- 文件私有首次触页：三项各增加128 kB；
- 文件共享映射：RSS +128 kB、PSS不变、USS −128 kB、Shared +256 kB；该增量与 [Linux reference report 336](../../report/336-T490-native-Linux-procfs-memory-parser-r2-20261119.md) 一致；
- parent COW 后：PSS +4 kB、USS +8 kB、Shared −8 kB；
- unmap 后 RSS/PSS/USS回到本轮baseline 128 kB，VmHWM保留512 kB。

## 运行条件与证据

- 内核SHA-256：`ac1032fe98c382cc37646a12453b7141b789c9abfe1651ff5f8f1e0263767fa2`；T490 Linux 7.0；QEMU 10.2.1；2 GiB；4 vCPU；纯TCG。
- guest探针：`scripts/t490/procfs_memory_probe.c`；执行入口：`scripts/t490/autorun_procfs_memory_probe.sh`。
- 非PPM归档SHA-256：`c3cd452cbf4a8241239cde08adb3b970a170371a235abfe136daf9743f1a1462`，共32项；8张原始PPM保留在T490，SHA清单见 `ppm-sha256.txt`。
- 完整console、命令、环境和判据在 `remote/`。
