# T490进程树采样器 guest smoke R3：RSS/PSS有效，USS读为零（2026-11-20）

R3在2 GiB AArch64纯TCG guest中完成root进程PID5和helper PID11的8个每秒采样点，共16行CSV。x-kernel `/proc/<pid>/smaps_rollup` 对root/helper输出了非零RSS/PSS（560/346 kB、160/160 kB）；但当前采样器没有解析内核提供的 `USS:` 字段，转而汇总标准Linux `Private_*`字段后得到USS=0。smoke拒绝该结果，未计入Chromium峰值或性能样本。

原始 `/proc` 页面尚未随R3导出，现有日志足以定位到采集器字段适配缺口，R4会加入 `USS:` 优先读取并保存原始rollup片段。完整原始证据见[R3 archive](../evidence/2026-11-20_t490-candidate-proc-tree-smoke-r3/remote-archive-no-ppm.tgz)。

\n