# 19 · Chromium 渲染矩阵与下一处阻塞

## 本轮结果

T490 当前内核包含 ARM `/proc/cpuinfo` 字段和 inotify 配额节点补丁。Wayland/Ozone 矩阵已完成：

| 组合 | browser | renderer | 页面导航 | 结果 |
|---|---:|---:|---:|---|
| `gl=none + in-process` | 存活 | 0 | `FileURLLoader::Start` | 画面冻结 |
| `angle-vulkan + in-process` | 存活 | 0 | 有 | 画面冻结 |
| `angle-opengles + in-process` | 存活 | 0 | 有 | GL 实现选择失败/画面冻结 |
| `angle-vulkan + separate` | 存活 | 0 | 有 | GPU 子进程 `48896 = 191<<8` |

共同事实：`FileURLLoader::Start` 已出现，但 `RenderProcessHost`、`type=renderer`、`CommitNavigation` 均为 0。说明浏览器能够启动并开始文件加载，但没有完成 renderer 创建。

证据目录：

- `evidence/2026-09-22_t490-ozone-c0-nogpu/`
- `evidence/2026-09-22_t490-ozone-c1-anglevulkan/`
- `evidence/2026-09-22_t490-ozone-c2-angleopengles/`
- `evidence/2026-09-22_t490-ozone-c3-gpuseparate/`
- `evidence/2026-09-22_t490-x11-render-probe/`

X11/Xwayland 对照也未形成回退路线：Xwayland 报 `GBM Wayland interfaces not available`，随后 `x11_get_atoms` assertion，Chromium 以 `rc=1` 退出。

## 下一步

不再继续枚举 GL 参数。下一轮应围绕 `FileURLLoader` 后的 renderer 创建请求，增加 Chromium content/zygote/mojo 详细日志，并核对 x-kernel 的 `clone`、进程间 socket、`pidfd`、`futex`、`execve` 和子进程退出状态。验收标准仍是首个 renderer PID、页面 marker 和相邻截图差异同时出现。
