# 干净 Linux 目录构建与功能复现报告

2026-10-13 在 T490 Ubuntu 26.04.1、Linux 7.0.0-38、QEMU 10.2.1 上使用新的 HOME、材料目录、内核 checkout、target 和工作盘复现。复用预装工具及 Cargo 下载缓存；这是同一 Linux 主机的干净目录验证，不声称重装操作系统或使用第二台主机。

## 输入与构建

材料脚本从 Windows 工作区的源码归档解包；内核从本地 Git 对象库创建干净 checkout，固定 2a1b101ccf97ed255821b85628f366700089cda3，未复制旧 target 或工作盘。执行：

```bash
cp platforms/kplat-aarch64/qemu_defconfig .config
make defconfig
make build GRAPHIC=y ACCEL=n MEM=2g SMP=4 VSOCK=n
```

构建约 2 分 51 秒、exit=0；配置 SHA-256 为 42e8d16450352712d78813b5f78b7ca221dfb88fadc796f57ecf317d7e33f669。新 kernel.bin 为 3a2e6441d75ea32c4e64389b507e098018884f54d4481cd9accebbb4d2111f62。逐字构建输出、配置与源码状态见 [构建证据](../evidence/2026-10-13_t490-clean-build-1340/build.log)。

从 T490 上保存的 Release 压缩资产重新解压基础镜像；压缩包哈希为 6ed1bff70cabaa7d215693c10d2fef72f5f23d834031e260c70e5bcfae68e561，解压后的 2 GiB 镜像为 bb25e0b298d619a62df06b0ab044750c0885adc2d34602eb0c5875a022aaee09，与历史功能输入一致。未复用历史可写 disk.img 或 Chromium profile。

## 功能实跑

使用仓库内 p31 overlay、official-index、FIRST_SHOT=180、SINGLE_HOLD_VALUE=600、STRICT_GATE=1，执行 900 s 会话。证据目录为 [clean-submission-repro-v2-1350](../evidence/2026-10-13_t490-clean-submission-repro-v2-1350/)：

- 平台断言 PASS=15、FAIL=0，AArch64/2 GiB/4 vCPU/cortex-a76/virtio 设备，纯 TCG。
- 原始 console 记录 SINGLE_HOLD_REACHED elapsed=615 与 SINGLE_GATE=1。
- 13 张原始 QEMU screendump；汇总 strict_fail=0、probe_fail=0。
- 首次发现导航日志的计数为 90 s，保留与历史 75 s 的差别，不把计数当精确页面加载时刻。
- 判据参考图先用仓库 PNG 解码器转 PPM，自检 25/25 对照符合预期；dry-run 的命令与平台检查也已归档。

此次证明干净源码、配置、镜像与工作盘可以实跑。最终 ZIP 的来源提交和完整文件清单由打包器生成；从 ZIP 的后续核验结果另记，不能以该次源码归档验证代替不同运行代码的验证。

## 实际发现与修正

最早的本次预检缺少 selftest 的 --refs，后续已显式生成参考 PPM；隔离 PATH 最初漏掉 /usr/sbin，补回后 debugfs/e2fsck 可用。新探针 payload 起初错误使用 Bash shebang，Guest Alpine 没有 Bash；改为 POSIX sh，失败轮保留，不列为执行通过。

运行编排已补在下一轮写盘前回收单进程/探针持久日志，并传递会话退出码。函数门禁、像素判据与实际 ABI 结果分别核对；不以脚本最后一条 echo 的成功代替运行结果。
