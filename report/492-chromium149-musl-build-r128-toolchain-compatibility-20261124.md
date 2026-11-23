# Chromium 149 musl/AArch64 构建兼容性补丁与 R128 复核（2026-11-24）

## 范围

本轮在 T490（`10.249.11.192`）继续冻结的 Chromium 149 源码树上推进全量
`chrome` 构建，目标是得到可以注入 guest 的 AArch64/musl 二进制。源码版本为
`9d2c8156a72129edca4785abb98866fad60ea338`，输出目录为
`/home/mo/chromium-src-149-alpine/out/tryframe-root4`。本轮仍属于构建和工具链兼容性
复核；在最终链接、打包和 guest 严格页面运行完成前，不把本轮写成稳定性或性能通过。

统一构建命令：

```sh
cd /home/mo/chromium-src-149-alpine
env -u CHROMIUM_DIAGNOSTIC_ALLOW_TS_ERRORS \
  LIBRARY_PATH=/home/mo/uuid-dev-r118/usr/lib/x86_64-linux-gnu \
  /home/mo/ninja-src/ninja -C out/tryframe-root4 -j8 chrome
```

`CHROMIUM_DIAGNOSTIC_ALLOW_TS_ERRORS` 被明确移除，避免旧诊断轮生成的
`export {};` 占位 TypeScript 输出进入正式构建。`LIBRARY_PATH` 指向 T490 上以普通用户
解包的 `uuid-dev` 开发文件，不修改系统包数据库；它只提供 host helper 链接所需的
`libuuid.so`。

## 本轮已定位并验证的兼容性问题

| 编号 | 位置 | 复现/影响 | 修复 | 已完成验证 |
| --- | --- | --- | --- | --- |
| C149-01 | `base/debug/stack_trace_posix.cc` | musl sysroot 没有 `execinfo.h`，`HAVE_BACKTRACE` 关闭后仍有 `StackTrace::OutputToStreamWithPrefixImpl` 引用，Crashpad handler 链接失败 | 在无 backtrace 分支提供空实现，保持 ABI 完整 | `ninja -v chrome_crashpad_handler` 通过，3 actions |
| C149-02 | `chrome/common/crash_keys.cc` | `use_crash_key_stubs=true` 时 stub 没有 `.value()`，common object 编译失败 | 仅在 `USE_CRASHPAD_ANNOTATION` 开启时读取值，否则返回空 view | `ninja -v obj/chrome/common/common_lib/crash_keys.o` 通过 |
| C149-03 | `build/toolchain/linux/unbundle/BUILD.gn` | `compiled_action()` host helper 继承了 AArch64 guest toolchain，生成工具被错误地按 guest 链接 | 在 toolchain args 中显式保留 `host_toolchain`；同时保留 T490 的显式 musl clang 路径 | `clang_x64/nasm`、`clang_x64/generate_colors_info` 均生成成功 |
| C149-04 | `chrome/browser/BUILD.gn` | AArch64 guest 的 browser 依赖树强制拉入 host-only `generate_colors_info` 可执行文件并触发 `-luuid` 链接 | arm64 Linux 跳过该 public dep，compiled action 仍由 host toolchain 生成颜色数据 | `ninja -t query chrome` 不再把 `generate_colors_info` 作为 guest 根依赖 |
| C149-05 | `components/metrics/private_metrics/BUILD.gn` | federated compute 生成的 signed endorsements 头在目标编译阶段不可见 | 将 confidential compute proto 置于 public hard dependency；musl 目标移除不需要且不可用的实现/测试 crypto 依赖 | `metrics_services_manager.o` 定向编译通过 |
| C149-06 | `content/zygote/zygote_linux.cc` | 已有 renderer lifecycle 事件调用 `base::NumberToString`，但缺少声明头 | 增加 `base/strings/string_number_conversions.h` | zygote object 定向编译通过 |
| C149-07 | `chrome/browser/enterprise/connectors/reporting/BUILD.gn` | reporting implementation 使用 Crashpad client 类型但自身没有 client include/config | 为 `impl` source set 增加 Crashpad client dep | 两个 reporting object 定向编译通过 |
| C149-08 | `chrome/browser/net/profile_network_context_service.cc` | 无 NSS 的 Linux/musl 分支缺少平台 client-cert store；另有 `optional` 到 vector 的模板推导差异 | 使用空平台证书 store 保留 profile/browser 匹配；显式 `std::vector<uint8_t>()` | profile network object 定向编译通过 |
| C149-09 | `chrome/browser/ui/webui/certificate_manager/client_cert_sources.cc` | Linux 无 NSS 构建仍实例化 NSS-only client certificate source | 仅在 `IS_LINUX && USE_NSS_CERTS` 编译 NSS factory/writable source；其它 Linux 使用空 loader | certificate manager object 定向编译通过 |
| C149-10 | `chrome/browser/ui/startup/profile_launch_observer.cc` | Chromium bundled libc++ 对 `std::set<raw_ptr<Profile>>.contains(const Profile*)` 的异构比较器无法匹配 const pointer | 查询时只去除 lookup 参数的 const 限定，集合元素、生命周期和排序语义不变 | object 定向编译通过；随后纳入 R128 全量构建 |

每个最小补丁均保存在 [patches/](patches/)：`0035`–`0043`。`0039` 的 lifecycle
事件行属于前一轮已落地的观测改动，本轮补齐其缺失的数字转换头；`0037` 中 T490 的
显式 clang/musl 路径是冻结构建环境的一部分，`host_toolchain` 是本轮新增的机制修复。

## 相关工具链准备

旧输出树中 searchbox TypeScript 生成目录曾保留 11 字节 `export {};` 诊断占位文件。
本轮删除该目录的旧生成结果后，以无诊断环境变量方式重新执行：

```sh
env -u CHROMIUM_DIAGNOSTIC_ALLOW_TS_ERRORS \
  /home/mo/ninja-src/ninja -C out/tryframe-root4 -v \
  ui/webui/resources/cr_components/searchbox:build_ts
env -u CHROMIUM_DIAGNOSTIC_ALLOW_TS_ERRORS \
  /home/mo/ninja-src/ninja -C out/tryframe-root4 -v \
  chrome/browser/resources/lens/shared:build_ts
```

searchbox `searchbox_mixin.js` 恢复为 18,842 字节、`.d.ts` 为 1,929 字节。NASM
子模块也恢复为 Chromium 记录的精确提交
`358842b6b7dd69b2ed635bef17f941e030a05e5f`；用 host NASM 交叉生成
`dequantize_mmx.o` 通过。GN 重新生成后，host `generate_colors_info` 使用
`/home/mo/uuid-dev-r118` 的开发链接库成功生成。

## R128 构建状态

R127 在 `profile_launch_observer.o` 处停止，完整错误和命令保存在 T490：

```text
/tmp/chrome-build-r127-bg.log
```

R128 已在同一输出树继续执行，日志为：

```text
/tmp/chrome-build-r128-bg.log
```

R128 启动时从 4,125 个 Ninja actions 重新计数；`profile_launch_observer.o` 已通过，
其余动作仍在编译。最终 `chrome` 链接、ELF/SHA-256、guest 打包、三次冷启动、30
分钟/十次加载和四项性能统计必须在该构建完成后另行记录。本报告不提前宣称这些 gate。

## 证据边界与下一步

1. 先等待 R128 全量构建结束；若出现下一处源码或链接阻断，按同样方式建立最小复现、
   单目标回归和新增补丁编号。
2. 成功后执行 `file`、`readelf -h`、SHA-256 和 `scripts/t490/package_chromium_binary.sh`，
   保存 package manifest。
3. 使用正式 2 GiB、AArch64 QEMU 纯 TCG、Weston/native Wayland 和默认
   Browser → Zygote → Renderer 参数做冷启动/稳定性复核。TCG 期间只验证接口、稳定性和
   采集器，不把它写成 KVM 性能收益。
4. 只有真实 renderer ready、首帧严格判据和 guest RSS/PSS/USS 快照都有效时，才启动
   before/after 各五轮统计；缺失事件继续标记为 invalid。

