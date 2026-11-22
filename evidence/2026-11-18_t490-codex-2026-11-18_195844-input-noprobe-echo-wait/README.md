# R11 无 observer 键鼠轮

本轮第 56 次 readiness 采样通过；动态键盘 echo 轮询在 10 秒采样就看到输入文字。`keyboard-echo-sample` 的命中结果与截图可查 `interaction-events.jsonl` 和 `screenshots-review/`。

计数点击后的截图仍显示 `当前：0`。R11 原始 gate 的 mouse ROI 太宽，把屏幕下方光标移动算成了计数变化；事后 recheck 保留在 `interaction-score-gate-corrected.json`。原始 as-run gate 仍保存在 `interaction-score-gate-run.json`。

QEMU 相对指针命令请求 `(281,674)` 时，截图光标约在 `(320,749)`，没有落到计数按钮。导航命令请求 `(350,710)` 也没点中 CSS 链接。下一轮候选校正值在 report 314 中列出，仍需复测。

所有 75 张原始 PPM 留在 T490；仓库内 `_ppm-sha256-2026-11-18_t490-codex-2026-11-18_195844-input-noprobe-echo-wait.txt` 保存哈希。仓库中的 PNG 是便于查看的截图副本。

详细结果见 [report 314](../../report/314-T490-2GiB输入尝试r11键盘回显通过鼠标计数ROI校正-20261118.md)。
