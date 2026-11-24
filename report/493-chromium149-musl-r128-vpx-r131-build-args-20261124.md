# Chromium 149 R128/R131 host helper与构建参数复核（2026-11-24）

## R128 的失败

R128 在 2,669/4,125 actions 处停止于：

```text
clang_x64_v8_arm64/v8_context_snapshot_generator
undefined symbol: vpx_sub_pixel_avg_variance16x16_sse2
undefined symbol: vpx_sub_pixel_avg_variance16x16_ssse3
...
```

完整日志在 T490 的 `/tmp/chrome-build-r128-bg.log`。检查 host x64 的
`third_party/libvpx/source/config/linux/x64/vpx_config.h` 发现此前诊断配置生成改动删掉了
`HAVE_X86_ASM 1`。`variance_sse2.c` 和 `variance_ssse3` 的 RTCD 头仍声明这些入口，
但源文件被 `#if HAVE_X86_ASM` 排除，所以 archive 只有引用没有定义。

补丁 [0044](patches/0044-chromium-musl-libvpx-host-x86-asm.patch) 只恢复 host x64
配置宏，不触碰 AArch64 guest 配置。恢复后，libvpx 相关 undefined symbols 不再出现。

## R131 的参数调整

host helper 还暴露出精简诊断 args 与 Chromium 目标依赖不一致：

```text
rtc_build_libsrtp = false
skia_use_libjpeg_turbo_decode = false
skia_use_libjpeg_turbo_encode = false
```

但 WebRTC `srtp_session`、Blink image decoder 和 Skia image encoder 仍引用对应实现。
R131 在 T490 输出树临时启用：

```text
rtc_build_libsrtp = true
skia_use_libjpeg_turbo_decode = true
skia_use_libjpeg_turbo_encode = true
use_v8_context_snapshot = false
```

最后一项关闭可选的 V8 context snapshot host generator，避免它把 SQLite、Wasm、dav1d
等在诊断 args 中关闭的功能接口强行合并到 host helper 链接；它不改变页面 HTML/CSS/JS
判据，但会改变 V8 启动路径，正式性能统计前必须把它作为固定条件记录。

GN 重新生成后，R131 目标图为 2,205 actions；当前正在同一 T490、同一
`out/tryframe-root4` 继续执行 `ninja -j8 chrome`，日志为
`/tmp/chrome-build-r131-bg.log`。R131 仍未完成最终链接，不能据此宣称二进制可运行。

## 验证记录

- R128 失败发生在 host helper 链接，非 guest `chrome` 最终链接。
- `HAVE_X86_ASM` 恢复后，libvpx 的 `vpx_sub_pixel_avg_variance*` undefined 集合消失。
- R131 已开始真实编译 libsrtp 对象；截至本报告更新时未出现新的 `FAILED`。
- 所有运行仍使用 `env -u CHROMIUM_DIAGNOSTIC_ALLOW_TS_ERRORS`，不接受 TypeScript
  占位输出。

