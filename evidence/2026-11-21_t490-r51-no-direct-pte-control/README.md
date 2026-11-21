# R51：移除 direct-PTE walker 后的 observer-off 页面控制

R51 从冻结快照重建候选，保留 stat22、procfs RSS/PSS/USS、tree rollup、dense PFN 与 timing 补丁，但不应用 `t490-procfs-resident-walk-direct-pte-r27.patch`。其余与R50一致：T490、AArch64、2 GiB pure TCG、官方 rootfs、同一页面、sampler/preload/guest-clock-sync关闭。

候选编译通过（kernel.bin SHA-256 `2bca9a09…c230d011`）。真实诊断轮在 host elapsed `466.008 s` 首次 strict page pass，真实Ctrl+R reload 1/1通过，driver保持420秒并返回 PASS。PPM摘要记录22张截图、8张在首次strict通过帧之前失败，strict通过后没有退化；首屏与重载的可查看画面见 `stability/load-00-initial.png` 和 `stability/load-01-reload.png`。

事件normalizer `FAIL`：4个family snapshot freshness分别超限5.857、2.026、1.026和0.031秒（35秒上限）。因此本轮是页面启动/reload诊断通过，不是正式30分钟/10 reload稳定性PASS。memory sampler关闭，没有峰值或四项性能数据。

R50使用同一补丁栈但包含direct-PTE patch，observer-off时首屏1800秒超时；R51排除该patch后strict首屏、reload和420秒hold通过。这指向direct-PTE walker可能回归图形页面启动，但两轮各一份样本，仍需R52把patch重新加回复跑确认。PPM原件保留在T490，SHA索引见 `evidence/_ppm-sha256-r51-no-direct-pte-control.txt`。
