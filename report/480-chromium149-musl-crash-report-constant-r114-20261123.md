# Chromium 149 R114 的 crash-report 常量兼容修复（2026-11-23）

## 失败位置

T490 上的 exact Chromium 149 AArch64/musl `ninja -C out/tryframe-root4 -j8 chrome`
在 `render_frame_host_impl.cc` 编译阶段停止，日志为：

```text
content/browser/renderer_host/render_frame_host_impl.cc:11070:30:
error: no member named 'kMaxCrashReportContextSize' in namespace 'blink::mojom';
did you mean 'kMaxCrashReportStorageSize'?
```

当前生成的 `gen/third_party/blink/public/mojom/frame/frame.mojom-forward.h`
只导出 `blink::mojom::kMaxCrashReportStorageSize`（值 5 MiB）。源文件仍使用旧的
`kMaxCrashReportContextSize` 名称，导致 R114 在 297/24139 个构建动作处失败；这
是源码与生成 Mojo 常量名称不一致的兼容性缺陷，不是 x-kernel 运行时阻断。

## 最小修复

补丁 [0026](patches/0026-chromium-musl-crash-report-constant.patch) 将两处旧名称
（比较和相邻注释）改为当前生成头提供的 `kMaxCrashReportStorageSize`，保持长度
限制和 bad-message 分支不变。

远端临时修复后的源码位置：

```text
/home/mo/chromium-src-149-alpine/content/browser/renderer_host/render_frame_host_impl.cc
```

重新编译前应先确认该行与生成头中的常量一致，再以同一 R114 输出目录继续
`ninja -C out/tryframe-root4 -j8 chrome`。修复后的对象和最终链接仍待构建返回码为 0
后记录；在此之前不能把它写成可运行 Chromium 149。

## 证据

- 失败日志：T490 `/tmp/chrome-build-r114-bg.log`，`BUILD_RC=1`。
- 失败对象：`obj/content/browser/browser/render_frame_host_impl.o`。
- 失败动作序号：`[291/24139]`，之后若干并行对象完成但 Ninja 以失败收尾。
- 生成头：`out/tryframe-root4/gen/third_party/blink/public/mojom/frame/frame.mojom-forward.h`。

这轮构建失败已与 Chromium 149 preload 运行诊断分开归档；后者使用已存在的
Chromium 149 预编译包，不能替代 R114 源码构建结果。
