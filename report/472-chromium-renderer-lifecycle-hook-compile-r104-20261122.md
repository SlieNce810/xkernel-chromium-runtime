# Chromium Renderer lifecycle hook mechanism patch（R104，2026-11-22）

根据 R104 的 preload 继承诊断，新增机制补丁 [0024-chromium-renderer-lifecycle-events.patch](../report/patches/0024-chromium-renderer-lifecycle-events.patch)：

- `content/zygote/zygote_linux.cc` 在拿到 Renderer 的真实 PID 后发出 `renderer-create-requested`；
- `content/browser/renderer_host/render_process_host_impl.cc` 在 `OnChannelConnected(peer_pid)` 发出 `renderer-ready`；
- 两个事件使用 Chromium multiprocess eventlog，事件中的 PID 可与进程实例和 zygote fork request 关联；
- 正常构建未启用事件宏时 `Emit` 保持 no-op，补丁本身不改变正式运行协议。

## 单文件编译验证

T490 Chromium 源码工作树：`/home/mo/chromium-src`，源码 revision `4b8153ab58d3c`，目标输出为 `instrumented-arm64`。为绕过诊断输出树中已知的 PartitionAlloc thread-isolation 常量配置，临时将生成的 `ENABLE_THREAD_ISOLATION` 设为 0，仅用于 direct compile，不写入正式源码或镜像。

- `obj/content/zygote/zygote/zygote_main_linux.o`：编译通过；
- `obj/content/browser/browser/render_process_host_impl.o`：编译失败，原因是 partial GN 生成树缺少 `components/services/storage/privileged/mojom/bucket_client_info.mojom-shared-internal.h`；
- 没有链接新 Chromium 二进制，也没有把该机制补丁用于正式性能数据。

编译原始日志和摘要在 [R104 direct compile evidence](../evidence/2026-11-22_chromium-lifecycle-direct-compile-r104/)。该补丁是可回退的机制候选，当前仍不能改变正式性能 0/0 判定。
