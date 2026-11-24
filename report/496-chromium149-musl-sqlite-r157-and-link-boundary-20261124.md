# Chromium 149 SQLite 独立修复与最终链接边界（2026-11-24）

## SQLite 单目标结果

最终链接曾报告：

```text
undefined symbol: sqlite3Analyze
undefined symbol: sqlite3Reindex
```

当前 `third_party/sqlite/sqlite_chromium_configuration_flags.gni` 同时定义了：

```text
SQLITE_OMIT_ANALYZE
SQLITE_OMIT_REINDEX
```

但现有 Chromium 对象仍引用这两个 SQLite 入口。R157 删除这两个 omit flag 后，单目标
构建通过：

```sh
ninja -C out/tryframe-root4 -v third_party/sqlite:chromium_sqlite3
```

输出 archive：

```text
out/tryframe-root4/obj/third_party/sqlite/libchromium_sqlite3.a
```

这项修复记录为 [0048](patches/0048-chromium-musl-sqlite-restore-required-ops.patch)。

## 当前边界

SQLite 修复之后，重新生成整个 GN 输出树会因为 root Skia/V8 诊断条件变更触发约 28k
动作重编。为避免把长时间全树重编误当成有效链接结果，R159 已停止在新的动作树早期，
T490 没有活动 Ninja 进程。R133 的 377/377 编译完成证据仍然有效，最终 `chrome` ELF
仍未生成。

剩余符号和下一步入口继续以 [report 495](495-chromium149-musl-link-symbol-inventory-r156-20261124.md) 为准；正式稳定性和性能
指标不因 SQLite 单目标通过而改变，仍为 `0/4`、`0/0`。

