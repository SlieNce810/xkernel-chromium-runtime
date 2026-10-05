# 三页键鼠与 JavaScript/CSS 交互验收报告

本阶段在 `codex/initial-round-single-process` 分支完成，验证范围固定为单进程
Chromium、Wayland/Weston、官方三页测试集。页面默认评委手动模式保持不变；
新增的 `?e2e=1` 只用于可重复的浏览器级联动验收。

## 采用的成熟接口与边界

输入注入先使用 QEMU 官方 QMP/HMP 接口：`query-mice`、`send-key`、
`input-send-event`、`mouse_set` 和 `hostfwd_add`。QEMU 的 QMP 文档明确规定了
键盘、相对/绝对指针事件以及 display device 路由：

- [QEMU QMP Reference: input-send-event](https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html#command-input-send-event)
- [QEMU Monitor: sendkey/mouse_move/mouse_button](https://www.qemu.org/docs/master/system/monitor)
- [QEMU QMP Reference: query-mice/send-key](https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html)

QEMU 轮次中 `query-mice` 能看到 `QEMU Virtio Mouse` 和额外的
`QEMU Virtio Tablet`，每条 QMP 命令都返回成功；但 `p15_evdev_event_trace.py`
在 x-kernel 的 `EventDev::has_event → InputDevice::read_event` 处没有记录任何
事件。也就是说，当前内核的 virtio-input 事件消费链仍未打通，本阶段没有把
QMP 返回成功误写成“硬件键鼠通过”，也没有修改 Wayland 包或凭空添加内核语义。

为完成应用层页面验收，复用 Chromium 官方 DevTools Protocol 的 Input/Runtime
接口作为显式浏览器级 fallback。该协议由 Chromium DevTools 团队维护：

- [CDP Input.dispatchKeyEvent / dispatchMouseEvent](https://chromedevtools.github.io/devtools-protocol/tot/Input/)
- [CDP Runtime.evaluate](https://chromedevtools.github.io/devtools-protocol/tot/Runtime/)
- [CDP protocol overview](https://chromedevtools.github.io/devtools-protocol/)

当前分支保留了两条证据：QMP/evdev 未消费的硬件链路诊断，以及页面标准 DOM
事件联动通过的应用层结果。后续若补齐 x-kernel virtio-input 消费，只需将
`INPUT_DRIVER=qmp` 重新运行，页面代码和验收判据不需要再造一套。

## 页面实现

- `index.html` 保持默认静态像素基线；表单控件增加原生 `input`、`change` 和
  `click` listener，点击后通过按钮值/title 反映当前选择，默认首屏外观不变。
- `interaction.html` 保留评委手动的“运行自检”、文本回显、点击计数和布局跳转。
  只有 URL 为 `?e2e=1` 时，才由同一页面函数执行标准 `KeyboardEvent`、
  `MouseEvent`、`input` 事件、T1–T6/F1 检查，并跳转到 `layout.html?e2e=1`。
- `layout.html` 的 C1–C6 `load` 测量保持原逻辑；`?e2e=1` 只在检查结束后
  滚动到结论卡，便于截图捕获绿色 `6/6`，不改变默认评委视图。

## 通过证据

### interaction 页面

最终页面轮为 [2026-10-02_t490-interaction-single-e2e-r20](../evidence/2026-10-02_t490-interaction-single-e2e-r20/)。

- [interaction-e2e.png](../evidence/2026-10-02_t490-interaction-single-e2e-r20/screenshots/interaction-e2e.png)
  显示 T1–T6、F1 全部绿色通过，核心结论为 `6/6`，文本框回显
  `hello x-kernel`，鼠标计数为 `1`。
- [interaction-assert.json](../evidence/2026-10-02_t490-interaction-single-e2e-r20/interaction-assert.json)
  的 core 组 3 项（banner、无失败色、无异常块）+ viewport 组 1 项（自检表）共 `4/4` 通过，
  `interaction_selfcheck_pass` 作为 input 组参考项通过；对外转述统一用
  `ppm-summary.txt` 严格集口径（口径说明见 [report/46](46-初赛单进程材料口径勘误.md) 勘误 2）。
- [qmp-events.jsonl](../evidence/2026-10-02_t490-interaction-single-e2e-r20/qmp-events.jsonl)
  保存 QMP 握手、`query-mice`、设备清单和 hostfwd setup 回执。

### layout 页面

layout 专项轮为 [2026-10-02_t490-layout-e2e-r21](../evidence/2026-10-02_t490-layout-e2e-r21/)。

- [layout-top.png](../evidence/2026-10-02_t490-layout-e2e-r21/screenshots/layout-top.png)
  的 `layout-top-assert.json` 显示官方严格几何集 `5/5`：banner、C1 flex、
  C2 grid、C3 盒模型和无失败色全部通过（严格集口径以 `ppm-summary.txt` 为准，
  C3 在 assert JSON 中归 viewport 组，见 [report/46](46-初赛单进程材料口径勘误.md) 勘误 2）。
- [layout-e2e.png](../evidence/2026-10-02_t490-interaction-single-e2e-r19/screenshots/layout-e2e.png)
  保存滚动后结论视图，C1–C6 运行时检查为绿色 `布局检查 6/6 全部通过`——**该 6/6
  证据来自 r19 轮**（interaction 页跳转 `layout.html?e2e=1` 后滚动截图）。
  ⚠️ r21 本轮未产生滚动后结论条证据：r21 的 `layout-verdict.png` 与 `layout-top.png`
  同哈希（滚动未发生）、`layout_verdict_pass=False`，其 `ppm-summary.txt` 自带
  「取景不够，必须用更高窗口/滚动后重截」警告（见 report/46 勘误 3）。
  **待办**：按 report/45 §4-C3 补一轮 e2e 滚动 layout 轮，把 6/6 结论条落入同一目录后，
  本引用才可改指新目录；补齐前 6/6 一律注明证据在 r19。

### index 页面

初赛静态 index 的 10 分钟严格像素和单进程基线仍以
[2026-10-02_t490-single-initial-r5](../evidence/2026-10-02_t490-single-initial-r5/)
为准，`official-index` 严格失败数为 0；本阶段只增加默认不改变外观的表单
listener，不重写初赛静态基线。

## 可复现命令

T490 上使用已验证的基础镜像和 overlay：

```sh
cd /home/mo/xk6
INPUT_DRIVER=page-e2e \
BASE_IMG=$HOME/x-kernel/images/agentos-weston.img \
PKG_TARBALL=$HOME/xk6/tmp/eudev-seatprobe-libinput-swiftshader-p31.tar.gz \
GL_VARIANT=angle-swiftshader GPU_MODEL=in-process \
bash scripts/t490/run_interaction_round.sh interaction-single-e2e-r20 240 30
```

layout 几何专项：

```sh
PAGE_URL=file:///usr/share/html-test/layout.html \
BASE_IMG=$HOME/x-kernel/images/agentos-weston.img \
PKG_TARBALL=$HOME/xk6/tmp/eudev-seatprobe-libinput-swiftshader-p31.tar.gz \
GL_VARIANT=angle-swiftshader GPU_MODEL=in-process \
ASSERT_PROFILE=official-layout FIRST_SHOT=120 \
bash scripts/t490/t490_round.sh layout-e2e-r21 300 30 autorun_single_initial.sh
```

最终 r20 使用的 kernel SHA-256 为
`7584653beb24572cb22380baf8aa7c0c55de85ae1bb0412f0f101e3fedaed02f`，基础镜像
SHA-256 为 `bb25e0b298d619a62df06b0ab044750c0885adc2d34602eb0c5875a022aaee09`；
完整命令、平台合规、页面哈希和时间戳见两轮 evidence 目录中的标准文件。

硬件键盘/鼠标通过仍是后续内核工作项：下一步应围绕 `drivers/devices/virtio/src/input.rs`
的 pending queue、`EventDev::poll/read` 和 QEMU virtio-input queue 建立 Linux 对照，
再提交最小内核修复；本报告不把浏览器级 e2e 结果扩大为该内核缺口已解决。
