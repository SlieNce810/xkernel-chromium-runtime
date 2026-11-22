# T490 R78 c80 绝对 tablet 输入正式通过（2026-11-22）

## 结论

R78 在统一 2 GiB、AArch64 QEMU 纯 TCG、Chromium 149 默认多进程和真实 virtio 输入链路下正式通过输入总门禁。它是当前可计入 Input 4/4 的正式证据轮次。

- 候选内核：`a70ecb4a34910f56c31d677f1b27d3a25088b94dc2fc82ba13b33544f34e3c1f`
- 平台：Weston 原生 Wayland、Browser → Zygote → Renderer、virtio keyboard/mouse/tablet
- 运行目录：`/home/mo/xk6/evidence/2026-11-22_t490-r78-c80-tablet-input07`
- 本地证据：`evidence/2026-11-22_t490-r78-c80-tablet-input07/`

## 总门禁

`input-gate.json`：

- `ready_rc=0`
- `before_rc=0`
- `input_rc=0`
- `ppm_assert_rc=0`
- `pixel_policy_rc=0`
- `input_changed_pixels=1`
- `round_rc=0`
- `qmp_quit_rc=0`
- `interaction_score_gate_rc=0`
- `pass=1`

## interaction-score 子门禁

- JavaScript 自检：PASS。
- 键盘回显：PASS，局部差分证明真实 QMP 键盘输入到达页面。
- 计数按钮：PASS，绝对 tablet 点击后计数局部变化。
- CSS 导航：PASS；顶部几何帧通过，底部帧的 6/6 绿色结论通过。
- 真实动作账本：30 个键盘动作、5 个 QMP 点击、5 个绝对移动，PASS。
- QMP 查询确认 virtio tablet 是当前绝对鼠标设备。

## 证据修复

R76 已证明所有 interaction 子门禁通过，但由于 staged helper 路径缺失总门禁仍为 0。R78 在 staged source 提供 `verify_pixel_policy.py` 后重跑，pixel policy 两张 PPM 均返回 PASS，消除了该环境假失败。R78 的 PASS 才正式计入 Input 4/4。

