# Chromium Renderer lifecycle hook compile（R106，2026-11-22）

R104 已确认 `.so` 预加载没有进入 Chromium zygote fork 出来的 Renderer。R106 继续验证机制补丁 [0024-chromium-renderer-lifecycle-events.patch](patches/0024-chromium-renderer-lifecycle-events.patch) 的源码可编译性，目标输出单独放在 T490 的 `out/lifecycle-arm64`，不接触已安装的 Browser 二进制。

## 生成环境

- T490：`mo-ThinkPad-T490`，地址 `10.249.11.192`。
- Chromium 源码 revision：`4b8153ab58d3c3f4c9f7e4baad9616ecf80db5fa`。
- 已安装 Browser SHA-256：`d7d89bcb466c1d9a7ab209220c8ab997f66c02b77c5e80d3ea10ed64c772a641`。
- 独立 GN 输出：`out/lifecycle-arm64`；GN 成功生成 35,378 个目标。因为 T490 主机没有 `pkg-config`，该诊断输出使用只返回空 flags 的临时 wrapper；它没有写入仓库，也没有用于运行时。
- 本轮补齐了直接编译所需的 Mojo、protobuf 和 buildflags 生成物，包括 quota、file-system-access、font service、memory usage monitor 和 `google_apis/buildflags.h`。

## 结果

| 目标 | 工具链 | 结果 | 说明 |
|---|---|---:|---|
| `content/zygote/zygote_main_linux.cc` | T490 Chromium host clang | PASS | 直接编译，1.76 s |
| `content/browser/renderer_host/render_process_host_impl.cc` | T490 Chromium host clang | PASS | 直接编译，45.21 s；仅有既存 `AXPlatformNodeId` extra-qualification warning |
| 同一 RPH 源文件 | AArch64/musl 诊断命令 | INVALID | T490 主机的交叉 C++ 头文件组合不完整：musl 没有 glibc 风格 `strtoll_l`/`strtoull_l`，且独立输出还缺 `partition_alloc/buildflags.h` |
| 完整 Chromium 链接 | AArch64 | 未执行 | Ninja 首个依赖需要 DevTools esbuild，而镜像没有可用的 bundled `node` |

主机 clang 的两个直接编译均使用启用 `CHROMIUM_ENABLE_MULTIPROCESS_EVENTLOG` 的同一生成配置，且 RPH 编译已经包含补丁新增的 `renderer-ready` 调用。该结果证明补丁的 C++ API、头文件和调用点可以通过 Chromium 源码编译检查；没有产生可运行的 AArch64 新二进制，因此本轮不改变正式性能数据，也不把 `renderer_ready` 标记为有效。

## 证据

- [compile-summary.txt](../evidence/2026-11-22_chromium-lifecycle-direct-compile-r106/compile-summary.txt)
- [cmd.txt](../evidence/2026-11-22_chromium-lifecycle-direct-compile-r106/cmd.txt)
- [manifest.txt](../evidence/2026-11-22_chromium-lifecycle-direct-compile-r106/manifest.txt)
- [remote-env.txt](../evidence/2026-11-22_chromium-lifecycle-direct-compile-r106/remote-env.txt)
- [RPH host compile log](../evidence/2026-11-22_chromium-lifecycle-direct-compile-r106/rph-direct-x86-r106.log)
- [zygote host compile log](../evidence/2026-11-22_chromium-lifecycle-direct-compile-r106/zygote-direct-x86-r106.log)
- [AArch64 diagnostic log](../evidence/2026-11-22_chromium-lifecycle-direct-compile-r106/rph-direct-arm64-r106.log)

## 判定

R106 通过了机制补丁的 Chromium host 编译检查，仍未完成 AArch64 链接、注入和运行时事件验证。正式性能状态保持 `0/0`；下一轮应在具备完整 AArch64 C++/Node 构建依赖的独立输出中完成链接，或采用 Browser IPC 的真实连接 observer。任何仅观察到 Renderer PID 的记录仍不能替代 `renderer_ready`。
