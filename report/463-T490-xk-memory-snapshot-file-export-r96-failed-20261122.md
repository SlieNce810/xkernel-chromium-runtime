# T490 R96 快照文件导出尝试（2026-11-22）

R96 将 R95 的快速取样块写入 guest `/root/xk-memory-snapshot-samples.log`，串口只保留 marker，目标是避开连续大块 console 输出的丢失。取样节奏本身保持约 0.8 秒中位 begin 间隔；但 QEMU 停止后用 debugfs 从 `disk.img` 回收该文件时返回：

```text
/root/xk-memory-snapshot-samples.log: File not found by ext2_lookup
```

这说明本轮运行时 `/root` 路径不在可回收的持久 ext2 文件系统中，文件缓冲不能作为证据传输路径。R96 保留 console marker、命令、环境、截图判据、debugfs 失败结果和哈希材料；没有把缺失的快照块伪装成有效样本。

## 判定

R96 不计入性能样本，也不改变性能 0/0。R95 已证明快速读取可以接近 1 Hz，R96 证明需要在平台上确认一个真正可回收的 guest 持久路径，或者继续使用带长度/SHA/序号校验的串口导出协议。下一轮不能只写 `/root` 后假定 debugfs 能回收。
