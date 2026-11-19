# Chromium 正式稳定性 R4

- 主机：T490 `10.249.11.192`；guest AArch64、2 GiB、纯 TCG；Chromium 149.0.7827.53。
- Kernel SHA-256：`ac1032fe98c382cc37646a12453b7141b789c9abfe1651ff5f8f1e0263767fa2`。
- 结果：初始首页 strict 在2,400秒内未通过（79次轮询）；未发出重载，未开始保持；正式 gate FAIL。
- 73/73周期截图已判，strict PASS 0/73；780条 guest watchdog 和60条 host liveness显示Weston/Chrome存活。
- 新版 `round_assert` 的三个字段为 `last_frame_strict_pass=0`、`any_strict_pass=0`、兼容 `last_pass=0`。
- [报告 361](../../report/361-T490-ac1032正式稳定性r4首屏超时及明确last_frame字段-20261120.md) 说明结果与限制。
- 非 PPM 原始材料在 `remote-archive-no-ppm.tgz` 和展开的 `remote/` 树；74项原始 PPM 留在 T490，SHA 清单见 [ppm-sha256.txt](ppm-sha256.txt)。
- 本地仅存3张 PNG 预览，不保留 PPM 本体。
