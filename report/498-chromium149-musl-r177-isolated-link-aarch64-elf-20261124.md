# Chromium 149 musl R177 隔离链接生成 AArch64 ELF（2026-11-24）

## 结果

R177 在 T490（`10.249.11.192`）的
`/home/mo/chromium-src-149-alpine/out/tryframe-root4` 中完成了一次隔离链接，生成：

```text
chrome: ELF 64-bit LSB pie executable, ARM aarch64
interpreter /lib/ld-musl-aarch64.so.1
size=487474928
mode=775
sha256=58433b67eba7ecf4f6effaf7673ed6fe87f5640194ecd184b2106deca8803161
```

ELF 头验证结果：

```text
Class:   ELF64
Data:    little endian
Type:    DYN (position-independent executable)
Machine: AArch64
```

完整日志和隔离链接脚本保存在 T490：

```text
/tmp/chrome-r177-link.sh
/tmp/chrome-build-r177.log
/tmp/chrome-r175.rsp
```

R177 日志没有 `undefined symbol`、duplicate symbol 或链接失败记录。

## 本轮如何收口

R177 复用了 R133 已完成的 377/377 编译和归档对象，在响应文件中加入已经单独编译的
Chromium/Perfetto/WebRTC/Cast/Floss/通知对象，并加入诊断用符号对象：

* R162 的 Chrome/Net 链接兜底对象；
* WebRTC neural residual estimator ABI 修正版；
* Cast remoting、Floss、通知 bridge 和 Perfetto trace processor 对象；
* 现有 dav1d 静态库及 `dav1d_video_decoder.o`；
* V8 Wasm、libyuv JPEG、Linux sync 和少量基础 ABI 的符号级诊断对象。

用于复现诊断对象的源码/汇编材料已保存为：

* [0050 V8 Wasm 符号对象](patches/0050-chromium-musl-r177-v8-wasm-link-stubs.S)
* [0050 其他链接符号对象](patches/0050-chromium-musl-r177-misc-link-stubs.S)

这些对象只提供链接边界验证所需的空实现或错误返回，不能作为功能实现、稳定性修复或性能
优化结论。

## 验收边界

R177 证明了当前对象集合可以产出 AArch64 musl `chrome` ELF，但它仍是隔离链接结果：

1. 没有在新的干净输出目录重新运行完整 `gn gen` 和 `ninja -C <out> chrome`；
2. 使用了历史已完成对象、当前诊断对象和响应文件的组合；
3. 尚未注入 guest，也没有完成 Chromium 149 源码 ELF 的冷启动、功能、稳定性或性能 gate；
4. 四项正式性能指标仍为 `0/4`，before/after 仍为 `0/0`。

因此本结果可以作为 2026-11-25 截止包中的“源码链接诊断进展”和可复核 ELF 证据，不能
写成完整源码构建、稳定性通过或性能优化完成。后续仍需以冻结源码和 GN 参数在新输出目录
执行一次全量构建，再开始 guest 验收。
