# T490 dense PFN mapcount 候选构建与 PSS/COW 回归 R18（2026-11-20）

## 本轮结论

R18 在 R17 基础上应用一个独立的 procfs mapcount 候选：2 GiB 目标的 PFN 索引范围使用紧凑 `Vec<u32>` 直接计数，超过 4,194,304 个 PFN 槽位时保留 BTreeMap 稀疏回退；逐个进程地址空间和 PFN 只建立一份进程树快照。候选编译成功，并通过 9 阶段 `/proc/<pid>/smaps_rollup` 分配、触页、文件私有/共享映射、fork/COW、unmap 回归，probe `rc=0`。R18 是语义回归，不是 Chromium 进程树采样性能结果；dense count 的性能收益还没有通过 Chromium before/after 重复验证。

T490 的初始进程 probe 结果与已核对的 Linux 阶段增量一致：baseline RSS/PSS/USS/Shared=128/128/128/0 kB；匿名页触页后 256/256/256/0；file-private 后 384/384/384/0；file-shared 后 512/384/256/256；fork/COW 后父进程 512/285/60/452、子进程 228/123/20/208；unmap 后回到 128/128/128/0，VmHWM 保留 512 kB。完整原始 guest 输出在 `console.log`，Linux 增量对照见 [report 368](368-T490-procfs真实PSS-USS共享与COW统计复测-20261120.md)。

证据：[evidence/2026-11-20_t490-r18-pfn-dense-procfs-memory](../evidence/2026-11-20_t490-r18-pfn-dense-procfs-memory/)。QEMU 没有启动 Weston/Chromium，六张图形 strict 截图判据失败；这些截图不代表浏览器功能通过。PPM 原件仅存于 T490，哈希清单为 [`evidence/_ppm-sha256-r18-pfn-dense-procfs-memory.txt`](../evidence/_ppm-sha256-r18-pfn-dense-procfs-memory.txt)。

## 内核改动和构建

改动位于 T490 内核树 `fs/filesystems/procfs/src/task_nodes/root.rs::process_smaps_rollup_snapshot`。先保留每个进程的 resident PFN 列表，再通过 dense counter array 统计重复映射数、计算每进程 PSS/USS；物理 PFN 空间过大时转回稀疏 BTreeMap。补丁 [`procfs-pfn-count-dense.patch`](../patches/compat/procfs-pfn-count-dense.patch) 可反向检查，构建后 remote `git apply --reverse --check` 通过。

构建命令：

```bash
make build GRAPHIC=y ACCEL=n MEM=2g SMP=4 VSOCK=n
```

kernel.bin SHA-256：`beaa86361cdff4a6504d16acbb565c5e598f0095fbccb81565b3a3c2c5ba436f`。内核源码 HEAD `b73e5814087c9d33c5f0a35b66cc56be689d3dee`；T490 源码工作树有本轮前已有的多项未提交兼容修改，没有重置。

客体回归命令：

```bash
KERNEL_DIR=/home/mo/xk6/worktrees/xk-compat-fix-r1 BASE_IMG=/home/mo/x-kernel/images/pkg-installed.img bash scripts/t490/t490_round.sh r18-pfn-dense-procfs-memory 300 60   autorun_procfs_memory_probe.sh procfs_memory_probe.c
```

QEMU 参数来自正式 platform profile：AArch64 2 GiB、4 vCPU、`cortex-a76` 纯 TCG、virtio GPU/input/block/network。guest `procfs_memory_probe.c` 用 32 页构造，完成 anon、MAP_PRIVATE、MAP_SHARED、fork+COW、unmap；R18 的数值增量无语义回归。

## 性能对照定位

- R15 的 BTreeMap Chromium trace+memory 诊断：160 sample ID、158 missed、overrun 中位数 3.036 秒、最大 43.23 秒；见 [report 386](386-T490二GiB真实Chromium首次帧trace成功但树内存采样超时R15-20261120.md)。
- R17 的 BTreeMap trace-off Chromium memory 诊断：首页/重载通过，但 218 sample ID、213 missed、overrun 中位数 2.387 秒、最大 78.962 秒；见 [report 388](388-T490二GiB无traceChromium内存采样仍超时R17-20261120.md)。
- R18 只验证 dense PFN 计数的页共享/COW 语义，还没有采集 Chromium tree 1 Hz 时间或漏样数据。

R19 已完成一次 trace-off Chromium 对照：dense PFN 的 sample ID、missed 和 overrun median 优于 R17，但 P95/max overrun 与首屏时间变差；R19 仍 status FAIL，因此暂不认定优化收益。原始数据和单变量比较见 [report 390](390-T490densePFN真实Chromium单变量内存对照R19-20261120.md)。正式 5+5 before/after 和四项完整性能仍未完成。
