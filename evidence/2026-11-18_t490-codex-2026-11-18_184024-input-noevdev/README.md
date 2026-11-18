# R9 交互页输入复测

本轮 R9 在 2 GiB / AArch64 纯 TCG / Chromium 149 默认多进程条件下，于第 45 次采样通过 `official-interaction` ready gate。运行复现命令、进程输出和 strict gate 结果见本目录 `cmd.txt`、`env.txt`、`input-runner.log`、`manifest.txt` 和 `interaction-score-gate.json`。

- `screenshots-review/` 保存键盘输入前后、滚动、计数点击和导航截图。30 秒键盘回显截图未变化；后续截图显示文本框与回显区均为 `hello x-kernel`。
- `EVDEV_PROBE=0`，console 显示 `EVDEV_SNIFF_SKIP=probe_not_injected`；本轮没有内核 evdev 事件观察。
- 计数点击后仍为 0；CSS 导航截图仍显示 interaction 页。本轮的导航点击点是 `(500,710)`，后续已基于截图修正为 `(350,710)`。
- 所有原始 PPM 留在 T490。本轮共有 63 张：正式 screendump、45 张 ready 采样、交互动作截图和输入前后图；仓库根 `_ppm-sha256-2026-11-18_t490-codex-2026-11-18_184024-input-noevdev.txt` 列出 SHA-256。
- `console.log` 含 QEMU 串口和 Chromium 日志；`screenshots-review` 内 PNG 是便于查看的副本，不替代原始 PPM。

详细结论见 [report 312](../../report/312-T490-2GiB输入尝试r9交互页ready通过键盘回显延迟鼠标未通-20261118.md)。
