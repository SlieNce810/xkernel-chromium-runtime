# T490 Chromium navigation trace 试采 R7（2026-11-20）

## 结论

R7将串口base64数据块扩展到256字符，并将诊断保持延长到650秒。首页strict判据于559,092.472 ms通过；QMP重载1/1、650秒保持和事件归一化422/422均通过。串口导出输出7,303个连续序号块（0–7,302）及END标记，且传输期间没有周期截图状态行；抽取仍失败：gzip解压到17,451,213字节后流结束，离BEGIN声明的17,451,240字节少27字节，gzip尾部校验缺失。因此未产生JSON样本。

## 解释与后续

块数、块序和END完整，gzip payload仍短27字节。当前证据更符合guest trace源文件或gzip临时产物尚未稳定完成的情况；单凭本轮无法区分写入竞态与后续压缩阶段错误。R8会等待trace原文件连续稳定后，先把gzip结果写到独立临时文件并运行 `gzip -t`；只有原始长度、SHA及gzip自检均通过才发送串口块。

## 本轮限制

周期截图间隔1,200秒，仅240秒一张页面strict失败的预加载帧，post-pass失败0；trace诊断保持不能替代正式30分钟稳定性验收。R7为diagnostic-only，gate RC78，指标仍为0个有效样本。

完整console、事件、QMP transcript、preflight及抽取失败记录位于 `remote/`。原始PPM共3张，保留在T490并见 `ppm-sha256.txt`；仓库保存PNG预览。非PPM归档SHA-256为 `ae347ca45304ac0897f1e22932c5123a7e452f432ffa82e83e5f01360a24ddd4`，共35项。

详见 [报告370](../../report/370-T490性能trace试采r7序号齐全但gzip尾部缺失-20261120.md)。
