# T490 Chromium navigation trace 试采 R6（2026-11-20）

## 结论

R6 在固定 JSON 参数上增加 `navigation` trace 类别，用来确认 Chromium 的 `RenderProcessHostImpl::Init` 请求事件。trace 文件期望21,046,297字节、SHA-256 `9dcb6eee87354145b00f9093ef3e041b58530d347b5e37df3d2b4c5ff8fbdfbc`，需要29,444块。诊断保持窗口结束时只输出21,288块，没有 END；抽取器按预期拒绝缺失 END 的串口日志，因此本轮没有有效 trace 或性能样本。

## 页面和稳定性诊断

首页严格通过于559,372.968 ms；QMP重载1/1通过，driver完成550秒保持，事件归一化380/380通过。1200秒周期截图间隔仅产生240秒一张页面通过前的截图（严格失败1张、post-pass失败0），仍不能作为正式稳定性通过。本轮diagnostic-only，gate RC78。

## 后续

R6的类别修正需要保留，下一轮把串口base64行宽从76增至256字符，减少固定行前缀传输耗时；诊断保持增至650秒，guest观察上限增至1400秒，给21 MB事件文件足够收尾空间。序号、BEGIN/END块数和SHA校验保持开启。本轮JSON流因无END而不解析、不进入指标汇总。

完整console、稳定性事件、QMP transcript、trace头和抽取器拒绝结果在 [R6 evidence](./)。非PPM归档SHA-256为 `beef6ada3806491ace0626abd873aef1f9540d142ebd4329aaef7585842784ac`，共35项、不含PPM；3张原始PPM保留于T490并有SHA清单。
