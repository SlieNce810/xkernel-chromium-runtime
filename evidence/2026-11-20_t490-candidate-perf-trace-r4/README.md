# T490 Chromium startup trace 试采 R4（2026-11-20）

## 结论

R4 完成了首页严格判据、一次真实 QMP 重载和 550 秒诊断保持。串口传输数据完整：24,484 个序号块全部到齐，gzip、长度和 SHA-256 校验通过，并恢复出 7,086,692 字节的 Chromium startup trace。

trace 字节不是 JSON。R4 没有设置 `--trace-startup-format`；文件头及 Chromium 源码说明该开关默认输出 Perfetto protobuf。JSON 模式在 UTF-8 检查时于第 11 字节被拒绝，原始 protobuf 则通过完整性校验保存为 [mp-perf-trace.pb](remote/mp-perf-trace.pb)。当前未解析出 `traceEvents` JSON，因此四项性能指标仍为 0 个有效样本。

## 会话结果

| 项目 | 结果 |
|---|---|
| 平台 | T490 `10.249.11.192`；AArch64；2 GiB；纯 TCG；Chromium 149.0.7827.53 |
| 页面与重载 | 首页 strict PASS 于 559,502.879 ms；QMP 重载 1/1 PASS |
| 保持与事件 | driver PASS；保持 550 秒；事件归一化 390/390 PASS |
| 周期截图 | 首张 240 秒截图 1/1；该帧在页面通过前严格失败，post-pass 失败 0。周期截图间隔 1,200 秒，因此没有页面通过后的周期帧；不能作为正式稳定性通过 |
| 门禁 | diagnostic-only，gate RC 78；不计正式稳定性或性能样本 |
| trace | 24,484 块，序号 0–24,483；gzip PASS；7,086,692 字节；SHA-256 `f0f0a9789a0f28bb5fa7d3bffec407831fa749f5ed26412b8e3e74849bff51b6` |
| JSON 与性能 | JSON 校验拒绝 protobuf 字节；未形成四项指标样本，before/after 仍为 0/0 |

## 格式与后续

Chromium trace 参数源码说明输出格式支持 `json` 和 `proto`，默认是 `proto`：[Chromium tracing switch definitions](https://chromium.googlesource.com/chromium/src/+/a0e9c1e80c1bd2ab242a969fd460af4a07cae15e/components/tracing/common/tracing_switches.cc)。R4因此证明串口 exporter 和 raw extractor 工作正常，同时定位了 R5 所需修正：在专用探针中显式传入 `--trace-startup-format=json`，同步更新 `t490_round.sh` 固定参数 guard，再验证 traceEvents JSON。

完整日志、事件、QMP transcript、preflight 正反例和 raw protobuf 在 `remote/` 与 `remote-archive-no-ppm.tgz`。归档 SHA-256 为 `c17e5dcf8e913536cff8bb5d74af4d53c02523c7a798d1abfce1be737d6ccb13`，共 39 项且不含 PPM；3 张原始 PPM 留在 T490，SHA 清单见 `ppm-sha256.txt`。仓库包含三张 PNG 预览。

详见 [报告 366](../../report/366-T490性能trace试采r4完整捕获默认Proto但JSON解析未启用-20261120.md)。
