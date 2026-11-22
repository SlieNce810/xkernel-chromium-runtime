# T490 Chromium trace 试采 R8：末尾fold记录漏发（2026-11-20）

## 结论

R8已通过源文件大小/SHA稳定检查和独立gzip `-t`。trace头声明原始JSON 6,392,473字节，SHA-256 `66312d664dd12f4dc00a477dbc5b68600ca5ab6d1089ba0a1160b140a6c347b2`；临时gzip自检也通过。串口BEGIN/END和已发送块序看起来完整，但抽取器以gzip压缩字节数不符拒绝：头部声明661,983压缩字节，重组数据只有661,824，少159字节。

原因是256字符折行后，最后一行212字符没有结尾换行。BusyBox `wc -l` 只计3447个LF，而文件实际有3448条逻辑记录；`while read` 在EOF时返回非零，未处理最后仍非空的记录。因此末尾212个base64字符没有输出。R9改用awk逻辑记录数，并让读取循环处理未换行的最后一行；guard自检会用600字符输入确认折成三块且三块都能发出。

## 稳定性诊断

首页严格通过于558,947.018 ms；QMP重载1/1，保持650秒，事件归一化432/432通过。周期截图仅有页面通过前240秒的一帧（严格失败1、post-pass失败0），因此本轮不构成正式稳定性通过。R8为diagnostic-only，性能指标仍为0。

完整console、BEGIN/END、guard preflight、稳定性事件和图片在 `remote/` 与 `screenshots/`。非PPM归档SHA-256为 `e786ccc5e6504d80eaf3988ab4c1c0fa416fd4b6802caa71bb22a6f6c3b46b9e`，共35项、不含PPM；3张原始PPM保留在T490并见 `ppm-sha256.txt`。

详见 [报告371](../../report/371-T490性能trace试采r8gzip自检有效但fold末块EOF未发-20261120.md)。
