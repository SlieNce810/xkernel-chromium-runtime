# 内核补丁集索引

本目录保存 x-kernel 为运行 Chromium 所做的全部内核改动。补丁全部由
`git format-patch` 导出，可用 `git am` 依序应用，或用 `git apply` 单独应用。

- **上游基线**：`https://gitee.com/openkylin/x-kernel.git`
- **最终落点**：`c2eabd5` → `2a1b101`（见下表"对应提交"）
- **编号**：`0001`–`0018`，**缺 `0008`**（该编号在早期整理中作废，未使用）

---

## 补丁总览

| 编号 | 主题 | 改动文件数 | 对应 T490 提交 |
|---|---|---|---|
| 0001 | DRM 容忍 `DRM_IOCTL_VERSION` / `DRM_UNIQUE` 的 NULL 指针 | 1 | `8162e8a` |
| 0002 | AF_UNIX `SOCK_STREAM` 投递 ancillary data | 2 | `8efe025` |
| 0003 | `sched` 按 tid 解析目标线程 | 1 | `c6930c2` |
| 0004 | netlink bind 接受非零组播组 | 1 | `031a3b4` |
| 0005 | 实现 `PR_SET_NO_NEW_PRIVS` | 1 | `f8b9224` |
| 0006 | 不再拒绝格式正确的 `madvise` 调用 | 1 | `7b60564` |
| 0007 | AF_UNIX 接受 `SCM_CREDENTIALS` | 1 | `0c611be` |
| 0009 | `/proc/cpuinfo` 暴露 ARM CPU 身份字段 | 1 | `7f77919` |
| 0010 | `/proc/sys/fs/inotify/*` 配额文件 | 1 | `c2eabd5` |
| 0011 | PI futex 返回 `EOPNOTSUPP`（不谎报 ENOSYS） | 1 | —（见下"覆盖关系"） |
| 0012 | 内核内存记账快照（procfs + memspace） | 12 | —（独立，基线 `80b4836`） |
| 0013 | `MSG_CMSG_CLOEXEC` 传递 | 1 | —（见下"覆盖关系"） |
| 0014 | inotify 子系统（Chromium 文件监视） | 10 | `0ba22d2` |
| 0015 | evdev sysfs 投射与 virtio-input 事件消费 | 9 | `707ada7` |
| 0016 | `/proc/stat`、`/proc/uptime`、`/proc/loadavg`、`/proc/meminfo` | 2 | `670f80d` |
| 0017 | AF_UNIX 对端凭据与更多 socket 选项 | 12 | `aff4f00` |
| 0018 | `ppoll_time64`、`PR_SET_PDEATHSIG` 与驱动杂项修复 | 8 | `2a1b101` |

---

## 覆盖关系（重要，避免重复应用）

`0014`–`0018` 是 2026-10-05 把 T490 工作区长期未提交的改动正式入库后导出的，
它们**完整包含**早先单独导出的两个补丁：

| 旧补丁 | 内容 | 现状 |
|---|---|---|
| `0011-futex-pi-unsupported-errno.patch` | `core/ksyscall/src/sync/futex.rs` 的 PI futex 处理 | **已被 `0018` 完全覆盖** |
| `0013-posix-net-msg-cmsg-cloexec.patch` | `posix/net/src/io.rs` 的 `MSG_CMSG_CLOEXEC` 传递 | **已被 `0017` 完全覆盖**（`0017` 是其超集，另含对端凭据处理） |

原因：这两处改动当时只导出了补丁、未曾提交，改动本身一直留在 T490 工作区，
因此 10-05 归档时被同一批提交一并带入。

**应用建议**：以 `0014`–`0018` 为准；`0011`、`0013` 保留仅为记录改动首次导出的时间点
（分别被 `report/34`、`report/20` 引用），**不要与 `0017`/`0018` 重复应用**。

`0012`（内存记账）与上述任何补丁均无重叠，但它基于 `80b4836`，与 `c2eabd5` 有
上下文差异，应用前需先跑 `git apply --check`。

---

## 应用方法

```bash
# 全量应用（按编号顺序）
git am report/patches/00*.patch        # 注意先跳过 0011/0012/0013，见"覆盖关系"

# 单个补丁预检
git apply --check report/patches/0017-feat-knet-af-unix-credentials-and-socket-options.patch

# 推荐的最小复现路径：从 0014 起，覆盖初赛单进程包所依赖的全部内核能力
git am report/patches/001[4-8]-*.patch
```

---

## 质量门禁

`0014`–`0018` 对应的 5 个提交均在 T490 上通过项目自带的 `pre-commit`
钩子（`make fmt` + `make clippy`）。早先的 `0011`–`0013` 未经该钩子。

其中 4 处"改动尚未完成"的位置在归档时按保留痕迹的方式处理，即添加
`#[allow(...)]` 并附说明注释，而非删除代码：

| 位置 | lint | 处理 |
|---|---|---|
| `drivers/integration/kdriver/.../virtio/mod.rs` | `clippy::needless_ifs` | 空 `if` 分支保留为 virtio-input 特判的位置标记 |
| `posix/fs/src/io.rs`（`sys_read` / `sys_write`） | `clippy::let_and_return` | `let` + `return` 形式保留，供 inotify 通知插入 |
| `fs/boot/src/lib.rs`（`create_sys_cpu_entries`） | `clippy::useless_format` | 字面量分支保留以与格式化分支对称 |
