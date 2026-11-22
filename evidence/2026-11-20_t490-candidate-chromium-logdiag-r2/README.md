# Chromium 诊断日志 R2

- 主机：T490 `10.249.11.192`，Ubuntu 26.04.1 LTS，QEMU 10.2.1。
- Kernel：`ac1032fe98c382cc37646a12453b7141b789c9abfe1651ff5f8f1e0263767fa2`；Chromium：149.0.7827.53。
- Guest：AArch64，2 GiB，纯 TCG，Weston/Wayland。
- 结果：单调时钟快照 5 组；700 秒首屏 strict 等待超时；周期截图 16/16 strict 失败。diagnostic-only，正式 gate 跳过。
- `strace` 自检失败，未记录 syscall trace；快照本身记录 Browser 日志和 IPC 行。
- [报告 354](../../report/354-T490-ac1032诊断R2单调快照有效但首页首屏超时-20261120.md) 说明判定、对照和限制。
- 远端非 PPM 材料在 `remote-archive-no-ppm.tgz` 和展开的 `remote/` 树；17 项原始 PPM 留在 T490，SHA 清单见 [ppm-sha256.txt](ppm-sha256.txt)。
- 本地保留 3 张 PNG 预览，不保留原始 PPM。
