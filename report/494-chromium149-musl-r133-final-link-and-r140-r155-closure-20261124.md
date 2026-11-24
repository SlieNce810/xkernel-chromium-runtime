# Chromium 149 musl R133 最终链接与 R140–R155 收口记录（2026-11-24）

## 已完成的构建阶段

R131/R133 在 T490 的 `/home/mo/chromium-src-149-alpine/out/tryframe-root4` 完成了
Chromium 149 AArch64/musl 的全部源码编译和归档。R133 进度为 `377/377`，随后执行
guest `chrome` 最终链接。源码、工具链和远端日志仍保留在 T490；本轮没有把未链接的
输出目录误记为可运行 binary。

已确认并记录的阻断顺序：

1. R128 host V8 helper：libvpx host x64 配置缺少 `HAVE_X86_ASM`，已由补丁 [0044](patches/0044-chromium-musl-libvpx-host-x86-asm.patch) 定向恢复。
2. R131 host helper：精简 args 关闭了 libsrtp、Skia JPEG 和 V8 context snapshot 依赖，
   先恢复 libsrtp/JPEG，随后固定 `use_v8_context_snapshot=false`，使 guest 页面所需的
   目标树可以继续编译。
3. R133 compile：`use_nss_certs=false` 仍将 Firefox NSS importer 源编入 utility，
   已形成 [0045](patches/0045-chromium-musl-firefox-nss-guard.patch)；无 NSS 时只跳过
   密码导入，Firefox 书签/历史等其它 importer 保持可编译。
4. R133 link：目标 sysroot 没有 `libuuid`，`ld.lld` 报 `unable to find library -luuid`。
   T490 已从 Debian snapshot 下载 arm64 `uuid-dev`，只提取 `libuuid.a` 到
   `/home/mo/aarch64-libuuid/usr/lib`，并以 [0047](patches/0047-chromium-musl-guest-libuuid-search-path.patch)
   的 `-L` 选项重试；host 的 `uuid-dev-r118` 仍单独用于 host helper。

## R140–R155 的结果

补齐 `libuuid` 后，链接继续暴露出当前诊断裁剪与源码子模块不一致：

- libvpx AArch64 dotprod/VP9 postproc 入口与当前生成配置不一致；
- root Skia 的 JPEG/`SkParsePath` 源和 `third_party/skia` 的裁剪条件不一致；启用它会
  触发 28k host/guest 动作重编，且 host/guest 两侧的 `jpeglib.h` 条件不同；
- V8 WebAssembly 在 `v8_jitless=true` 下不能直接重新打开；试验性启用 Turbofan/Wasm
  触发约 587 个 V8/host generator 动作，尚未形成最终 binary；
- 无 TFLite 的 WebRTC neural residual creator 已增加空实现候选，但需要进一步校验其
  public target 和 include closure；
- federated compute checkout 的 `monitoring.cc` 缺失、FCP COSE 源依赖的
  `absl/status/status_builder.h` 也与当前 Abseil/源码快照不匹配。私有 metrics 路径已
  通过 [0046](patches/0046-chromium-musl-private-metrics-no-fcp-fallback.patch) 保持
  加密 reporting disabled，避免把不完整 FCP 子树引入页面运行；该补丁尚需在干净
  Chromium 源树上做一次单目标复核。
- 最终链接还存在 DBus/BlueZ/notification platform、Linux platform util、net trust
  store、SQLite omit 配置、`vpx_variance4x4_neon_dotprod` 等剩余未定义符号；这些均
  是下一轮兼容性补丁候选，尚未写成成功结论。

R140–R155 的原始日志分别保留在 T490：

```text
/tmp/chrome-build-r140.log
/tmp/chrome-build-r141.log
/tmp/chrome-build-r142.log
/tmp/chrome-build-r143.log
/tmp/chrome-build-r144.log
/tmp/chrome-build-r145.log
/tmp/chrome-build-r146.log
/tmp/chrome-build-r147.log
/tmp/chrome-build-r148.log
/tmp/chrome-build-r149.log
/tmp/chrome-build-r150.log
/tmp/chrome-build-r151.log
/tmp/chrome-build-r152.log
/tmp/chrome-build-r153.log
/tmp/chrome-build-r154.log
/tmp/chrome-build-r155.log
```

## 当前验收结论

- Chromium 149 源码已推进到 guest 最终链接阶段；**尚未生成可运行的 `chrome` ELF**。
- 因 binary 未完成，尚未执行源码 binary 的 package manifest、guest 三次冷启动、30
  分钟/十次加载或四项性能 before/after；README 中的正式性能 `0/4`、before/after
  `0/0` 结论继续有效。
- TCG 期间的兼容性和构建证据与正式 guest 性能统计分开保存；不把 R133 的编译成功或
  R140–R155 的局部修复写成稳定性/性能通过。

