# Chromium 启动 trace 试采 R1

- 主机：T490 `10.249.11.192`；guest AArch64、2 GiB、纯 TCG；Chromium 149.0.7827.53。
- 结果：初始首页 strict PASS、nav-01重载 PASS、550秒 diagnostic hold通过；27/27周期截图成功。
- Trace试采未生效：实际 Chrome argv 无 `--trace-startup`，guest `/root/mp-perf-trace.json` 未生成。本轮不计性能样本。
- 根因：当时 `autorun_mp_score_observe6.sh` 没有消费 `EXTRA_FLAGS_VALUE`；后续已加入模板占位符与启动前 preflight 检查。
- [报告 363](../../report/363-T490性能trace试采r1未注入Chrome参数仅稳定性诊断通过-20261120.md) 说明结论与证据限制。
- 远端非PPM材料在 `remote-archive-no-ppm.tgz` 和展开的 `remote/` 树；29项原始PPM保留在T490，SHA清单见 [ppm-sha256.txt](ppm-sha256.txt)。
