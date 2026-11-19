# Chromium 149 inotify `NotFound` 路径分类（2026-11-19）

## 结论

这 7 次 `inotify_add_watch` 失败是对当前 rootfs 中不存在的可选配置路径进行 watch 的结果，不是 inotify syscall 缺失，也没有阻断首页加载。路径诊断内核返回 `KErrorKind::NotFound`（Linux 对应 `ENOENT`），没有 `ENOSYS`/`ENOTSUP`。

四次 policy 路径请求为 `/etc/chromium/policies`（两次）、`/etc/chromium/policies/managed` 和 `/etc/chromium/policies/recommended`。Chromium 149 源码 `components/policy/core/common/policy_paths.cc:21` 将 Linux 系统策略根目录定义为 `/etc/chromium/policies`；`components/policy/core/common/config_dir_policy_loader.cc:32-60` 定义并尝试监视 `managed` 和 `recommended` 两个子目录，`config_dir_policy_loader.cc:103-123` 在目录没有 policy 文件时跳过加载。

另外三次请求为 `/etc/localtime`、`/etc/timezone` 和 `/etc/TZ`。诊断日志给出这些实际路径，但没有定位到各自的 Chromium 调用点。Chromium 149 的通用 Linux watcher 源码 `base/files/file_path_watcher_inotify.cc:676-697` 为目标路径组件逐级加 watch；当某个组件不可访问时会忽略该 watch 错误并继续尝试可访问的父目录。

同一实现的失败处理与 x-kernel 的结果一致：缺失目录不装 watch，调用方不会因其不存在而中断初始化。独立的 inotify named-create C probe 在正式候选内核 `fa02114ae8058e3da43942ec614f098f53a2b5b41b20181b7728f7992c983e48` 上通过 7/7；同一内核的 Chromium 首页 strict gate 也通过，完整数值见 [report 340](340-T490同一候选内核兼容性与PSS-USS复测-20261119.md) 和 [report 339](339-Chromium149候选内核首页与进程链复核-20261119.md)。

## 最小复现与诊断方式

- `compatprobe.c --inotify-timerfd` 在 guest 内创建临时 watch 目录和文件，验证 `IN_CREATE` 事件可读；此用例在上述候选 SHA 上通过。
- Browser integration 跑指定 `index.html`，原始 console 中记录到 7 次 `NotFound`。为取得路径，诊断版内核只在 `sys_inotify_add_watch` 路径解析失败时输出 pathname/mask/errno；诊断补丁为 [inotify-add-watch-path-diagnostic.patch](../patches/compat/inotify-add-watch-path-diagnostic.patch)。诊断二进制 SHA `ead6710a29f606fcf8f698f24170dac220860e2c3ddcd50078b26c1e3fbe890f` 仅用于定位，复测结束后恢复正式候选 binary SHA `fa02114a…`；原始 `/home/mo/x-kernel` 未改动。
- guest `strace` 自检失败，未把 strace 结果用于结论；路径来自诊断内核日志。所有 7 行路径日志、完整 console、命令与环境、6 张 QEMU 截图判据及 PPM SHA-256 见 [inotify path diagnostic evidence](../evidence/2026-11-19_t490-codex-2026-11-19-inotify-watch-path-diagnostic-r1/)；原始 PPM 留在 T490。

## 验收分类

| 项目 | 结果 |
|---|---|
| `inotify_init1` / `inotify_add_watch` / `inotify_rm_watch` | 运行；缺失可选路径返回 `NotFound` |
| Chromium policy 目录 watch | 可选 policy 目录不存在时跳过加载，不阻断首页 |
| Chromium time-zone 路径 watch | 缺失文件作为可选路径处理，父目录 watch best-effort |
| watched-directory `IN_CREATE` ABI | 同候选 SHA C probe 通过 |
| 默认多进程指定首页 | 同候选 SHA 页面 strict PASS |

因此这 7 次 `NotFound` 不再作为待修复缺陷计入兼容性矩阵。诊断轮本身只用于 path attribution；其长日志未作为性能数据。
