# 关于 round-0N.log 为 0 字节的说明

本目录的 round-01.log .. round-05.log 是测量驱动按轮 tee 的占位文件，内容为 0 字节：
轮次脚本自身的进度输出走 QEMU 会话串口（各轮 console.log），未经过该 tee。

每轮的完整证据在配对目录中：

- 2026-10-02_t490-single-perf3-01-152259 .. -05-154454（每轮 27 个文件，含 console.log 与 guest/ 日志）
- 原始汇总数据在本目录 raw.csv / summary.json / host.txt。

（2026-10-13 补注：保留空文件而非删除，避免破坏既有归档目录结构；新测量轮次
2026-10-13_measure-* 的 round-0N.log 同样可能为 0 字节，原因同上。）
