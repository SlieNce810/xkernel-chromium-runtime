# T490 Chromium trace 试采 R9：首页严格判据超时（2026-11-20）

## 结论

R9 在带 `--trace-startup-format=json` 与 navigation 类别的2 GiB AArch64纯TCG会话中，700秒内没有通过首页严格判据。截图预览为空白；最后看门狗记录显示 Weston 与 Chrome仍存活、guest可用内存491,992 KiB，未见OOM文本。由于Chrome trace没有生成完成日志，串口没有BEGIN/DATA/END，本轮不产生trace或性能样本。

归一化的197个稳定性事件没有解析错误，但driver返回 `initial strict page gate timed out`；重载和保持阶段未开始。本轮仅为diagnostic-only启动失败，不能作为正式稳定性结论。

## 文件与复核

- `remote/console.log` 保留完整 Browser 参数、进程观察、页面轮询和 watchdog 输出；`remote/ppm-assert-shot-01-at0240s.json` 与 `screenshots/shot-01-at0240s.png` 记录空白预加载帧。
- `remote/stability/` 包含 QMP 轨迹和归一化事件；事件归一化197/197 PASS。
- 非PPM归档 SHA-256：`20d0f4e20f8ed6e5f0c1c88cf094ec8ce47858485fd100b4bd5720ca399a1f83`，34项、不含PPM。2张原始PPM保留在T490并见 `ppm-sha256.txt`。
- 首次严格判据超时之前没有QMP重载、保持窗口、trace导出或性能采样。

详见 [报告372](../../report/372-T490-R9 trace-only首页严格判据超时-20261120.md)。
