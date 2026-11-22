# R12 相对指针坐标校正复测

R12 在 2 GiB / 默认多进程 / `EVDEV_PROBE=0` 下，于第 47 次 readiness 采样通过。动态键盘 echo gate 与 JS 自检通过，鼠标计数和 CSS 导航仍未通过。

- 本轮用 R11 估出的坐标 `(247,607)` 点击计数按钮、`(292,638)` 点击 CSS 链接；截图中的指针仍在页面下缘，按钮计数为 0，导航没有离开 interaction 页。
- as-run gate 与事后按 counter-only ROI 重算的 gate 都保留；计数和导航最终判 FAIL。
- 所有 64 张原始 PPM 留在 T490。仓库仅提交 PNG 查看副本和 `_ppm-sha256-2026-11-18_t490-codex-2026-11-18_202815-input-corrected-pointer.txt` 哈希清单。

详细分析见 [report 315](../../report/315-T490-2GiB输入尝试r12修正坐标后鼠标点击仍未生效-20261118.md)。
