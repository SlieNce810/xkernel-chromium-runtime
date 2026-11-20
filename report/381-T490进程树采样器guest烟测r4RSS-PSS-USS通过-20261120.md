# T490进程树采样器 guest smoke R4：RSS/PSS/USS均为有效数值（2026-11-20）

## 结果

R4在2 GiB AArch64纯TCG guest上通过sampler smoke：AArch64静态程序以 `-Wall -Wextra -Werror` 编译成功；root PID5与helper PID11组成的两个进程每秒采样8次，得到16行RSS/PSS/USS数据，缺失字段、无效零值和采样遗漏均为0。

采样器现在优先解析x-kernel提供的自定义 `USS:`，在Linux回退到 `Private_Clean + Private_Dirty + Private_Hugetlb`。guest原始`smaps_rollup`与CSV数值吻合：root第一批样本RSS/PSS/USS=560/346/132 kB，helper=160/160/160 kB；root烟测末尾rollup为560/310/132 kB。R3的USS为零假阳性因此已定位并修复。

R4是shell父子进程探针，不包含Chromium，不计入性能样本。下一步需要把采样器挂到Chromium启动路径，验证真实Browser→Zygote→Renderer树，并与页面strict通过后60秒窗口及生命周期trace整合。

更新后的Linux标准字段回退解析也在T490 native Linux host烟测通过，4个采样点共8行，RSS/PSS/USS均为正数；输出摘要见 [native-linux-smoke.txt](../evidence/2026-11-20_t490-candidate-proc-tree-smoke-r4/native-linux-smoke.txt)。

## 证据

- 原始guest console、命令、环境、平台检查、PPM判据与文件清单：[R4 archive](../evidence/2026-11-20_t490-candidate-proc-tree-smoke-r4/remote-archive-no-ppm.tgz)。
- host编译和注入过程：[host-round.log](../evidence/2026-11-20_t490-candidate-proc-tree-smoke-r4/host-round.log)。
- 45秒空画面截图：[shot-01-at0045s.png](../evidence/2026-11-20_t490-candidate-proc-tree-smoke-r4/screenshots/shot-01-at0045s.png)。原始PPM仍保留在T490，SHA见[ppm-sha256.txt](../evidence/2026-11-20_t490-candidate-proc-tree-smoke-r4/ppm-sha256.txt)。

\n