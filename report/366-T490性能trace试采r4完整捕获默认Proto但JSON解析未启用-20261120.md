# T490 Chromium startup trace 试采 R4：完整捕获默认 protobuf 输出（2026-11-20）

## 结论

R4 首次实现了完整、可验证的 Chromium startup trace 串口回收。导出器写出24,484个带序号数据块，序号为0到24,483；抽取器通过gzip解压、原始长度和SHA-256校验，恢复了7,086,692字节文件，SHA-256为 `f0f0a9789a0f28bb5fa7d3bffec407831fa749f5ed26412b8e3e74849bff51b6`。

JSON抽取仍失败，因为R4没有传入 `--trace-startup-format`，Chromium默认输出Perfetto protobuf。原始trace文件头 `0a50324a10030a09080610e088e1c6cd030a0c08021080ab88b3fae6e6f4180a` 与protobuf格式相符；JSON模式在UTF-8检查时于第11字节失败。Chromium tracing switch definitions说明该参数有效值为 `json` 或 `proto`，未设置时默认 `proto`。因此R4证明了传输完整，但尚未产出JSON事件，不计性能样本。[源码说明](https://chromium.googlesource.com/chromium/src/+/a0e9c1e80c1bd2ab242a969fd460af4a07cae15e/components/tracing/common/tracing_switches.cc)。

## 页面与稳定性诊断

R4首页严格判据在559,502.879 ms通过，QMP重载1/1通过，driver完成550秒保持；事件归一化390/390通过。trace模式关闭了额外syscall/strace诊断，周期截图间隔为1,200秒，首张截图在240秒，故本轮只产生一张周期图像且发生在页面首过帧之前。该周期帧严格失败1张，post-pass失败0张；不能据此判定正式稳定性通过。本轮仍是diagnostic-only，门禁RC78。

## 证据

- trace raw bytes：7,086,692；SHA-256：`f0f0a9789a0f28bb5fa7d3bffec407831fa749f5ed26412b8e3e74849bff51b6`
- 串口块：24,484；BEGIN/END齐全；序号0–24,483连续；gzip、长度、SHA PASS
- 原始文件： [R4 evidence 中的 mp-perf-trace.pb](../evidence/2026-11-20_t490-candidate-perf-trace-r4/remote/mp-perf-trace.pb)
- JSON 校验：拒绝 protobuf payload，UTF-8 错误偏移11；未输出 `traceEvents` JSON
- 稳定性诊断：首页strict PASS；重载1/1；保持550秒；事件归一化390/390；只产生首张240秒周期截图
- 归档：39项、无PPM，SHA-256 `c17e5dcf8e913536cff8bb5d74af4d53c02523c7a798d1abfce1be737d6ccb13`

3张原始PPM保留在T490，仓库保存SHA清单和PNG预览。R4的工具guard首轮曾在QEMU前拒绝trace-only组合；修复后正反guard preflight均归档在 `evidence/.../remote/preflight/`。

## 后续

R5在固定startup trace参数中增加 `--trace-startup-format=json`，并让 `t490_round.sh` guard精确允许该参数组。确认json有效后，继续关联导航、renderer和同钟域生命周期事件；四项指标及before/after样本仍保持0/0。
