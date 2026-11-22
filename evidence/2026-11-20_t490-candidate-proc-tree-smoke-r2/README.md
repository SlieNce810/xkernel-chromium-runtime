# T490 proc_tree_sampler guest smoke R2（2026-11-20）

## 结果

R2确认R1的root发现问题：guest `/proc/5/stat` 合法地报告字段22 `starttime=0`。采样器放宽该值后识别到2个进程并运行8个1秒样本周期，C helper返回 `missed=0`、没有 `smaps_rollup=unavailable` 错误。内存CSV没有在控制台输出，所以该轮不能核实实际RSS/PSS/USS数值，也不能作为内存测量样本。

外层smoke gate仍失败，因为BusyBox `awk` 对 `print NR > 0 ? NR - 1 : 0` 的重定向/条件解析导致 `sample_rows` 为空。R3已把行数统计改为 `wc -l`，并会逐项核对RSS/PSS/USS数值。

## 运行身份与界面

T490 `10.249.11.192`，Ubuntu 26.04.1 / Linux 7.0.0-43 / QEMU 10.2.1；AArch64 2 GiB pure TCG、4 vCPU；kernel SHA-256 `ac1032fe98c382cc37646a12453b7141b789c9abfe1651ff5f8f1e0263767fa2`。该轮没有启动Chromium。QEMU 45秒画面显示display output未激活；它不是浏览器页面证据。

## 证据

- 完整命令、环境、console、platform合规、采样器启动行与PPM判据：[remote-archive-no-ppm.tgz](remote-archive-no-ppm.tgz)，SHA-256 `3439cb3d2200328e4b945c49d811bb6764535c924f13e7caef99700bb5651611`。
- 交叉编译与注入过程：[host-round.log](host-round.log)。
- 原始PPM保留在T490，SHA见[清单](ppm-sha256.txt)；可查看 [45秒启动截图](screenshots/shot-01-at0045s.png)。

\n