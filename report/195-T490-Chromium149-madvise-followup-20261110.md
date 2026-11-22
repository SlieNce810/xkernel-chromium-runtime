# Chromium 149 madvise compatibility follow-up（2026-11-10）

在 renderer 无连接的首帧诊断中，临时 x-kernel 参数日志记录到 Chromium 149
使用了此前未覆盖的 Linux advice 值：

```text
0x10  MADV_DONTDUMP
0x11  MADV_DOFORK
0x12  MADV_WIPEONFORK
0x0a  MADV_DONTFORK（按 ABI 保留）
0x11/0x10  出现在 V8/PartitionAlloc 地址范围
```

旧实现只接受 `MADV_NORMAL/RANDOM/SEQUENTIAL/WILLNEED/FREE/DONTNEED`，这些
合法提示会返回 `EINVAL`。在独立诊断内核中将 fork/dump advice 扩展为无副作用
成功路径，并撤掉临时参数日志后重建，最终 kernel SHA 为：

```text
e229d46715be4fa37bcfa46c6ea00e8f5f1621cd2bcc598b9452502bf08aa992
```

证据目录：
`/home/mo/xk6/evidence/2026-11-10_t490-score149-madvise-fork-r1`

修复后的日志不再出现 `0x10/0x11/0x12` 的 `madvise` 拒绝，只剩 Chromium
传入的非法 advice `-1`；`FileURLLoader::Start` 仍能命中，但本轮没有
`DocumentLoader`、`DidCommitNavigation` 或 `FrameSink`，PPM 仍为 Weston 背景，
因此该内核兼容修复是真实 ABI 改善，但尚未解决 renderer Mojo 建连/页面首帧。

正式结论保持：renderer PID 和 Wayland 生命周期可观测，多进程 HTML 首帧尚未
通过；不能把这轮标记为渲染 PASS。
