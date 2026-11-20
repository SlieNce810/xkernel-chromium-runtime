# Chromium 启动 trace 试采 R2

- 主机：T490 `10.249.11.192`；guest AArch64、2 GiB、纯 TCG；Chromium 149.0.7827.53。
- 结果：`--trace-startup` 确实出现在 Browser argv，Chromium日志报告trace完成；但 `/root/mp-perf-trace.json` 未回收到证据包，本轮不计性能样本。
- 稳定性诊断：首页 strict PASS、nav-01重载PASS、550秒保持、29/29周期截图成功；formal gate按diagnostic-only跳过。
- 原始 evidence 的guest回收脚本在本轮读了 `$HOME/x-kernel/disk.img`，而QEMU命令使用 `KERNEL_DIR/disk.img`；停机后 worktree disk debugfs 也没找到该trace文件。后续已补正镜像选择与串口 exporter，trace R3再复核。
- [报告 364](../../report/364-T490性能trace试采r2参数生效但guest文件未回收-20261120.md) 说明结果限制。
- `bundle-sha256.txt` 覆盖本目录其余归档文件；PPM 原始图像单独以 `ppm-sha256.txt` 校验，原件保留在 T490。
- 非PPM原始材料在 `remote-archive-no-ppm.tgz` 和展开的 `remote/` 树；31项原始PPM留在T490，SHA清单见 [ppm-sha256.txt](ppm-sha256.txt)。
