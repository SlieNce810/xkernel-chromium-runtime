# 274 · Chromium 149 interaction 页 JITless A/B 恢复首帧（2026-11-16）

## A/B 结论

同一镜像、同一 guest 4 GiB、同一 Wayland + SwiftShader + in-process GPU、同一默认
Browser → Zygote → Renderer 路径下：

| 变量 | interaction readiness | 结果 |
|---|---:|---|
| 默认 V8 | 1400 秒超时 | renderer 反复重启，首帧未出现 |
| `--js-flags=--jitless` | 第 55 次检查（约 9 分钟）通过 | 首帧和脚本自检可用 |

A/B 没有使用 `--single-process`、`--no-zygote`、CDP 或页面注入。`jitless` 仍然由独立
renderer 执行 JavaScript，只改变 V8 的代码生成路径，避开 TCG 下 JIT 冷启动/可执行代码
路径的长时间阻塞。

## 已观察到的功能证据

在 JITless 会话中，真实 QMP 鼠标点击 interaction 页“运行自检”按钮后，
`live-jitless/after2.ppm` 用：

```text
ppm_assert.py --profile official-interaction --expect-input --strict
```

得到严格集 5/5 通过，包含 `interaction_selfcheck_pass`。截图里 T1–T6、F1、核心检查
6/6 和文件系统检查均为绿色，说明 DOM、事件派发、数组计算、定时器、JSON、Promise 和
localStorage 已由 renderer 执行。

原始 JITless 轮证据：

`evidence/2026-11-16_t490-input-mp-jitless/`

## 仍需完成的输入门禁

JITless 轮的第一版键盘探针在按钮上成功率不足，原因是页面实际文本框在首屏下方，旧的
固定坐标落在说明文字；这属于输入坐标/滚动校准，不是 renderer 首帧失败。已经增加了
实时 QMP follow-up 驱动，用于：

1. 在真实页面上等待并记录页面位置；
2. 通过 QMP 鼠标把焦点放到可见文本框，再发送真实键盘字符；
3. 滚动到“真实点击 +1”按钮并用 QMP 鼠标点击；
4. 单独保存回显、计数和导航截图。

`run_input_final.sh` 的默认多进程 interaction 入口现在自动加入 `--js-flags=--jitless`；
显式设置 `EXTRA_FLAGS_VALUE` 仍可运行对照轮。下一轮只需完成坐标校准并重新生成 input
gate，不需要再回到单进程模式。

## 对“为什么多进程卡很久”的补充解释

静态 index/layout 只需要 renderer 启动和文档/样式提交；interaction 还在 renderer 冷启动
阶段触发了 V8 JIT 相关路径。纯 TCG 下这些指令由 QEMU 动态翻译，JIT 的代码生成、内存
权限和线程同步会把冷启动放大到 IPC 超时窗口，Browser 随后回收 renderer 并重试，形成“多
进程一直卡住”的表象。增加 swap 只能避免内存容量不足，不能消除这条 CPU/代码生成路径。
