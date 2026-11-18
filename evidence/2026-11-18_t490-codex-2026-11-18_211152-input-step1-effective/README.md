# R14 step1 相对指针试验

R14 使用 2 GiB / AArch64 纯 TCG / `EVDEV_PROBE=0`；QMP ledger 已确认真实的 `pointer_mode=step1`。ready 第 46 次采样通过，JS self-test 和键盘回显 gate 通过，鼠标计数和 CSS 导航未通过。

- step1 请求按钮 `(281,674)` 后，查看图上的鼠标光标落在左上方，计数仍为 0。
- 总计发送 2,021 个 HMP 相对移动；导航等待结束时的截图出现 Chromium Page Unresponsive 对话框。因未启用 evdev observer，本轮没有输入 event 记录。
- 所有 65 张原始 PPM 留在 T490；仓库只保存 PNG 查看副本、判据和 `_ppm-sha256-2026-11-18_t490-codex-2026-11-18_211152-input-step1-effective.txt` 哈希清单。

详细结论见 [report 317](../../report/317-T490-2GiB输入尝试r14真实step1落点不足并出现页面无响应-20261118.md)。
