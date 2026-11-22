# Chromium 149 Renderer lifecycle hook AArch64 编译（R108，2026-11-22）

R108 在 T490 的 Chromium 149 独立源码树中验证了机制补丁的两个真实目标对象。R107 使用的是另一套 instrumented 源码；本轮改用实际 Chromium 149 源码 revision `9d2c8156a72129edca4785abb98866fad60ea338`，因此可以把“对象编译通过”与正式 Browser 的版本条件对齐。

## 临时改动和恢复

在 `/home/mo/chromium-src-149-alpine` 中先备份 `render_process_host_impl.cc`、`zygote_linux.cc`，再临时加入：

- `RenderProcessHostImpl::OnChannelConnected` 的 `renderer-ready` 事件；
- `Zygote::ForkWithRealPid` 在取得真实 PID 后的 `renderer-create-requested` 事件；
- `base/trace_event/chromium_multiprocess_eventlog.h`；
- 仅对两个对象的编译命令添加 `CHROMIUM_ENABLE_MULTIPROCESS_EVENTLOG=1`。

编译器报告缺失的 Mojo 生成物由同一 `tryframe-root4` 输出目录的 Ninja 目标按需生成，涉及 storage、remoting、cert verifier、metrics、auction worklet、tracing internals、font service 及 feature headers。编译完成后两个源码文件均恢复为编译前内容，临时 header 已删除；远端对应路径的 `git status` 为空。

## AArch64 结果

| 对象 | 结果 | 架构/耗时 | SHA-256 |
|---|---:|---|---|
| `content/browser/renderer_host/render_process_host_impl.cc` | PASS | AArch64 relocatable，32.61 s | `8c91626a723c9d0a4649d7719d73f9bbcd035dc3d5dc2b00b28a6b740424956d` |
| `content/zygote/zygote_linux.cc` | PASS | AArch64 relocatable，3.88 s | `39ec281db2a69cde665c406118a8f7f20b9fdee11bf19b36a1f86a128572b84c` |

`strings` 校验确认 RPH 对象含 `renderer-ready` 和 `child-process-channel-connected`，zygote 对象含 `renderer-create-requested` 和 `zygote-fork-real-pid`。两个文件均由 `file` 识别为未剥离的 ARM aarch64 relocatable ELF。

## 证据和限制

- [compile-summary.txt](../evidence/2026-11-22_chromium-lifecycle-exact149-arm64-compile-r108/compile-summary.txt)
- [cmd.txt](../evidence/2026-11-22_chromium-lifecycle-exact149-arm64-compile-r108/cmd.txt)
- [manifest.txt](../evidence/2026-11-22_chromium-lifecycle-exact149-arm64-compile-r108/manifest.txt)
- [remote-env.txt](../evidence/2026-11-22_chromium-lifecycle-exact149-arm64-compile-r108/remote-env.txt)
- [RPH compile log](../evidence/2026-11-22_chromium-lifecycle-exact149-arm64-compile-r108/rph-final-direct-arm64-r108.log)
- [zygote compile log](../evidence/2026-11-22_chromium-lifecycle-exact149-arm64-compile-r108/zygote-linux-direct-arm64-r108.log)
- [generator loop log](../evidence/2026-11-22_chromium-lifecycle-exact149-arm64-compile-r108/rph-generator-loop-r108.log)

本轮没有链接 `chrome`、替换 `/home/mo/xk6/tmp/binextract/chromium`、启动 guest 或导出运行时事件。因而 `renderer_ready` 仍没有正式有效样本，四项性能统计仍为 `0/0`，R108 不构成性能收益结论。
