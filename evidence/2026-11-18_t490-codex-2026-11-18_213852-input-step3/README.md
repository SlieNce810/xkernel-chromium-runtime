# R15 step3 相对指针轮

R15 在第 46 次 readiness 采样通过；step3 相对移动和动态键盘回显运行，JS/Keyboard gate 通过。

- counter click 后，画面显示计数仍为 0，光标落在 CSS 链接附近；鼠标计数专用 ROI 因此判失败。
- CSS 导航实际打开了 layout 页面，但 driver 在 scrolled viewport 截图；strict layout gate 因 banner/C1/C2/C3 不可见而失败。下一轮会在导航后按 Home 回到顶部，再取严格截图。
- 本轮使用 679 次 HMP 相对移动，页面保持响应并完成导航；step1 的页面无响应现象没有重现。
- 点击落点与 gate 的细节见 `mouse-counter-analysis.txt`；导航后 PNG 确认已经进入 CSS 页面，strict gate 因滚动 viewport 未复核完整布局。
- 61 张原始 PPM 只保存在 T490；仓库只收 PNG 查看图和 `_ppm-sha256-2026-11-18_t490-codex-2026-11-18_213852-input-step3.txt` 清单。

详细结果见 [report 318](../../report/318-T490-2GiB输入尝试r15-step3指针移动导航已发生计数未变-20261118.md)。
