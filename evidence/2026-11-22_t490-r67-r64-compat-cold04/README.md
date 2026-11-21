# R67：R64 compatibility 候选 2400 秒首屏超时

R67 使用与 R65/R66 完全相同的 a70e kernel binary SHA `a70ecb4a34910f56c31d677f1b27d3a25088b94dc2fc82ba13b33544f34e3c1f`、2 GiB AArch64 pure TCG、Chromium 149.0.7827.53、2400 秒首屏期限、一次重载计划和 420 秒保持计划。QEMU 内核路径/哈希与 dry-run 预期匹配。

此轮在 2400 秒内没有严格页面通过。八张周期截图（guest 240 到 2342 秒）及 driver 的 `load-00-initial-timeout.ppm` 哈希一致，均为白屏严格 1/7。Chromium、Weston 和三个 renderer 仍被观察为存活，没有 Wayland fatal；事件归一化 1103/1103 PASS、0 修复。driver 明确报告 `initial strict page gate timed out`，未进入重载或保持，driver rc=1、round rc=0、diagnostic gate rc=78。此轮是有效的冷启动失败样本，不能计为稳定性通过。

R65/R66 在同一 kernel SHA、相同 tracked source diff 和相同运行参数下通过页面/重载/420 秒诊断保持；R67 的超时证明候选启动表现仍有显著间歇性。原始 PPM 全留在 T490，SHA-256 在 [R67 PPM 清单](../_ppm-sha256-r67-r64-compat-cold04.txt)；PNG 预览、完整 console、事件和 QMP transcript 已归档。

精确内核路径/哈希干跑在 `preflight-dry-run.txt`。详细分析见 [R67 报告](../../report/440-T490-R67-a70e候选首屏超时-20261122.md)。
