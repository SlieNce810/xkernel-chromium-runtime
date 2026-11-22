# Chromium Renderer lifecycle hook AArch64 编译（R107，2026-11-22）

R106 已在 T490 主机 clang 下通过两个源码对象的编译检查。R107 使用独立的 AArch64/musl 目标命令继续验证同一机制补丁 [0024-chromium-renderer-lifecycle-events.patch](patches/0024-chromium-renderer-lifecycle-events.patch)，并确认输出对象确实是 AArch64 ELF，而不是主机架构对象。

## 条件和临时覆盖

- T490：`mo-ThinkPad-T490`，`10.249.11.192`。
- Chromium 源码 revision：`4b8153ab58d3c3f4c9f7e4baad9616ecf80db5fa`。
- 现有 Browser SHA-256：`d7d89bcb466c1d9a7ab209220c8ab997f66c02b77c5e80d3ea10ed64c772a641`。
- 输出目录：`/home/mo/chromium-src/out/lifecycle-arm64`。
- 使用 T490 上已有的 musl 交叉 sysroot 和 libc++，并通过 `/tmp` 下的临时 include overlay 提供生成的 Perfetto、ICU 和 buildflags 文件。overlay 不在源码树内；其中只把诊断输出的 PartitionAlloc thread-isolation buildflag 置为 0，以绕过 R106 已记录的配置问题。

## 结果

| 对象 | 结果 | 输出和耗时 |
|---|---:|---|
| `content/browser/renderer_host/render_process_host_impl.cc` | PASS | `render_process_host_impl.o`，AArch64 ELF relocatable，42.49 s |
| `content/zygote/zygote_linux.cc` | PASS | `zygote_main_linux.o`，AArch64 ELF relocatable，1.97 s |

两个对象均带 debug information，SHA-256 分别为：

- RPH：`794f2b2356ed6171c9b0cfc62c80988f1b17c7379207ba14de11ece50c8bf132`；
- zygote：`bf0ba328201461abb1c524352e8b93b4a645ef5837d62e85d20ad09f2cdb9d4b`。

RPH 对象包含补丁新增的 `OnChannelConnected` `renderer-ready` 调用点，zygote 对象包含真实 PID 取得后的 `renderer-create-requested` 调用点。R107 只证明了 AArch64 对象级编译，尚未进行链接、二进制替换、guest 启动或事件导出。

## 证据

- [compile-summary.txt](../evidence/2026-11-22_chromium-lifecycle-arm64-compile-r107/compile-summary.txt)
- [cmd.txt](../evidence/2026-11-22_chromium-lifecycle-arm64-compile-r107/cmd.txt)
- [manifest.txt](../evidence/2026-11-22_chromium-lifecycle-arm64-compile-r107/manifest.txt)
- [remote-env.txt](../evidence/2026-11-22_chromium-lifecycle-arm64-compile-r107/remote-env.txt)
- [RPH AArch64 compile log](../evidence/2026-11-22_chromium-lifecycle-arm64-compile-r107/rph-direct-arm64-r107.log)
- [zygote AArch64 compile log](../evidence/2026-11-22_chromium-lifecycle-arm64-compile-r107/zygote-direct-arm64-r107.log)

## 判定

R107 将机制补丁的编译证据从主机语法检查推进到真实 AArch64 relocatable 对象。由于没有完成链接和运行时注入，Renderer ready 事件仍为无效，正式四项性能数据仍保持 `0/0`。下一轮应以同一 overlay 完成最小链接或获取匹配的完整 instrumented AArch64 构建依赖，然后才进行一轮 guest 运行验证。
