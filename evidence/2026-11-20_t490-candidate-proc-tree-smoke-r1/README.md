# T490 proc_tree_sampler guest smoke R1（2026-11-20）

## 结果

R1在T490 AArch64 2 GiB纯TCG guest中注入静态 `proc_tree_sampler`，使用 `/proc/<pid>/stat` 闭包寻找root进程，并尝试每秒读取process tree的 `smaps_rollup`。guest执行器返回失败：`PROC_TREE_SAMPLER_RESULT ... samples=0 processes=0`，随后的 `PROC_TREE_SMOKE_FAIL` 终止该探针。该轮没有有效guest内存样本，不能填充Chromium性能数据。

同一源文件在T490 native Linux先完成4秒父子进程烟测：4个样本、2个进程、RSS/PSS/USS均为正数；AArch64静态目标也编译成功。这些只证明主机侧程序构造及目标编译，不能代替x-kernel guest验证。

## 运行身份与界面

T490 `10.249.11.192`，Ubuntu 26.04.1 / Linux 7.0.0-43 / QEMU 10.2.1；AArch64 2 GiB pure TCG、4 vCPU、kernel SHA `ac1032fe98c382cc37646a12453b7141b789c9abfe1651ff5f8f1e0263767fa2`。该probe没有启动Chromium。QEMU在45秒截屏为640×480黑屏，截图中显示display output未激活；它不是浏览器页面证据。

## 证据

- 完整命令、console、环境、平台合规、PPM判据和哈希见 [remote-archive-no-ppm.tgz](remote-archive-no-ppm.tgz)，SHA-256 `fb6ef2796d14d210e0e41220b28ae88a721665c8fcb3694b35bf7f0eb17f43da`。
- 宿主注入/构建过程见 [host-round.log](host-round.log)。
- 原始PPM留在T490，十张同内容截图的SHA-256见 [ppm-sha256.txt](ppm-sha256.txt)；可查看其中一张 [shot-01-at0045s.png](screenshots/shot-01-at0045s.png)。
- 该轮只作为工具诊断失败记录；R2会加入guest进程stat原文和扫描计数，以定位root进程未被发现的原因。

\n