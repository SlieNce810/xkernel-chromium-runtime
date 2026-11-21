# R61：c78 候选 focused 兼容性复测失败

R61 在 no-direct-PTE、`LOG_LEVEL_ERROR` 候选内核 `c78ecd57fb47b8269ebecf0a4e99ee5d9f85648e01703726eee7af88ad017a67` 上运行兼容性 bundle。T490 干跑的 2 GiB AArch64 pure-TCG 命令平台门禁 15/15 通过，实际 QEMU `-kernel` 路径与候选 SHA 一致。

这次测试拒绝该候选作为最终兼容性内核：全量 ABI probe 35/37，inotify create 事件轮询失败，`MADV_DONTNEED` 覆盖未映射 gap 错误返回成功（Linux 预期 `ENOMEM`）；SCM_RIGHTS short-read 4/6，fd 首字节交付失败且后续读取重复交付；memfd sealing 6/12，添加 seals 返回 `EPERM` 且后续 seal 语义不符；procfs 分配/fork/COW/unmap probe 返回码 0，但 `file_shared_touched` 的 `statm_shared_pages=32` 与 `smaps_shared_kb=0` 不一致，需要进一步核实共享计量。

兼容性 bundle 汇总 `overall_rc=1`。会话期间两张黑屏 PPM 为 640×480，`ppm-summary.txt` 标明分辨率不符合 1280×800 决赛画幅；它们不构成页面或功能证据。QEMU 在 bundle 完成和五个 probe hold tick 后结束，未把剩余时长误算为稳定性验证。

原始 console、平台门禁、实际命令、内核指纹、probe 逐项输出和 PNG 预览均在本目录。原始 PPM 留在 T490，SHA-256 在 [R61 PPM 清单](../_ppm-sha256-r61-c78-compat-probe.txt)。对应干跑材料在 [R61 preflight](../2026-11-21_t490-r61-c78-compat-recheck/)。

这项复测说明 R58–R60 的稳定性成功只适用于其候选内核，不可覆盖兼容性缺陷。此前兼容性矩阵最终通过的 `ac1032fe…` SHA 结果保持原样；c78 不替换该矩阵摘要。

详细缺陷和后续修复方向见 [R61 兼容性失败报告](../../report/434-T490-R61-c78候选兼容性回归失败-20261121.md)。
