# R52：direct-PTE walker 回加复跑

R52 从冻结快照新建 candidate worktree，重新应用 stat22、procfs RSS/PSS/USS、tree rollup、dense PFN、timing 和 direct-PTE resident walker 补丁。observer-off配置、QEMU、内存、rootfs、页面、ready timeout与R50/R51相同。dry-run显示 `qemu_started=0`，内核构建通过。

结果重复 direct-PTE侧失败：1800秒内 strict 页面未通过；driver `STABILITY_DRIVER_RC=1`，53张1280×800截图 strict全失败，59次页面轮询通过0次。Weston/Chrome在末段保持存活，QEMU正常收尾；normalizer592/592通过，0修复。Sampler、preload和guest clock-sync均关闭，因此无memory/performance样本。

与R50相比，这次是用R52新建的干净冻结快照worktree重新应用同一patch并重建，source hashes与R50 direct-PTE候选一致；结果仍超时。R51不应用direct-PTE时则 strict首页/reload/420秒hold通过。这个重复对照强烈提示 direct-PTE patch 是图形启动回归源；仍有n=2 direct-on与n=1 direct-off，下一步以no-direct候选补做稳定性和功能检查，再决定该优化是否淘汰。

完整原始console、53张截图判据、QMP/liveness、build/source/platform和哈希见本目录。raw PPM留在T490，SHA索引在仓库 `evidence/_ppm-sha256-r52-direct-pte-repeat-control.txt`。
