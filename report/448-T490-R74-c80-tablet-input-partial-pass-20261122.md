# T490 R74 c80 绝对 tablet 输入复核（2026-11-22）

## 结论

R74 达到了严格 interaction 首帧，并验证了绝对 tablet 点击时序修复的一部分：真实点击计数从 0 变为 1，说明在绝对轴事件后等待 1 秒可以把按钮 click 送到 Chromium。整轮仍未达到 Input 4/4，原因是键盘回显和 CSS 页面结论帧尚未满足门禁。

- 候选内核：`a70ecb4a34910f56c31d677f1b27d3a25088b94dc2fc82ba13b33544f34e3c1f`
- 平台：2 GiB、AArch64 QEMU 纯 TCG、Weston 原生 Wayland、Chromium 149 默认多进程
- 输入设备：virtio keyboard、virtio mouse、virtio tablet
- 严格页面：ready gate 4/4，`ready_rc=0`
- 运行目录：`/home/mo/xk6/evidence/2026-11-22_t490-r74-c80-tablet-input03`
- 本地证据：`evidence/2026-11-22_t490-r74-c80-tablet-input03/`

## 已通过的判据

- JS 页面自检截图判据通过。
- 真实绝对 pointer 动作被记录：4 个 QMP 点击、4 个绝对移动。
- 计数按钮局部差分通过：第一次点击后没有变化，第二次点击后 `mouse_counter_diff=true`。
- CSS 链接确实导航到了 CSS 页面；独立运行 `ppm_assert.py --profile official-layout` 对顶部截图得到 5/5 核心几何通过。
- Browser、Weston、renderer 和 QMP 正常结束，`round_rc=0`、`qmp_quit_rc=0`。

## 仍未通过的判据

- `keyboard_echo_diff=false`。自检按钮没有可靠地激活键盘焦点，输入框仍显示占位符，键盘采样未出现局部回显。
- 原有单帧 layout gate 要求 6/6 绿色结论条，但 1280×800 截图只能显示 CSS 页顶部。R74 的 CSS 页面顶部几何已通过，底部结论没有在同一帧入镜，所以门禁保守拒绝。
- `input-gate.pass=0`，本轮不更新 Input 4/4。

## 下一轮修复

已在未提交代码中加入并将在下一轮验证：

1. readiness 通过后增加可配置的页面稳定等待；
2. 绝对 tablet 直接点击自检按钮两次，减少 Tab/Enter 焦点不确定性；
3. CSS 导航后保存顶部几何帧和滚动到底部的 6/6 结论帧，门禁分别验证两帧；
4. 保留真实 QMP 键盘输入和绝对 pointer 事件账本。

R74 作为正向局部证据保留：绝对 pointer 已能改变页面计数，不能把剩余键盘和 viewport 证据缺口误写成内核输入链路失败。

