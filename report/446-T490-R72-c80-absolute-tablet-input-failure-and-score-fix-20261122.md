# T490 R72 c80 绝对 tablet 输入复核（2026-11-22）

## 结论

R72 在统一 2 GiB、AArch64 QEMU 纯 TCG、Chromium 149 默认多进程条件下完成了完整输入动作，但输入评分门禁未通过，不能计入 Input 4/4。失败证据已归档，未将它解释为浏览器崩溃或内核退出。

- 候选内核：`a70ecb4a34910f56c31d677f1b27d3a25088b94dc2fc82ba13b33544f34e3c1f`
- 候选源码基线：`b73e5814087c9d33c5f0a35b66cc56be689d3dee`
- 配置：2 GiB、纯 TCG、Weston 原生 Wayland、Browser → Zygote → Renderer、`--js-flags=--jitless`
- 输入设备：virtio keyboard、virtio mouse、virtio tablet；QMP 查询确认 tablet 为当前绝对设备
- 运行目录：`/home/mo/xk6/evidence/2026-11-22_t490-r72-c80-tablet-input01`
- 本地证据：`evidence/2026-11-22_t490-r72-c80-tablet-input01/`

## 已通过的部分

1. 页面首次严格判据通过（`ready_rc=0`）。
2. QMP 绝对 pointer 事件实际发出；事件账本包含 6 个绝对移动和 6 个 QMP 点击。
3. 键盘真实输入回显通过；重算门禁的 `keyboard_echo_diff=true`。
4. JavaScript 自检在重算门禁中通过；页面画面包含 6/6 结论条。
5. Browser、Weston 和 renderer 在本轮保持运行，QMP 以 host-initiated quit 正常结束。
6. 2 GiB 平台检查和构建哈希检查通过。

## 失败定位

首次门禁因为 staged 目录下的评分器把仓库根误算为 `/home/mo/xk6/tmp`，错误寻找 `/home/mo/xk6/tmp/scripts/t490/ppm_assert.py`。修正评分器使其优先使用同目录的 `ppm_assert.py` 后重算，环境路径问题已排除。

修正后的真实判据仍为：

- `mouse_counter_diff=false`：按钮截图前后计数仍为 0，局部 ROI 没有变化。
- `mouse_navigation=false`：导航截图仍是 interaction 页，CSS layout 严格判据未通过。
- `real_input_actions=true`：绝对 QMP 事件已被单独计数，不能再因“没有 HMP 事件”而误报。
- 因此 `interaction-score-gate.pass=false`，且总 `input-gate.pass=0`。

画面显示绝对指针已落在“真实点击 +1”按钮上，但按钮没有收到有效 click。下一轮在绝对轴事件与按钮事件之间加入 0.50 秒 guest/compositor settle，并保留同一证据和评分路径。该改动只影响输入时序，未改变页面、内核或测量口径。

## 证据索引

- 原始 PPM 仍保留在 T490；本地提交的是 PNG 预览、原始文件 SHA-256 清单、事件账本、命令、环境和门禁 JSON。
- `input-gate.json` 是运行时结果，`interaction-score-gate-rerun.json` 是补齐评分器路径及绝对 pointer 统计后的重算结果。
- `archive-source.txt` 记录了候选内核、平台参数和失败分类。

R72 是失败样本，保留用于回归验证；修正后的绝对 tablet 输入轮次必须重新获得 counter 变化和 CSS 导航严格通过，才可把 Input 计分从 0/4 更新为 4/4。

