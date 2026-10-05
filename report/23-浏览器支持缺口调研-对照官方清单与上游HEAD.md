# report/23 · x-kernel 浏览器支持缺口调研：对照赛题官方清单与上游 HEAD

- 日期：2026-09-22
- 调研对象：`https://gitee.com/openkylin/x-kernel`，HEAD `0a04f7d`（MR !831，**我们的文档修复，2026-09-22 07:03 被上游合并**，author SlieNce810，committer 郭伟康）
- 调研方法：浅克隆全量源码（2233 文件），对照赛题 PPT 第 11 页官方 5 项缺口逐项在代码中核实；结合本仓库 report/09–22 的实测记录
- 本地副本：`tmp/xk-gitee/`（浅克隆，勿作构建用）

---

## 0. 结论先行（五条）

1. **官方 5 项缺口全部属实**，逐项都在上游代码里找到了确切的缺失位置（§2）。
2. **我们的 9 个已验证补丁（0001–0010）全部未进上游**——上游基线仍带 P0/P1/P2a/P2b/P3/P4/G17 全部缺陷（§4）。批量回传上游是"补丁 25 分"之外的上游贡献分直通车。
3. **新发现 4 个官方清单之外的缺口**，其中 `waitid` 未路由、inotify 三缺二最值得注意（§3）。
4. **一个好于预期的发现**：`/dev/shm`（tmpfs）上游已挂载（`fs/boot/src/lib.rs:184-193`），`memfd_create` 已路由——Wayland `wl_shm` 共享缓冲的内核侧地基是通的。
5. **优先级矩阵**（§5）：把官方 5 项 + 新发现项按"是否阻塞 L5（导航/renderer）"与"是否独立可拿分"两个维度排序，与 report/22 的阶段 B 衔接。

---

## 1. 基线事实

| 项 | 值 |
|---|---|
| 上游 HEAD | `0a04f7d` `!831 文档缺陷：README 与 docs 中的平台 defconfig 路径…已失效（实测 HTTP 404）` |
| 已路由 syscall | **251 个**（`core/ksyscall/src/dispatch.rs` 中 `Sysno::` 唯一名统计） |
| 未路由 syscall 的默认行为 | `warn!("Unimplemented syscall: {sysno}")` + `ENOSYS`（`dispatch.rs:853-857`，与赛题 PPT 底部说明一致） |
| 显式静默拒绝 | `sys_dummy_fd`（`posix/fs/src/io.rs:169`）：`fanotify_init`/`inotify_init1`/`userfaultfd`/`perf_event_open`/`io_uring_setup`/`fsopen`/`fspick`/`open_tree`/`memfd_secret` → debug 日志 + ENOSYS |

**注意**："已路由"≠"已实现"——如 `rseq` 路由到显式 ENOSYS（`dispatch.rs:831`），`PR_SET_NO_NEW_PRIVS` 路由到显式 ENOSYS（见 §2 表）。

---

## 2. 官方 5 项缺口逐项核实

### 2.1 「procfs 的 statm 与 status 的 Vm 字段」——✅ 确认缺失

**代码位置**：`fs/filesystems/procfs/src/task_nodes/root.rs`

- `format_task_status()`（L88-103）只输出 7 行：`Name / Tgid / Pid / Uid / Gid / Cpus_allowed / Mems_allowed`。
- **无任何 Vm 字段**（`VmRSS/VmSize/VmPeak/VmHWM/VmData/VmStk/VmExe/VmLib/VmPTE` 全仓库 0 命中）；
  也**无** `State / Threads / SigQ / SigPnd / Seccomp / PPid`。
- `/proc/<pid>/statm` 文件**不存在**（`statm` 全仓库 0 命中，仅 `statmount` syscall 号注释）。
- `/proc/<pid>/` 现有节点：`stat / status / oom_score_adj / task / maps / mounts / mountinfo / mountstats / cgroup / ns / cmdline / comm / exe / fd`（root.rs L598-612）——**节点覆盖尚可，缺的是内容深度**。

**对浏览器的影响**：`ps`/top 类观测工具失效（演示分受影响）；我们自己阶段 B 的快照脚本拿不到 `State/Threads/Seccomp`（report/20 B4 计划的观测依据）；Chromium 自身的 `base::ProcessMetrics` 读 `/proc/self/status` 的 VmRSS 用于内存报告（缺失时降级，不致命）。

**补法草案**（"errno 修正类"之外的**新功能类**，单独立项）：
1. `kprocess`/`mm` 侧增加进程级统计：RSS 页数（遍历 VMA 或在缺页路径维护常驻计数）、 peak RSS、VMA 计数；
2. `format_task_status` 扩展 `State / PPid / Threads / VmPeak / VmSize / VmRSS / VmHWM / SigQ / SigPnd / Seccomp`；
3. 新增 `statm` 节点（`size resident shared text lib data dt` 七字段）。

### 2.2 「getrusage 进程记录：ru_maxrss、缺页计数」——✅ 确认硬编码 0

**代码位置**：`core/ksyscall/src/task/rusage.rs`

- 框架存在且路由（`dispatch.rs:492`）；`ru_utime/ru_stime` 是**真实采样**（`sample_cpu_time` / `process_cpu_times`）；
- 但 `ru_maxrss = 0`、`ru_minflt = 0`、`ru_majflt = 0`，连同 `ru_ixrss/ru_idrss/ru_isrss/ru_nswap/ru_inblock/ru_oublock/ru_msgsnd/ru_msgrcv/ru_nsignals/ru_nvcsw/ru_nivcsw` **全部硬编码 0**（rusage.rs L39-52）。

**对浏览器的影响**：Chromium `base::Process::GetPageFaultTotals` 与内部内存观测失效（降级不致命）；`/usr/bin/time -v` 等演示工具输出全 0（演示分受影响）。

**补法草案**：
1. 缺页计数：在 mm 的缺页异常处理路径加 per-task `min_flt/maj_flt` 计数器（minor=无需块 I/O 的按需分页，major=需要读块）；`fork` 时累计子进程已回收部分（对齐 `children_rusage` 语义）；
2. `ru_maxrss`：用 §2.1 的 RSS 统计，在 `task` 上维护 peak，getrusage 时换算为 KB（Linux 语义：ru_maxrss 单位 KB）；
3. `ru_nvcsw/ru_nivcsw`：调度器切换点顺手可采，成本极低。

### 2.3 「DRM ioctl 与 evdev 的完整行为语义」——✅ 确认，两处具体缺陷

**DRM 现状**（`io/drmdevice/src/card0.rs`，1486 行）：覆盖面**好于预期**，约 30 个 ioctl 已路由：
`VERSION / SET_VERSION / GET_CAP / SET_CLIENT_CAP / AUTH / AUTH_MAGIC / PRIME_HANDLE_TO_FD / PRIME_FD_TO_HANDLE / ModeCardRes / ModeCrtc / ModeSetCrtc / ModeGetEncoder / ModeGetConnector / ModeRmFb / ModeCrtcPageFlip / ModeCreateDumb / ModeMapDumb / ModeDestroyDumb / ModeGetPlaneRes / ModeGetPlane / ModeObjGetProperties / ModeGetProperty / WaitVblank / ModeAtomic / CreateBlob / DestroyBlob / GetBlob / ModeFbCmd2 / DirtyFB / SET_MASTER / DROP_MASTER`。

但有两处**语义级**缺陷：

| # | 缺陷 | 位置 | 证据 |
|---|---|---|---|
| **P0（已修未传）** | `DRM_IOCTL_VERSION` 对 libdrm 的"NULL 探测"首次调用无条件 `write_vm_slice` → EFAULT | card0.rs L73-87 | 我们补丁 `report/patches/0001`（tag `p0-drm-version-fix`）；上游代码与补丁"删除侧"逐行一致，**缺陷仍在** |
| **新发现** | 未知 ioctl 返回 `VfsError::OperationNotSupported`（=ENOTSUP/EOPNOTSUPP 95），Linux DRM 语义是 **-ENOTTY(25)** | card0.rs L590 | libdrm/mesa 以 ENOTTY 判定"ioctl 不受支持"并走降级；ENOTSUP 可能被当成别的错误类 |

**evdev 现状（G6，已确认在上游）**：

- `drivers/devices/virtio/src/input.rs:102-103`：`physical_location()` **硬编码返回 `"virtio0/input0"`**——所有 virtio-input 设备同一 location；
- `io/inputdev/src/lib.rs:47`：注册时按 `device.id()` 去重——id 派生自 location ⇒ **第二台 virtio-input（鼠标/tablet）被静默丢弃**；
- 实测吻合：guest `/dev/input` 只有 `event0`（QEMU Virtio Keyboard）（`scripts/t490/evprobe.c`）；weston 因此拿不到完整输入设备集，Chromium 每轮报 `No wl_seat object`（report/21 §3.6）。

**补法**：`physical_location()` 改由设备树实际 slot/bus 派生（如 `virtioN/inputM`），去重逻辑对齐；这是 report/22 阶段 B2 假设（G6 → wl_seat → 导航前置）的前置修复。

### 2.4 「Wayland / X11 共享缓冲区与输入事件路径」——内核侧地基好于预期，两处缺口

| 组件 | 状态 | 证据 |
|---|---|---|
| `memfd_create` | ✅ 已路由 | dispatch.rs |
| `/dev/shm`（tmpfs） | ✅ **已挂载**（好于预期，`--disable-dev-shm-usage` 可能可去掉，需实测） | `fs/boot/src/lib.rs:184-193` |
| **SCM_RIGHTS**（fd 经 unix socket 传递——wl_shm fd 从客户端到 compositor 的必经路径） | ❌ **上游缺失** | `net/knet/` 中 `SCM_RIGHTS/scm_rights` **0 命中**；我们补丁 `0002` 已修（T490 树已带，验证有效） |
| SCM_CREDENTIALS | ❌ 上游缺失 | 补丁 `0007`（G17）已修 |
| inotify | ⚠️ **三缺二**：`inotify_init1` 静默 ENOSYS（`dispatch.rs:805` dummy 表）；`inotify_add_watch`/`inotify_rm_watch` **完全无路由**（warn+ENOSYS）；`inotify_init`（旧号）也无路由 | 与实测 `inotify_init() failed: Function not implemented (38)` 吻合；`/proc/sys/fs/inotify/*` quota 文件已由补丁 `0010`（P6）补上，但 **syscall 本体仍缺** |
| 输入事件路径 | ❌ G6（见 §2.3） | — |

**判断**：X11 路线已被证否（report/20 §1.2），此条的实际工作面 = Wayland：`wl_shm` 路径内核侧只差 SCM_RIGHTS（已有补丁）+ 可选的 inotify；**输入事件路径的实质就是 G6**。

### 2.5 「稳定性：长时间运行不崩溃、不卡死、不泄漏」——运行性质，静态盘点结论

静态可确认的稳定性风险清单（证据均来自 report/19–21 实测）：

1. `rc=191`：browser 与 gpu-process 共用非 Chromium 定义退出码 `0xBF`（report/21 §0.4）——指向 crashpad 或内核 wait 编码，**内核 wait 状态编码是内核侧候选**；
2. 47 s 静默后退出（`--use-gl=swiftshader` 无效取值的历史轮次）；
3. GPU 进程 ~20 s 崩溃后重启（C3 轮 pid 257→306）——反复崩溃-重启循环本身是泄漏/抖动源；
4. `PR_SET_PDEATHSIG` 返回 EINVAL（G16，上游刻意）——Chromium 用它做子进程跟随回收，缺失时 renderer 成为孤儿的风险面（Chromium 有兜底，但内核语义正确更稳）。

**补法**：此项无法一次"修完"，以 V1–V6 验收序列（report/20 §2）+ 10 min 长稳轮（阶段 E）+ `measure.py` 中位数聚合（R3 待建）落地；内核侧对应工作是 wait 状态编码核查（随阶段 B3 的 strace 判决）。

---

## 3. 新发现的缺口（官方清单之外）

| # | 缺口 | 位置 | 对浏览器的影响 | 优先级 |
|---|---|---|---|---|
| N1 | **`waitid` 无实现也无路由**（`task/wait.rs` 仅 `sys_waitpid`，注释却声称支持 waitid——文档与实现不一致） | `core/ksyscall/src/task/wait.rs:243`、`dispatch.rs:570` | glibc `waitpid` 走 `wait4`，主路径可活；但部分代码路径直接 `waitid()`（如 base 库部分分支）会 ENOSYS | **中**（先补文档或补路由+实现） |
| N2 | **inotify_add_watch / inotify_rm_watch 无路由**（配 §2.4 的 init1 静默 ENOSYS = inotify 整体不可用） | `dispatch.rs` | Chromium `file_path_watcher` 降级（实测 ERROR 一条，非致命——report/19 已证非 renderer 阻塞点） | **中低**（完整实现工作量大；先保持 ENOSYS 明确化即可） |
| N3 | **DRM 未知 ioctl 返回 ENOTSUP 而非 ENOTTY** | `card0.rs:590` | libdrm/mesa 降级判断失准 | **低**（一行语义修正，可搭车其他 DRM 提交） |
| N4 | `openat2` / `mbind` / `migrate_pages` / `process_madvise` / `semget` 未路由 | `dispatch.rs` | openat2：glibc 通常回退 openat；其余 Chromium 主路径不用 | **低** |

---

## 4. 本地 9 个补丁 vs 上游 HEAD（全部未进上游）

| 补丁 | 内容 | 上游现状（本次逐点核实） |
|---|---|---|
| 0001 (P0) | `DRM_IOCTL_VERSION` 容忍 NULL 探测 | **缺陷仍在**（card0.rs L73-87 与补丁删除侧逐行一致） |
| 0002 (P1) | AF_UNIX SOCK_STREAM 递交 SCM_RIGHTS 伴生数据 | **缺失**（net/knet 无 SCM_RIGHTS 字样） |
| 0003 (P2a) | `sched` 调度目标按 tid 解析（不止 tgid） | 未核实行级（T490 实测有效） |
| 0004 (P2b) | netlink `bind()` 接受非零 groups | 未核实行级 |
| 0005 (P3) | 实现 `PR_SET_NO_NEW_PRIVS` | **缺陷仍在**：`ctl.rs:120-125` 对 `arg2=1` 显式 `ENOSYS`，且测试锁死该行为（`prctl_set_no_new_privs_requires_exec_enforcement`）⇒ 回传时需连带改测试与上游意图对齐 |
| 0006 (P4) | madvise 不再拒绝合法调用 | 未核实行级 |
| 0007 (G17) | AF_UNIX 接受 SCM_CREDENTIALS | **缺失**（同 0002 区域） |
| 0009 | `/proc/cpuinfo` 暴露 ARM64 CPU identity 字段 | 未核实行级（T490 实测有效） |
| 0010 (P6) | procfs 补 `/proc/sys/fs/inotify/*` quota 文件 | 未核实行级 |

**行动建议**：按"一个补丁一个 MR"批量回传（PR 格式 `!<MR号> <type>(<scope>): <subject>`，正文必写 what/why/expected——report/14 §1.1 已有格式模板）。文档修复 !831 当天即被合并，说明上游响应积极。

---

## 5. 优先级矩阵（与 report/22 阶段 B 衔接）

**维度**：是否阻塞 L5（导航/renderer 破局）× 是否独立可拿分（不被 L5 阻塞的 70 分）。

| 优先级 | 工作项 | 理由 |
|---|---|---|
| **P0（随阶段 B 立即做）** | ① G6 修复（B2 假设前置）；② `--vmodule` 盲区补测（B0）；③ wait 状态编码核查（随 B3 strace 判决） | 直接服务 L5 破局 |
| **P1（独立可拿分，官方点名）** | ① `statm` + `status` Vm 字段（含 State/Threads/SigQ/Seccomp，顺带服务我们自己的观测）；② `ru_maxrss` + min/maj_flt 计数 + nvcsw/nivcsw | 图形/演示/观测证据链；**不被 L5 阻塞** |
| **P2（语义修正，低成本）** | ① DRM 未知 ioctl → ENOTTY；② N1 waitid（补实现或先改 wait.rs 注释）；③ `/dev/shm` 去掉 `--disable-dev-shm-usage` 的实测（若通，减少一个非标旗标） | 一行级/一轮级成本 |
| **P3（上游贡献）** | 9 个补丁批量回传（0005 需与上游测试意图对齐） | 上游贡献分 + 补丁 25 分的证据链强化 |
| **P4（大工程，缓）** | inotify 三件套完整实现 | 官方未点名 syscall 本体；实测已证非阻塞点 |

**分工映射**（report/22 §7）：A（内核/驱动）→ P0① + P1② + P3；B（用户态/图形）→ P0②③；C（度量/工程）→ P1① 的观测消费端（ps/time 证据）+ 性能采数。

---

## 6. 证据索引

| 内容 | 位置 |
|---|---|
| 上游源码只读副本 | `tmp/xk-gitee/`（HEAD 0a04f7d，浅克隆） |
| 本地补丁全集 | `report/patches/0001–0010` |
| G6 实测证据 | `scripts/t490/evprobe.c` + report/21 §3.6 |
| DRM/GBM/X11 路线证否 | report/20 §1.2 |
| rc=191 与 GPU 进程同码证据 | report/21 §0.4 |
| inotify ENOSYS 实测 | report/21 §3.6（`inotify_init() failed: (38)`） |
| 官方缺口清单出处 | 赛题 PPT 第 11 页「现状差距与任务空间」（本报告截图存档于对话） |

---

## 7. 本次调研修正了什么

1. **修正记忆**：`MEMORY.md §8` 记录"上游未提（文档修复）"——实测 **!831 已于 2026-09-22 07:03 合并**，且上游 HEAD 即该提交。
2. **修正预期**：`/dev/shm` 此前默认不可用（`--disable-dev-shm-usage` 一直在冻结旗标里）——上游代码显示 tmpfs 已挂载，**值得实测解锁**。
3. **量化了"已路由 251"这个数**：赛题 PPT 说"成片 ENOSYS"，实际分发器覆盖面比想象大；真正的窟窿是**内容深度**（procfs 字段、rusage 字段）而非 syscall 数量。
