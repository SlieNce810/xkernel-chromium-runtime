# Chromium 149 musl R162 链接边界与截止日打包状态（2026-11-24）

## 本轮范围

本轮在 T490（`10.249.11.192`）继续使用
`/home/mo/chromium-src-149-alpine/out/tryframe-root4`，沿用 AArch64、musl、2 GiB
诊断参数。目标是验证 R133 已完成的 377/377 编译与归档对象，在补入已验证的链接兜底对象和
静态依赖后能否完成 guest `chrome` 链接。

本轮没有启动新的全量 Ninja 构建。R159 及之后的 GN 图会触发约 28k 个动作；本轮先采用
定向编译、归档成员补齐和隔离链接，以免把旧对象混用误写成最终构建结果。

## 已验证的定向输入

以下对象使用当前 GN 生成的 ARM64 musl 编译命令独立通过：

```text
obj/chrome/chrome_initial/musl_link_stubs.o
obj/net/net/net_musl_trust_stubs.o
obj/third_party/webrtc/api/audio/neural_residual_echo_estimator_creator/neural_residual_echo_estimator_creator_stub.o
```

为满足链接器的系统库搜索，使用 Chromium 自带 expat 源码在 T490 上构建了临时
`/home/mo/aarch64-expat/libexpat.a`。该文件没有写入系统包数据库，也没有被当作仓库证据提交。

此外，R162 隔离链接前检查了响应文件中的静态库成员，并补编了五个缺失的 ARM64 archive
成员；响应文件中不再存在可直接定位的缺失归档成员。

## R162 隔离链接结果

R162 使用 R133 的完成对象、当前 `chrome.rsp`、新增两个链接兜底对象、临时 expat 静态库
以及已验证的 `libuuid.a` 执行纯链接。链接命令和日志保存在 T490：

```text
/tmp/chrome-r162-link.sh
/tmp/chrome-build-r162.log
```

链接器不再报告 `-luuid` 或 `-lexpat` 缺失，但仍报告 20 个未定义入口，主要分为：

* WebRTC neural residual echo estimator；
* FCP confidential-compute `BaseCwt<OkpKey>::Decode`；
* Cast remoting、Floss 和 Linux notification bridge；
* Perfetto trace processor storage、JSON exporter 和 `TraceBlob`；
* V8 WebAssembly `BackingStore` 方法。

代表性结果如下：

```text
ld.lld: error: undefined symbol: webrtc::CreateNeuralResidualEchoEstimator(...)
ld.lld: error: undefined symbol: fcp::confidential_compute::cose_internal::BaseCwt<...>::Decode(...)
ld.lld: error: undefined symbol: CastRemotingConnector::Get(...)
ld.lld: error: undefined symbol: perfetto::trace_processor::TraceProcessorStorage::CreateInstance(...)
ld.lld: error: undefined symbol: v8::internal::BackingStore::AllocateWasmMemory(...)
```

输出目录目前仍没有可执行的 `chrome` AArch64 ELF：

```text
/home/mo/chromium-src-149-alpine/out/tryframe-root4/chrome  # 不存在
```

因此 R162 仍是源码链接诊断，不能进入 guest 冷启动、稳定性或性能 gate。

## 截止日可交付边界

截至北京时间 2026-11-24 21:11：

* 已推送的仓库提交仍为 `5e828c63`；
* 现有历史功能和兼容性证据可继续归档；
* 源 Chromium 149 的可运行 ELF 尚未生成；
* 四项正式性能指标仍为 `0/4`，before/after 仍为 `0/0`；
* 本轮新增的链接结果只能作为未完成项和复现边界提交。

若在 2026-11-25 前打包，提交材料必须明确区分历史已验证证据、源码构建诊断和仍未完成的
稳定性/性能条款。不能把 R133 的 377/377 编译、R162 隔离链接或已有预编译 Chromium
运行结果写成“Chromium 149 源码最终构建完成”。

## 后续正式构建要求

链接依赖冻结后，必须在新的输出目录重新运行 `gn gen` 和完整的
`ninja -C <out> chrome`，随后检查 AArch64 ELF、SHA-256、guest 注入、冷启动和功能 gate。
只有这次全量构建通过，才可以开始新的正式稳定性和性能采样。
