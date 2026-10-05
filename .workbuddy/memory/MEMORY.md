# 中电杯项目长期记忆（索引）

> 2026-10-02 两轮压缩：去重 + 收敛已撤销条目。**详细过程一律看 `report/NN` 与当日日志**，
> 本文件只留"不能再踩的坑 + 仍有效的结论 + 下一步"。

## 硬约束与平台
- 赛题六：AArch64 QEMU，`kplat-aarch64` + `platforms/kplat-aarch64/qemu_defconfig`；QEMU ≥8；评分纯 TCG（命令行无 `-accel`、`-cpu cortex-a76`）。
- 设备须含 virtio-gpu-pci / virtio-input / virtio-blk / virtio-net；功能证据**只认 monitor `screendump`**；性能 ≥5 次中位数+范围+宿主指纹；before/after 必须有 git tag。
- 参数单一真源：`scripts/t490/platform.env`（现固定 `GRAPHIC=y ACCEL=n MEM=2g SMP=4 VSOCK=n`，输入靠 `--with-input`）。

## 评分表与方向锚点（**勿再偏**）
- 初赛满分 100：**系统兼容性与移植分析 25（内核态）= 缺口×1/个（≤8）+ 上游 patch×4/个（≤3 项）+ Linux 基线对比 5**；图形启动与稳定性 20 + 浏览器基础功能 20（用户态）；性能观测 15；文档 10；演示 10。决赛另有开源回馈 9。
- ⇒ **内核态是分值最高的单项，也是开源回馈的唯一来源**，但**不是"只能内核态"**；赛题原文要求"配置图形/输入/FS/网络所需**内核能力**"⇒ 内核能力是图形分项的前置。
- **纪律**：遇"图形起不来"，**先读内核能力表**（`core/ksyscall/src/dispatch.rs` 251 项 + `io/drmdevice/src/card0.rs` 的 ioctl match 表），再决定用户态怎么用；不要先在用户态堆启动脚本倒推内核。
- 官方意图路线 = **Weston + DRM backend + Chromium Ozone/Wayland**（defconfig 明写 `KFEAT_DRIVER_VIRTIO_GPU/INPUT=y`，仓库自带 `uapps/weston-start/xk-weston-start`）。旧 agentos 镜像无 weston/seatd/Xwayland（纯 X11）⇒ 已转向 Weston。

## 内核 DRM 缺口

### ⛔ 两次已撤销的误修 —— 最重要的一条教训
两次都是**自写探针与内核共用同一个错误假设 ⇒ 自洽变绿**，而标准 libdrm 必然落空。**均已回退**（`scripts/t490/p2_revert.sh`；回退后 `card0.rs` 与 HEAD 逐字节一致）。
- **误修 A（属性编号）**：曾把 `0xAA→0xA8`、`0xAC→0xAA`；**HEAD 原值才对**。
  uapi 真值（guest 自带 `drm.h:1159-1164`）：`0xA8`=`MODE_ATTACHMODE`(deprecated，从未工作)、
  **`0xAA`=`MODE_GETPROPERTY`**、**`0xAC`=`MODE_GETPROPBLOB`**。
  改坏后真实 libdrm 发 `0xc04064aa` 而内核只认 `0xc04064a8` ⇒ `errno=95` ⇒ 读不到属性名
  ⇒ `plane->type = WDRM_PLANE_TYPE__COUNT` ⇒ `drm_plane_create()` 静默丢弃 ⇒ 无 plane
  ⇒ **这才是 `Failed to find primary plane` 的直接原因**。
- **误修 D（GETPLANE 结构体）**：曾把 `drm_mode_get_plane` 从 32B 扩到 48B，**是错的**。
  标准 uapi = **6×u32 + u64 = 32 字节**，**无** `crtc_x/crtc_y/x/y`（那是 `drm_mode_set_plane` 的字段）。
  机器证据：`DRM_IOCTL_MODE_GETPLANE=0xC02064B6`（32B）vs 48B 复算 `0xC03064B6`（`scripts/t490/abi_probe.c`，宿主+aarch64 双编译器）。
  注：weston6（p3 之前=正确内核）同样报该错 ⇒ D 是**独立**缺陷，与 A 无关。
- ⇒ **铁律**：`io/drmdevice` 的 uapi 需一次系统性核对（**编号 + 结构体字段/长度**双维度）；
  **任何内核算术改动必须用真实 libdrm / 标准头文件验签，禁止用自写探针自证。**

### 待评估 / 未实现
- **缺口 C（待评估）**：**sysfs 无 `/sys/class/drm`**（`/sys/class` 只有 `graphics`）⇒ 经 libudev 找设备的现代合成器无法启动；正解是内核补 sysfs 设备模型（工作量大）。正落在"配置…文件系统…所需内核能力"里。
- **缺口 E（候选）**：`GETCONNECTOR` 报 `count_props=0`，而 `OBJ_GETPROPERTIES` 对同一 connector 返回 1。
- 未实现 ioctl：`MODE_ADDFB(0xAE)`、`MODE_GETFB(0xAD)`、`SETPLANE(0xB7)`、`OBJ_SETPROPERTY(0xBA)`、`CURSOR/CURSOR2(0xA3/0xBB)`、`GET/SETGAMMA(0xA4/0xA5)`。

## Weston 链路（六层，report/30）
- 层 1–4（设备路径前缀 / `/run` 持久化致空壳 socket 骗过 `[ -S ]` / LD_PRELOAD 逐符号解析 / Weston 14 先经 libudev 查 `/sys/class/drm/<name>`）
  **已由「内核 sysfs 投射 + 真实 seatd」真实解决，shim 已全部拆除**（见阶段2）。
- 层 5：connector/EDID/色彩/Pixman renderer 全就绪（`using /dev/dri/card0` ✅）。
- 层 6：`drm_plane_create` 静默失败 ⇒ **已定位 = 误修 A，已回退**。
- 镜像 **`images/agentos-weston.img`**（weston 全家桶，无 shim）。
- **已排除的归因**（勿再试）：GETPLANE ABI、会话/seatd、设备发现、IN_FORMATS blob 格式。
- ⚠️ Weston 在该失败点有**多条静默路径**（源码 `~/xk6/tmp/weston-14.0.2`）：`drm.c:1325 create_sprites()` 两处裸 `continue`；
  `drm.c:1213 drm_plane_create()` 的 `goto err_props`（`WDRM_PLANE_TYPE__COUNT`，**不打日志**）与
  `drm_plane_populate_formats()<0`（同样不打日志；kms.c:569 对**重复 modifier** 返回 -1）。
- **定位工具（已就绪）**：`scripts/t490/weston_sim.c`（用真实 libdrm 原样复现 plane 创建每一步）+ `iocspy.c`（LD_PRELOAD **只观测不伪造**）。

## T490 与运行陷阱
- `mo@192.168.1.217`（2026-10-05 起主用；`mo@10.249.63.140` 为备选），密钥 `C:\Users\12697\.ssh\id_ed25519_t490`。远端：`~/x-kernel`（构建）、`~/xk6`（脚本+证据）。
- 本机 Bash 先加 PATH：`/c/Users/12697/.workbuddy/binaries/PortableGit/versions/1.2.0/usr/bin:/usr/bin:/bin:/c/Windows/System32`；`python` 不在 PATH。
- 工具链 PATH 须含 `~/.cargo/bin`、`~/qemu-root/usr/bin`、musl 交叉工具链。guest 日志写 `/root/`（`/tmp` 是 tmpfs）。避免 `pkill -f` 自杀。
- 沙箱：含"通配符+删除循环"的脚本会被 SIGTERM（改 python 驱动）；**`sleep` 超前台超时也会被 SIGTERM**（不会自动转后台）→ 长等待用 `run_in_background` 或拆 ≤100 s。

## agentos 镜像与判据坑（report/25、27、26）
- 现行 guest = **agentos kiosk 镜像**（Alpine 3.22 + Xorg 1.21.1.19 + jwm + chromium）；远端 `disk.img`、基准 `~/x-kernel/images/agentos-disk.img`、旧盘备份 `images/pre-agentos-20260922-164822.img`。
- **该镜像没有 `/etc/profile.d/99-autostart.sh`** ⇒ `/root/autorun.sh` 从不被拉起（"静默空跑"）。已做成 `t490_round.sh` 4a 步注入 `guest-autostart.sh` + 读回自证。**换新镜像第一件事就是确认这个钩子。**
- x-kernel PID1 是 `/bin/sh --login`（不跑 `/etc/inittab`）；镜像 `x11-session` 把 Xorg 日志重定向到**不存在**的 `/dev/ttyAMA0` ⇒ X11 走 `scripts/t490/autorun_x11.sh`（`-logfile /root/xorg.log -logverbose 7`）。
- **X11 阻塞（已定位，作为备选路线）**：`card0.rs:818` 的 `DrmModeCreateDumb` **只收 bpp==32**（24/16 → EINVAL，`drmdumbprobe` 实测），
  而 modesetting 在 glamor 不可用时强制 ShadowFB、前缓冲固定 24bpp(RGB888) ⇒ `ScreenInit failed` ⇒ QEMU 恒 `Display output is not active.`。
  **未闭环**：Xorg 未打出点名 CreateDumb 的 (EE) 行 ⇒ 因果是强假设，**不得当成已证**。
  另两处 32bpp-only 约束：`DrmModeFbCmd2`(0xB8) 仅收 XRGB8888/ARGB8888；`drivers/contracts/display` 的 `ScanoutFormat` 只有 `Bgra8888`。
- 判据坑：`pgrep -x Xorg` 在本 guest **恒为空** → 用 `/proc/<pid>`；**socket 存在 ≠ Xorg 可用**（先建 socket、约 7 s 后 DDX 失败才清 ⇒ 十几秒"假可用窗口"）→ 用 `xset q` 功能门禁。
- `/dev/shm` 是 **0 容量**挂载点，`remount,size=512m` 报成功但**不生效**。

## 官方测试页与判据
- `scripts/testpage/{index,interaction,layout}.html` 三页互链 ⇒ **必须整目录注入** `/usr/share/html-test/`。注入器 `t490_inject_pages.sh`（写盘 + debugfs dump 回读 cmp，不一致硬中止）。
- `PAGE_URL` 白名单（拒绝 `..`）+ 注入时烘焙 + 落点自证；干跑 **19/19**，官方页判据自检 **28/28**。
- 判据要点：不能复用 legacy 判据；**`index` 不适合双帧差异**（纯静态，两帧 0 差异 ≠ renderer 死，JS 存活看结论条颜色）；
  **`interaction` 必须真实键鼠输入**（未点击时结论条是灰的，点击后才是绿底）；**`layout` 结论条在整页 y≈1450**，1280×800 首屏看不到。
- 参考图 `scripts/testpage/reference/ref-official-{index,interaction,layout}-{1280x800,640x480}.png` 是 `ppm_assert.py` 判据常量的来源（非从 CSS 反推）。
- ⚠️ 这些文件曾**只在本地仓库**（2026-09-22 才同步到 T490）⇒ 取脚本后必须核对远端哈希。

## 既有内核方向与红线
- 已修 P0 DRM NULL、SCM_RIGHTS、scheduler tgid、netlink groups、no_new_privs、madvise 等；本地补丁尚未全部上游（上游 MR !831 已合并）。
- 旧镜像的 Chromium/Wayland 现象（导航不提交、renderer=0、`rc=191`）**是旧镜像结论**，agentos 镜像上尚未复现到那一层。
- **贯穿全程的红线**：用户态 flags/shim/测试页仅作诊断/过渡/测量，**不得写入优化收益表**；评分数据不得混入 KVM/HVF。

## 进度与下一步（2026-10-05 更新：初赛单进程包已成形，进入提交前人工验证）

**已完成 ✅（单进程初赛路线，report/39–44）**
- 功能候选 `2026-10-02_t490-single-initial-r5`：`SINGLE_GATE=1`、保持 615 s、官方 index 严格像素 strict_fail=0（7/7×10 张）。
- 交互/布局：`..._interaction-single-e2e-r20`（T1–T6/F1 全绿 6/6、回显 hello x-kernel、计数 1）、`..._layout-e2e-r21`（几何 5/5）。
- 性能：`2026-10-02_measure-single-perf3`（5 轮 median 75.0 s / 180.2 s、gate 5/5）；host 观测 `2026-10-02_profile-single`（perf/eBPF 权限失败已如实归档）。
- 提交包索引 report/42；**手动验证清单 report/45**（阶段 A–H：平台合规→功能→三页→输入口径→性能→缺口/补丁→提交包→总口径）。
- **面向初学者的总讲解 = `report/48-项目完整实现讲解-从启动到Chrome运行.md`**（+ 同名 `.html` 可直接预览 9 张 Mermaid）。
  ⚠️ **2026-10-05 已重制**：`.html` 改为**手写版、零外部依赖**（7 张内联 SVG + 12 张语义化表格 + 响应式卡片）。
  旧版依赖 CDN 的 mermaid.min.js，在 IDE 预览面板里加载失败 ⇒ 9 张图退化成源码文本被用户判为"页面异常"。
  **交付类 HTML 的图一律内联 SVG，不要赌外部资源。**
  内容：拆题与评分坐标 → 从启动到运行的 8 阶段流程 → 支撑 Chrome 的内核组件（含 DRM ioctl 编号表、sysfs 关键性）→ 额外补充的四类内容（补丁 / 能力补齐 / 镜像与用户态 / 工具链）→ 两次误修教训 → 上手实践最短路径 + 12 条坑。
  需要"给新人讲一遍项目"或写文档/答辩材料时，**先从这里取骨架**。
- 内核指纹两枚：`dcb862c9…`（r5/perf3）、`7584653b…`（r20/r21）；镜像 `bb25e0b2…`；overlay `56dba17c…`。**补丁 17 个（report/patches，0001–0018 缺 0008，索引见 `report/patches/README.md`）**，上游 MR !831 已合并。
  ⚠️ `0011`（futex PI）与 `0013`（MSG_CMSG_CLOEXEC）的内容**已被 `0018`/`0017` 完全覆盖**（同一改动先后导出两次：先导出补丁、后随归档正式入库）⇒ **不要重复应用**。

**⛔→✅ 4 处「报告 ↔ 归档证据」不一致：口径已全部修正（2026-10-05，report/46 勘误）**
1. report/40 称 r5「心跳 9 对均有变化」→ 归档实为 `心跳=0/9`（九对全同）。**index 纯静态页 0/9 是预期**（README 规则 3），r5 GATE 行不含心跳。report/40 已改。
2. layout 口径：assert JSON 里 `layout_c3_box_model` 归 viewport 组，ppm-summary 严格集（5 项）把 viewport 算入 → 对外统一用 ppm-summary 口径，report/44 已注明。
3. **layout 6/6 结论条证据仍缺位**：r21 的 `layout-top.png` 与 `layout-verdict.png` 同哈希（滚动未发生）、`layout_verdict_pass=False`；report/44 引的 6/6 图实际在 r19。口径已改（注明证据在 r19），**证据补齐待执行 C3 e2e 滚动复跑**。
4. 缺口清单 9 条 > ≤8 口径 → 已收敛为 8 条（含补入 report/44 的 virtio-input 消费缺口）。

**✅ 提交前合规点已解决（2026-10-05 归档时）**
- ~~内核自报 `git_dirty = true`~~ → **根因已消除**：原因是 T490 工作区那 41 项内核改动一直未提交。10-05 已按主题提交为 5 个 commit（`0ba22d2` inotify / `707ada7` input+virtio-input / `670f80d` procfs / `aff4f00` knet / `2a1b101` ksyscall），工作区转 CLEAN。
  **仍需执行**：重建内核并在新证据里记录新的 `git_commit` 与 `config_sha256`（旧横幅的 `c2eabd52…` / `128e17a1…` 对应归档前的脏树；`git status --porcelain` 查不出的这项，现在只有重建后的横幅能证实已消除）。
- 内核构建元数据（区分轮次用）：**r5 = build_time 2026-09-30T03:50:50Z（dcb862c9）**；**r20/r21 与当前构建树 = 2026-10-02T13:21:16Z（7584653b）**。
- **`ConnectionRefused` 噪声定性**：`knet::transport::tcp:447 [KErrorKind::ConnectionRefused]`（约每 5 s 一条）= **当前版 `autorun_single_initial.sh` 的 CDP 就绪轮询**（连 9222 失败产出 `CDP_READY=0`）。r20/r21 同为 `CDP_READY=0`；r5 用旧版 autorun（无 `--remote-debugging-port`）故 0 条。**非故障**。
- **autorun 版本差异**：`scripts/t490/autorun_single_initial.sh` 于 **2026-10-02 22:29** 加入 CDP 支持（`--remote-debugging-port=9222` + CDP_READY 逻辑），晚于 r5（14:44）。⇒ 现在重跑单进程轮得到的配置与 r5 归档不同：`FIRST_NAV_ELAPSED` 60 s（新）/ 75 s（r5 旧版）/ 90 s（CDP 轮）。

**待办（按顺序）**
0. **推送归档（外发，需单独确认）**：本地领先 `main` **35 个提交**（分支 `codex/initial-round-single-process`，含 10-05 的 8 个归档提交）。按用户决定"两个分支都推"：先 `push -u origin codex/initial-round-single-process`，再 `git branch -f main HEAD` + `push origin main`（线性后代可 FF）。318 MB 的 `agentos-disk.img.xz` 走 GitHub Release 附件（本机无 `gh`，走 PAT+curl 或网页手动上传）。
  已完成的归档前置：`.git` 319.82 MiB → **18 MiB**（gc）、evidence 保真修复（`evidence/** -text` + renormalize，384 个文件）、T490 scripts +81 / evidence +257 目录、patches 0014–0018。
1. 按 report/45 逐项手动执行：先修 §1 口径，再 A→H；B1/E1 复跑各约 25/45 min（TCG 禁并发）。
2. 补 C3 layout 滚动轮，把 6/6 结论条证据落入同一目录。
3. 缺口清单收敛为 8 条（含 virtio-input）。
4. 决赛方向（不在初赛宣称）：virtio-input 事件消费（`fs/filesystems/devfs/src/nodes/event.rs`：鼠标暴露成 `mice`、`input_drain_devices()` 取走设备列表、minor 未用 `64+N`；另需 input sysfs 投射 `ID_INPUT*`）、多进程 renderer、30 min 稳定、双窗口、1.5 GiB 线。
5. 候选内核缺口（按需）：`inotify_init()` ENOSYS(38)；`/proc/<pid>/{status,wchan,syscall}` 返回空；`TCP_KEEPIDLE` 仅告警。

**不变的历史结论**：用户态 flags/shim/测试页不得写入优化收益表；评分数据不得混入 KVM/HVF；判定只认归档文件不凭报告转述。
