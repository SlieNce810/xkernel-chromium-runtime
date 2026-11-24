# Chromium 149 musl 最终链接符号清单与下一轮入口（2026-11-24）

## 当前状态

T490 当前没有活动 Ninja 进程，`/home/mo/chromium-src-149-alpine/out/tryframe-root4/chrome`
不存在。R133 已完成 377/377 个编译/归档动作；R133–R155 的后续尝试没有产生可运行
二进制，不能进入 guest 运行或正式性能统计。

最近一次稳定可复核的 guest 链接日志为：

```text
/tmp/chrome-build-r146.log
```

该日志已经越过 `-luuid`，剩余 undefined symbol 主要集中在以下类别：

```text
platform_util::OpenExternal
platform_util::ShowItemInFolder
vpx_variance4x4_neon_dotprod
vp9_post_proc_frame
SkJpegMetadataDecoder / SkJpegEncoder / SkJpegDecoder
SkParsePath::FromSVGString
webrtc::CreateNeuralResidualEchoEstimator
fcp::confidential_compute::BaseCwt<OkpKey>::Decode
__arm_tpidr2_save
sqlite3Analyze / sqlite3Reindex
net::TestRootCerts::Init
net::CreateSslSystemTrustStoreChromeRoot
bluez::BluezDBusManager::Shutdown
NotificationPlatformBridge::Create
```

## 已验证的原因分类

1. **诊断裁剪与调用方不一致**：`use_dbus=false`、`use_nss_certs=false`、SQLite
   `SQLITE_OMIT_*` 和 no-TFLite/no-FCP 条件仍让调用方保留平台 API 引用。
2. **生成配置与源码快照不一致**：libvpx AArch64 RTCD 头声明 dotprod 入口，但当前
   source 只生成部分尺寸；VP9 postproc 源也没有进入实际 archive。
3. **Skia root target 与 submodule target 分离**：`third_party/skia` 和 root `skia`
   BUILD.gn 各自控制 sources/deps。只改其中一层会造成 source object 未进 archive，或
   host helper 同时触发 JPEG 头文件缺失。
4. **FCP checkout 不完整**：`src/fcp/base/monitoring.cc` 原本缺失，补空文件后仍发现
   当前 Abseil 没有 `absl/status/status_builder.h`，COSE 源无法直接作为 musl 依赖编译。

## 下一轮建议顺序

1. 先在干净输出副本只验证 root Skia target 的 source/archive 成员，确认 JPEG 和
   `SkParsePath` 只进入 guest arm64 target；host `clang_x64` 不拉入 JPEG sources。
2. 对 libvpx 使用最小 C fallback 或修正 RTCD 生成输入，先让 `vpx_variance4x4` 和
   `vp9_post_proc_frame` 在 archive 中有定义，再触发 guest link。
3. 给 no-DBus/no-NSS/no-FCP 分支增加明确 stub 或 GN source guard，避免只靠未定义符号
   观察运行时行为。
4. 最后处理 `__arm_tpidr2_save` 和 SQLite omit 配置；所有修复都先做单目标编译，
   再执行 `ninja -j8 chrome`，不要再次从 GN 条件变化引发 28k 全树重编。

在这些链接符号全部消失并通过 `file`/`readelf`/SHA-256 之后，才继续 package、guest
冷启动、稳定性和性能采集。当前正式状态仍为 `INCOMPLETE`、性能 `0/4`、before/after
`0/0`。

