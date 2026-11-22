# Chromium 诊断日志 R1

- 主机：T490 `10.249.11.192`，Ubuntu 26.04.1 LTS，QEMU 10.2.1。
- Kernel：`ac1032fe98c382cc37646a12453b7141b789c9abfe1651ff5f8f1e0263767fa2`；Chromium：149.0.7827.53。
- Guest：AArch64，2 GiB，纯 TCG，Weston/Wayland。
- 结果：strict 首页通过、1/1 次重载通过、保持 60.001 秒；仅 diagnostic-only，正式 gate 跳过。
- trace 限制：guest `strace` 自检失败；旧 tick 调度器未输出 Chromium 周期诊断快照。新单调时钟采样器在提交 `cf4cae6`，后续轮次再验证。
- [报告 353](../../report/353-T490-ac1032诊断日志采集r1页面通过但strace不可用-20261120.md) 说明判定与限制。
- 远端非 PPM 原始材料保存在 `remote-archive-no-ppm.tgz` 和展开的 `remote/` 树；13 项原始 PPM 保留在 T490，SHA-256 清单为 [ppm-sha256.txt](ppm-sha256.txt)。
- 三张 PNG 为原始 PPM 的可查看预览；未将 PPM 本体复制到本地仓库。
