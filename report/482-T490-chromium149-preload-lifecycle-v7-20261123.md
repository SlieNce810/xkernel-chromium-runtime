# T490 Chromium 149 preload lifecycle v7（2026-11-23）

## 结果

本轮终于把同一 Chromium 149.0.7827.53 二进制（SHA-256
`d7d89bcb466c1d9a7ab209220c8ab997f66c02b77c5e80d3ea10ed64c772a641`）与新版
`lifecycle_event_preload.so` 接通。T490 使用 `pkg-installed.img`、2 GiB
AArch64 纯 TCG、Weston 原生 Wayland 和默认多进程参数；会话实际约 303 秒，
10/10 周期/最终截图严格判据均为 `True`，QEMU 正常退出。

生命周期 JSONL 已在观测循环中增量导出到 console，恢复出 13 条完整事件，另有一条
串口控制台交错导致的序号缺口（导出计数曾达到14，原始 console 保留）。有效事件类型：

- `preload_attached`：Browser、Zygote 及其子进程的 preload constructor；
- `browser_main_loop_ready`：Browser PID 71，guest 单调时间 `81.192852480 s`；
- `zygote_fork_boundary`：同一 zygote PID 223 产生 Renderer 候选 409、479、480、
  518、522，并带有唯一 request ID；
- `navigation_requested`：`file:///usr/share/html-test/index.html`，导航编号 `nav-00`；
- 进程观察器另外确认 Renderer PID 409 等已出现。

本轮没有恢复 `renderer_ready`，也没有 `first_valid_frame`；因此它证明了真实
Chromium 149 的 preload attach、zygote fork identity 和 Browser ready 链路，
但 renderer-create 性能指标仍为 invalid，不能进入正式四项性能 CSV。

## 关键事件摘录

```text
preload_attached pid=70  t_ns=43779205424
preload_attached pid=71  t_ns=52428625024
browser_main_loop_ready pid=71 t_ns=81192852480
zygote_fork_boundary pid=223 child_pid=409 request=...:z223:102149661984:1
zygote_fork_boundary pid=223 child_pid=479 request=...:z223:122415431984:2
zygote_fork_boundary pid=223 child_pid=480 request=...:z223:123387187616:3
zygote_fork_boundary pid=223 child_pid=518 request=...:z223:137607543872:4
zygote_fork_boundary pid=223 child_pid=522 request=...:z223:139313723712:5
navigation_requested pid=71 navigation_id=nav-00
```

`lifecycle-events.jsonl` 保存了可解析的13条事件；含交错/缺块的原始串口仍以
`console.log` 为准。事件均使用 `LINUX_CLOCK_MONOTONIC`，run ID 为
`preload-exec149-v7`。

## 验收边界

- **页面/多进程基线**：通过；10 个周期画面和最终画面严格判据全通过，Browser、
  Zygote、Renderer 观察链出现。
- **preload attach/Browser ready**：通过；事件从 guest 文件流经 console，且有
  SHA/行数/增量序号标记。
- **renderer ready/first frame**：未通过/缺失；`renderer-observed` 不替代真实 ready。
- **内存采样**：关闭；没有 RSS/PSS/USS 峰值样本。
- **正式稳定性与性能**：不计入；这是一轮机制诊断，不是30分钟/10次导航或5+5批次。

## 原始证据

```text
/home/mo/xk6/evidence/2026-11-23_t490-preload-exec149-v7/
```

仓库保存了 `console.log`、命令/环境、页面与严格判据、`lifecycle-events.jsonl`
和非 PPM 哈希清单；原始 PPM 仍留在 T490。下一步是在保持该事件链的前提下补真实
renderer-ready 边界，或明确报告其不可用原因，不用进程首次出现时间替代。
