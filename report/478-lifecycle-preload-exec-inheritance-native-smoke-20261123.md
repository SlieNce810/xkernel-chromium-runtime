# Lifecycle preload 的 renderer exec 继承（2026-11-23）

## 目的

R22 的 preload 在 Chromium zygote fork 边界能够记录 fork，但 renderer 重新加载
preload 后没有携带原来的 `request_id` 和 navigation identity，因此正式
`renderer_ready` 事件无法配对。本轮在不改变 Chromium 默认多进程参数的条件下，
补齐 preload 对 renderer `execve`/`execveat` 的环境继承。

## 实现

`scripts/t490/lifecycle_event_preload.c` 新增：

- `execve` 和 `execveat` 的动态符号包装；
- 识别包含 `--type=renderer` 的目标命令；
- 为 renderer 重新构造 `LD_PRELOAD` 环境项；
- 传递 `XK_METRICS_RENDERER_REQUEST_ID` 和
  `XK_METRICS_RENDERER_NAV_ID`；
- renderer preload constructor 读取这两个身份字段，再与 zygote 的
  `zygote_fork_boundary` 配对生成 `renderer_ready`。

已有的 zygote fork 路径和默认 Browser → Zygote → Renderer 参数保持不变。

## Native smoke 结果

执行：

```bash
bash scripts/t490/test_lifecycle_preload_native.sh
```

结果：

```text
LIFECYCLE_PRELOAD_NATIVE_SMOKE=PASS waits=epoll,poll,ppoll fork-ready=paired
```

本轮 fixture 新增了真实 `fork → execve(--type=renderer)` 路径，验证到：

- zygote 产生的 `request_id` 被保留；
- renderer exec 后重新加载 preload；
- renderer 进程读取同一个 request/navigation identity；
- `renderer_ready.pid` 与 fork 的 `child_pid` 一致；
- `renderer_ready.source` 为 `CrRendererMain-first-poll-or-epoll-wait`。

同一轮本地 Python 回归仍为 `78 tests ... OK`。

## 证据边界

这轮证明的是 preload 的 exec 继承机制和事件配对，尚未证明 Chromium 149
guest 运行时已经实际走过该路径。T490 上的 exact Chromium 149 R113 构建仍在
后台进行；构建完成后还需要使用真实 Chromium、Wayland 页面和 procfs 内存采样
复核该事件，再将 renderer-ready 纳入正式性能样本。
