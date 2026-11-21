# T490 R76 c80 绝对 tablet 输入全子门禁通过（2026-11-22）

## 结果

R76 是目前最完整的一轮输入证据：严格首帧、JS、自检后的键盘回显、绝对 tablet 计数点击、CSS 导航顶部几何、底部 6/6 结论和真实输入事件账本全部通过。运行总门禁仍显示 `pass=0`，唯一原因是 staged source 没有带上 `verify_pixel_policy.py`，导致像素策略脚本路径错误；这不是页面或输入链路失败。

- 候选内核：`a70ecb4a34910f56c31d677f1b27d3a25088b94dc2fc82ba13b33544f34e3c1f`
- 平台：2 GiB、AArch64 QEMU 纯 TCG、Weston 原生 Wayland、Chromium 149 默认多进程
- 输入设备：virtio keyboard、virtio mouse、virtio tablet
- 运行目录：`/home/mo/xk6/evidence/2026-11-22_t490-r76-c80-tablet-input05`
- 本地证据：`evidence/2026-11-22_t490-r76-c80-tablet-input05/`

## 子门禁

| 项目 | 结果 |
|---|---|
| readiness strict | 4/4，`ready_rc=0` |
| JavaScript 自检 | PASS |
| keyboard echo diff | PASS |
| mouse counter diff | PASS |
| CSS navigation | PASS；顶部几何 PASS，底部 6/6 PASS |
| real input actions | PASS；30 个键盘动作、5 个 QMP 点击、5 个绝对移动 |
| interaction-score-gate | PASS |
| QMP/round | `qmp_quit_rc=0`、`round_rc=0` |
| input-gate | 0，仅因 pixel policy helper 缺失 |

R76 的 `interaction-score-gate.json` 中 `pass=true`，并且底部截图的 `layout_verdict_pass` 为绿色结论 1637 像素/绿底 32058 像素。真实 QMP 账本记录了 tablet 为当前绝对设备。

## 唯一阻断与修复

`run_input_final.sh` 原来固定调用 staged 目录上一级的 `verify_pixel_policy.py`。当前 T490 source staging 只复制了 `t490/` 子目录，因此路径：

`/home/mo/xk6/tmp/r71-input-source-2026-11-22/t490/../verify_pixel_policy.py`

不存在；两次调用均返回找不到文件，`pixel_policy_rc=2)，继而总 `input-gate.pass=0`。已修复 runner：优先使用仓库路径，缺失时回退到同目录，并将 `pixel-policy.log` 一并归档。下一轮把 helper 复制到 staged source 后，预期不再有该假失败。

R76 的输入功能本身不应记为失败；在修复 helper 路径后需重新运行整轮，取得可正式计入的 Input 4/4。

