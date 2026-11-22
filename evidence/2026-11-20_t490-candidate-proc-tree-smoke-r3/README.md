# T490 proc_tree_sampler guest smoke R3（2026-11-20）

## 结果

R3解决了R1/R2的guest root发现问题。采样器在2 GiB AArch64纯TCG guest里找到root PID5及子进程PID11，每秒完成8个采样周期，共输出16行进程内存记录；root和helper的RSS/PSS分别为560/346 kB和160/160 kB。但两者USS都为0，smoke正值门禁按预期失败。该轮不是有效的内存样本，也没有启动Chromium。

缺口已收窄到USS字段读取：x-kernel `smaps_rollup` 有自定义 `USS:` 输出，R3采样器只汇总Linux `Private_Clean/Private_Dirty/Private_Hugetlb`，所以把guest的私有集写成0。R4在同一C采样器中优先读取自定义 `USS:`，并把root的 `smaps_rollup` 原始字段打印到console供对照。

## 运行身份与证据

T490 `10.249.11.192`，AArch64、2 GiB、纯TCG、4 vCPU，kernel SHA-256 `ac1032fe98c382cc37646a12453b7141b789c9abfe1651ff5f8f1e0263767fa2`。完整命令、console、host编译注入日志、PPM判据及环境见 [R3 evidence archive](remote-archive-no-ppm.tgz)；归档SHA-256 `be1ee286547cad28779ca70aa849b21f0658fd9a3cd0568e87af2b56bf675ff8`。

原始PPM留在T490，六张同内容帧SHA-256见 [ppm-sha256.txt](ppm-sha256.txt)；可查看 [45秒启动帧](screenshots/shot-01-at0045s.png)。该图为无显示输出的黑帧，不是浏览器画面。

\n