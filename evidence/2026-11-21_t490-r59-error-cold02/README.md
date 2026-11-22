# R59：no-direct-PTE ERROR 候选冷启动复测 02

R59 与 R58 使用完全相同的启动和诊断参数：no-direct-PTE、`LOG_LEVEL_ERROR` 候选内核，2 GiB AArch64 纯 TCG，Chromium 149.0.7827.53，2400 秒页面期限，一次真实 Ctrl+R 重载和 420 秒诊断保持。实际 QEMU `-kernel`、运行配置及候选 SHA-256 均一致：`c78ecd57fb47b8269ebecf0a4e99ee5d9f85648e01703726eee7af88ad017a67`。

guest 240 秒周期截图是启动期白屏；随后稳定性驱动捕获到严格页面，guest 540 秒周期截图通过官方 index 判据 7/7。初始和真实重载后的稳定性截图都通过严格判据，驱动报告 `pass=1 duration=420.0 reloads=1/1`。事件归一化 241/241 PASS，无修复或解析错误；driver 与 round 均返回 0。formal gate 因 diagnostic-only 按设计跳过（rc=78）。

本轮是有效冷启动及短保持诊断，不计为 30 分钟正式稳定性结果，也没有有效性能采样。540 秒仅是可见页面周期截图的观测点，不是精确页面首帧延迟。

原始 PPM 保留在 T490：`/home/mo/xk6/evidence/2026-11-21_t490-r59-error-cold02`。SHA-256 在 [R59 PPM 清单](../_ppm-sha256-r59-error-cold02.txt) 和本目录 `ppm-sha256-all.txt`。完整运行配置、内核来源及采集器判据均在本目录；启动前干跑输出保存在 `preflight-dry-run.txt`。

![R59 首屏通过](screenshots/shot-02-at0540s.png)

![R59 重载后通过](stability/load-01-reload.png)

详细结论见 [R59 冷启动报告](../../report/431-T490-R59候选内核cold-start复测-20261121.md)。
