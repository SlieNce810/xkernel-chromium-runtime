# Chromium 149 mremap 子区间兼容修复与首帧跟进（2026-11-11）

## 发现

Chromium 149 renderer/bootstrap 期间反复调用：

```text
mremap(addr=0x7ffeffffe000,
       old_size=0x1000,
       new_size=0x2000,
       flags=0)
```

x-kernel 原实现要求 `addr == VMA.start()`，而实际 VMA 为：

```text
vma_start=0x7ffefff80000
vma_end=0x7fff00000000
```

请求的整个新范围仍在同一个 VMA 内，只是从 VMA 中间地址开始。Linux 允许这种已经被同一 VMA 覆盖的子区间调整；x-kernel 旧代码却返回 `InvalidInput`。

## 修复

在 `sys_mremap` 中增加了子区间路径：当没有 `MREMAP_FIXED`/`MREMAP_DONTUNMAP`，且新的子区间仍完全位于现有 VMA 内时，直接返回原地址，不重新创建或搬移 VMA。这样不会改变已有页表，只消除错误拒绝。

诊断期间增加了参数和失败原因日志，确认修复前失败原因为 `reason=not-vma-start`；修复后的运行中该类 `mremap` 错误计数为 **0**。

## Chromium 149 运行结果

证据目录：

```text
T490: /home/mo/xk6/evidence/2026-11-11_t490-score149-mremap-subrange-r5
本地: evidence/2026-11-11_t490-browser20-mremap-subrange-r5
kernel.bin SHA-256: 2b54e8e04458050988c7ac69ece19c404d1bf24eefcf41e6b334eb177911ae83
```

修复后观察到：

- `SANDBOX_SYSCALL_ERROR sysno=mremap`：0 条；
- `SANDBOX_MREMAP_RESOLVE_FAIL`：0 条；
- 真实 renderer 子进程持续存在并通过直接 PPID 观察；
- renderer 的 Unix socket bootstrap 消息持续双向收发；
- 不再出现此前的 `ChildThreadImpl::Terminating current process after 15 seconds with no connection` 作为主要退出模式；
- `FileURLLoader::Start` 仍能命中。

页面首帧仍未通过：

```text
严格像素集 0/7
心跳 0/8
SUMMARY_END ... strict_fail=9
```

因此 mremap 是一个真实的 Chromium 149 ABI 缺口并已修复，但不是全部首帧阻塞。下一断点仍在 `FileURLLoader::Start` 之后到 `DocumentLoader`/`DidCommitNavigation` 之间。

后续窄日志又确认 browser 对指定页面完成了真实文件读取：

```text
SANDBOX_OPEN  /usr/share/html-test/index.html
SANDBOX_PREAD_HTML len=1024 offset=0
SANDBOX_PREAD_HTML len=5832 offset=1024
```

这排除了“页面文件打不开/只读到一部分”的解释。renderer 子进程在 mremap 修复后保持运行，并且 zygote/bootstrap Unix socket 继续双向收发；当前缺口收敛到响应体/DataPipe 消费或 renderer 文档提交状态机。

## NetworkService A/B

在同一 mremap 修复内核上设置 `MP_NET_VALUE=disable` 的单变量轮没有出现 `FileURLLoader::Start`，页面仍失败，因此该开关不是当前修复路径。正式路径保留 NetworkService 默认行为。

同一 mremap 修复内核上禁用 `MojoIpczMemV2` 与 `MojoPosixUseWritev` 的 A/B 轮也没有改善：HTML 文件仍完整读取，`FileURLLoader::Start` 命中，但没有 `DocumentLoader`/`DidCommitNavigation`，严格像素仍失败。当前问题不是这两个 Mojo transport feature 的简单开关选择。

## 当前浏览器 20 分

| 项目 | 分数 | 状态 |
|---|---:|---|
| 指定 HTML 页面首帧 | 0/4 | mremap 错误已消除，但文档提交和像素仍失败。 |
| renderer 多进程结构 | 4/4 | 真实 Browser→zygote→renderer 直接父链已在 [report/200](200-T490-Chromium149-real-renderer-ppid-r2-20261111.md) 通过。 |
| 双标签页/窗口 | 0/4 | 当前候选未复验。 |
| 键鼠 | 0/4 | 当前候选未复验。 |
| JavaScript | 0/2 | 当前候选未复验。 |
| CSS | 0/2 | 当前候选未复验。 |

## 下一步

1. 保留 mremap 子区间修复，去掉高量诊断日志后重建干净内核。
2. 在同一 renderer bootstrap 证据上追踪 `FileURLLoader` response/DataPipe producer/consumer 和 renderer 侧 `DocumentLoader`。
3. 若页面首帧通过，再迁移到双页签、真实输入、JS/CSS 验收。
