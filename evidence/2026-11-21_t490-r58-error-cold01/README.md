# R58：no-direct-PTE ERROR 候选冷启动复测

R58 使用 no-direct-PTE、`LOG_LEVEL_ERROR` 候选内核，在 2 GiB AArch64 纯 TCG 平台运行 Chromium 149.0.7827.53。启动入口显式指定 `KERNEL_DIR=/home/mo/xk6/worktrees/r53-no-direct-error-log`，并设置预期 SHA-256；干跑及实际 QEMU 命令均核对为 `c78ecd57fb47b8269ebecf0a4e99ee5d9f85648e01703726eee7af88ad017a67`。

官方 index 页周期截图 `shot-01-at0240s.ppm` 是启动期白屏；下一张 `shot-02-at0540s.ppm` 通过严格判据 7/7。稳定性驱动对初始画面及一次真实 Ctrl+R 重载后的画面均判为严格通过，并完成 420 秒诊断保持。稳定性事件归一化 242/242 通过，无修复或解析错误。诊断运行返回 driver=0、round=0；formal gate 因 `diagnostic_only=1` 按设计跳过（rc=78）。

本轮是有效的冷启动及短稳定性诊断样本，但不等同于 30 分钟正式稳定性验收，也没有开启内存或生命周期采样，不产生性能数据。首屏判据的 540 秒是定时截图观测点，不是启动时间或页面首帧延迟测量值。

原始 PPM 保留在 T490 的 `/home/mo/xk6/evidence/2026-11-21_t490-r58-error-cold01`。逐图 SHA-256 索引在 [R58 PPM 清单](../_ppm-sha256-r58-error-cold01.txt) 和本目录的 `ppm-sha256-all.txt`；仓库保存 PNG 预览。

启动前的精确参数干跑保存在 `preflight-dry-run.txt`（`qemu_started=0`）；将冻结内核哈希故意传给候选路径的负向校验保存在 `kernel-mismatch-rejection.txt`，结果为预期退出码 2。

![R58 初始页面严格通过截图](screenshots/shot-02-at0540s.png)

![R58 真实重载后严格通过截图](stability/load-01-reload.png)

详细分析见 [R58 冷启动报告](../../report/430-T490-R58候选内核cold-start复测-20261121.md)。
