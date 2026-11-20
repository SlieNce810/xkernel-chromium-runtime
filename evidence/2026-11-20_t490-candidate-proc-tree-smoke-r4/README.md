# T490 proc_tree_sampler guest smoke R4（2026-11-20）

## 结果

R4完成了C采样器在目标guest上的基本闭环。AArch64 musl二进制以 `-Wall -Wextra -Werror` 编译通过；guest root PID5和子进程PID11被正确识别，8个每秒采样周期写出16行RSS/PSS/USS记录，`missed=0`、缺失rollup计数为0、所有三类值均大于0。raw `smaps_rollup` root统计为Rss560 kB、Pss310 kB、USS132 kB；第一批样本中的root RSS/PSS/USS为560/346/132 kB，helper为160/160/160 kB。

这轮只构造了一个shell root及采样器子进程，验证procfs字段与采样实现；没有启动Chromium，因此仍不是用户要求的Chromium进程树样本，也不能填入性能CSV。

## 证据

- 完整guest命令、console、环境、编译/注入、平台合规和PPM判据见[remote-archive-no-ppm.tgz](remote-archive-no-ppm.tgz)，SHA-256 `33ab2e8f97f104b23d3b616f571673929866d362f95a2882e6c6bdcb2cddb615`。
- T490 host交叉编译与会话日志见[host-round.log](host-round.log)。
- 原始PPM留在T490，六张同内容帧的SHA-256见[ppm-sha256.txt](ppm-sha256.txt)；[45秒空画面预览](screenshots/shot-01-at0045s.png)不是浏览器画面。

\n