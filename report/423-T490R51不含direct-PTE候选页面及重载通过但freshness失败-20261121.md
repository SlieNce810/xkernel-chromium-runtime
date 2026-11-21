# T490 R51 排除 direct-PTE patch 后页面通过（2026-11-21）

## 单变量对照条件

R51 从冻结快照重建隔离 worktree，应用 stat22、RSS/PSS/USS mapcount、tree rollup、dense PFN 和 procfs timing 补丁；**不应用** `t490-procfs-resident-walk-direct-pte-r27.patch`。Guest 为2 GiB AArch64 pure TCG，官方 Chromium 149 rootfs、官方HTML、QEMU/CPU/图形输入参数和 R50 相同。Sampler、lifecycle preload、guest clock-sync 均关闭；process scan30秒、family watchdog25秒。

R50 使用同一补丁栈但包含 direct-PTE patch，observer-off 参数也相同；R50 在1800秒首屏deadline超时，53张strict截图全部失败。R51 的隔离候选kernel.bin SHA `2bca9a09…c230d011`，build通过，完整来源见 [R51 evidence](../evidence/2026-11-21_t490-r51-no-direct-pte-control/)。

## 页面结果

R51 首屏 strict 在 **466.008秒 host elapsed** 通过，真实Ctrl+R reload 1/1通过，随后 driver hold420秒完成，driver返回 `pass=1`。截图序列22张；8张发生在首次strict通过前，strict通过后未出现退化；最后一帧仍strict通过。可查看首屏与重载画面见 [initial strict screenshot](../evidence/2026-11-21_t490-r51-no-direct-pte-control/stability/load-00-initial.png) 和 [reload strict screenshot](../evidence/2026-11-21_t490-r51-no-direct-pte-control/stability/load-01-reload.png)。

事件normalizer `FAIL`：4个完整 family snapshot freshness 分别超限5.857、2.026、1.026和0.031秒（35秒上限）。因此本轮是页面启动/重载诊断通过，但不是正式30分钟/10 reload稳定性PASS。memory sampler关闭，没有四项性能数据。

## 对 R50/R51/R52 的结论

R50、R52两个direct-PTE-on构建均在observer-off条件下1800秒首屏超时；R51排除该patch后strict首屏、reload和420秒hold通过。direct-on失败方向在回加复跑中重复，**强烈提示 direct-PTE patch 可能破坏图形页面启动**。R27历史机制测试曾显示resident-walk耗时下降，但未做同内核renderer图形回归；目前应把该优化从候选版本排除，直到证明无回归。R51的normalizer仍拒绝4个stale family snapshots，故no-direct候选需要先修freshness设置并通过稳定性/功能回归。当前direct-on为2轮失败、direct-off为1轮页面通过，样本仍不足以做正式性能收益结论。

完整构建、命令、平台、QMP、liveness、normalizer和PPM判据均在 [R51 evidence](../evidence/2026-11-21_t490-r51-no-direct-pte-control/)；R52回加复测及源码/原始记录见 [report/424](424-T490R52direct-PTE回加重复复测首屏仍超时-20261121.md) 和 [R52 evidence](../evidence/2026-11-21_t490-r52-direct-pte-repeat-control/)。raw PPM 留在T490。
