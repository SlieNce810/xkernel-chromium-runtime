# T490 Chromium trace 试采 R8：gzip自检有效，末尾fold块未发送（2026-11-20）

## 结论

R8通过guest源文件连续稳定检查，并将gzip输出写入独立临时文件后通过 `gzip -t`。原始JSON声明6,392,473字节、SHA-256 `66312d664dd12f4dc00a477dbc5b68600ca5ab6d1089ba0a1160b140a6c347b2`；压缩文件声明661,983字节、SHA-256 `ee21ff6738faa7f6b595b248feddb6cfb5374a8d42abb0eeb2b290bb303f5a47`。

传输端以256字符 `fold` 行发送，BEGIN/END均出现，序号按已发记录连续。但base64压缩流重组后只有661,824字节，比压缩头少159字节，gzip未通过。原始console逐行检查显示每个已发DATA块均为256字符；独立的折行自检确认最后一条212字符记录不带LF，`wc -l`少计一条，POSIX `read`在EOF跳过非空缓冲区。这不是源文件或gzip自检失败，而是串口折行的最后一块漏发。

## 页面与稳定性诊断

首页strict PASS于558,947.018 ms，QMP重载1/1通过，driver保持650秒，事件归一化432/432 PASS。周期截图间隔1,200秒，只有240秒的页面通过前帧，post-pass失败0；本轮仍为diagnostic-only，gate RC78。

## 修正与复核

R9将块数改为awk逻辑记录数，并用 `while read ... || [ -n "$chunk" ]` 处理EOF非空缓冲区。T490 dry-run新增600字符、256宽折成3块的发送自检；抽取器测试覆盖块长、压缩长度/哈希和完整大块JSON。R8本身按失败样本保留，不补写末块、不重新标为通过。完整材料在 [R8 evidence](../evidence/2026-11-20_t490-candidate-perf-trace-r8/)。
