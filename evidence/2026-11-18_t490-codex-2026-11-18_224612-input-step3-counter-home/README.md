# R17 step3 counter / Home 复核

R17 第 46 次采样通过；JS 与 Keyboard gate 通过。HMP step3 点击后计数仍为 0，CSS 页面已打开。driver 发送 Home 后截图仍处于 CSS 页下部，因此 official-layout strict 没通过。

- `interaction-score-gate.json` 使用 counter-only ROI，鼠标计数结果为 FAIL。
- QMP ledger 记录导航点击与 Home 动作。最终 CSS 页面截图显示仍在下方表格/结论区；下一轮用 3 次 PageUp 回顶。
- 62 张原始 PPM 留在 T490，哈希清单在仓库根；PNG 查看副本位于 `screenshots-review/`。

详细结果见 [report 320](../../report/320-T490-2GiB输入尝试r17step3计数仍为零CSS页打开home未回顶-20261118.md)。
