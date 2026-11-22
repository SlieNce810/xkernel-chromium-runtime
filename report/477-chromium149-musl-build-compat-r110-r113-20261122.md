# Chromium 149 T490 构建兼容性增量（R110–R113，2026-11-22）

## 范围

本轮在 T490（`mo@10.249.11.192`）的 exact Chromium 149 源码树
`/home/mo/chromium-src-149-alpine`、revision
`9d2c8156a72129edca4785abb98866fad60ea338` 和
`out/tryframe-root4` 上继续补齐可运行的 renderer lifecycle 观测构建。
构建使用 AArch64 musl 交叉工具链、纯 TCG 目标配置和默认多进程代码路径。

## 已确认的阻断与最小处理

### R110：`std::optional::value_or({})` 不兼容

第一次完整 `chrome` 增量构建在约 `2489/31172` 停止：

```
components/autofill/core/browser/payments/full_card_request.cc:127:54:
error: no matching member function for call to 'value_or'
request_->context_token = std::move(context_token).value_or({});
```

T490 使用的 musl libc++ 版本不能从空初始化列表推导 `value_or` 的模板参数。
`context_token` 的类型是 `std::optional<std::string>`，因此已在远端临时改为
`std::move(context_token).value_or(std::string())`，业务含义保持为空字符串默认值。
原文件保留为 `.pre-musl-value-or`，修改文件 SHA-256 为：

```
45cdc4e0ed62d420790102cdf95847b80e3cb358b3e196d4bb9c0cc9bd76e37b
```

R111 已越过该对象，说明这个兼容修复有效。

### R111：Crashpad libcurl 头文件缺失

R111 在 R110 修复后继续构建，并在约 `4004/28677` 停止：

```
third_party/crashpad/crashpad/util/net/http_transport_libcurl.cc:17:10:
fatal error: 'curl/curl.h' file not found
```

该源文件通过 `dlopen` 使用 libcurl，但构建环境没有 curl 开发头文件。

### R112：socket transport 方案的副作用

R112 曾将 GN 参数 `crashpad_http_transport_impl` 临时设为 `"socket"`，并成功重新
生成了 35041 个 GN targets；Crashpad socket 路径本身可编译。但 GN 参数变化使
整个 `chrome` 闭包出现大量命令行/生成物重编译，未继续保留该方案。

### R113：临时 curl 声明头与生成物缺口

R113 恢复了 R111 的 GN 参数，在源码 include 根下临时加入
`third_party/crashpad/crashpad/curl/curl.h`，只声明 Crashpad 动态加载代码所需的
opaque 类型、枚举常量和函数指针签名，避免链接 libcurl。临时头 SHA-256：

```
8b38cc81b01f5a2dc011d9cbd7134e579f39d20782c090a0a4a5c6db8c67165a
```

R113 已转为 T490 后台增量构建，PID 为 `1131073`，日志为
`/tmp/chrome-build-r113-bg.log`。该轮随后暴露了两个源快照生成物缺口：

```
content/browser/gpu/gpu_internals_ui.cc:
fatal error: 'gpu/config/gpu_lists_version.h' file not found

gpu_internals_ui.cc:744:
error: expected ')'
```

原因是该 Chromium 源码快照把两个诊断元数据文件列在 `.gitignore` 中，但没有随
源快照提供。为保持诊断页可编译，T490 临时补入：

- `gpu/config/gpu_lists_version.h`，SHA-256
  `a562e81cc2d8a24d41f23e343b08ea8654fc2eb5b2357396fa55faa4191051d5`；
- `skia/ext/skia_commit_hash.h` 中的 `SKIA_COMMIT_HASH` 定义，SHA-256
  `0e4e8f21a303b5b7dd0e40689f4fd4106660ed4bc748083f32c36288ded0f300`。

补入后 `gpu_internals_ui.o` 单独编译通过。R114 已使用同一输出目录重新启动，PID
为 `1133481`，日志为 `/tmp/chrome-build-r114-bg.log`。在最终 `chrome` 链接前，
本轮仍不能记为可运行 Chromium 或性能样本通过。

## 当前构建命令

```bash
cd /home/mo/chromium-src-149-alpine
export PATH=/home/mo/chromium-src-149-alpine/third_party/node/linux/node-linux-x64/bin:$PATH
/home/mo/ninja-src/ninja -C out/tryframe-root4 -j8 chrome
```

R113 的完整日志在 T490 `/tmp/chrome-build-r113-bg.log`；R114 的完整日志在
T490 `/tmp/chrome-build-r114-bg.log`。下一步应等待 R114 会话结束，
核对 `chrome` 的 AArch64 ELF 和 lifecycle hook 对象，再决定是否清理临时 curl 头并
重编译带 `CHROMIUM_ENABLE_MULTIPROCESS_EVENTLOG=1` 的 RPH/zygote 对象。

## 证据限制

- R110 的失败日志位于 T490 `/tmp/chrome-build-r110.log`，失败原因已定位。
- R111/R112 只用于增量定位，未导出正式 evidence bundle。
- R113 已因生成物缺口停止；R114 仍在进行中。当前性能有效样本仍为 `0/0`，没有
  运行时 renderer-ready 结论。
