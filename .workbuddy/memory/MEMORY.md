# 中电杯项目长期记忆（索引）

## 初赛提交范围（用户决定，2026-10-14，后续整理必须遵守）
- WSL2 仅用于测试阶段验证，WSL2 脚本、证据、复现说明与验证报告一律不进入初赛提交材料。
- 正式材料仅面向 T490 原生 Linux；Windows 自动化、传输恢复脚本和本机配置不交付。
- 内容尽可能简洁：一份完整且不重复的 T490 证据集、一份完整演示视频、精简技术方案、源码/构建配置及必需运行脚本。
- 历史证据保留在研究归档，整理提交物时不改写原始日志。报名表按用户要求跳过。
- 当前唯一正式包：`E:/02_competition/中电杯/初赛提交材料/xkernel-initial-final.zip`，冻结 `330c5edf`，33,911,406 字节 / 242 文件 / 42 张 PPM / 29 个运行及探针文件，SHA-256 `c118afa43033e56e31665df84d499c2fdc5dbc071679385ba0d08be02a484b2c`。
- 原生 T490 源码构建、平台/干跑、300 秒集成及 guest 回收已通过；这些集成验证属于显示脚本修正前的版本；当前显示修正另经专项短测和包内 README 干跑验证，未重新跑 900 秒整轮。2026-10-14 14:39:35–14:55:22 实际重新 OBS 录制，947 秒原片裁 guest 区域并去掉尾部 2 秒，交付 945 秒 / 1280×800 / 30fps；完整解码通过，录制轮浏览器保持 795 秒、SINGLE_GATE=1。录制轮前三张启动帧未通过，主严格验收仍用所选 615 秒原件。
- 必须区分“加入已有录像”和“实际新录”。当前已替换掉 10-13 归档视频；新录像 SHA-256 `4ae0bd762312a38f53d42c6f8a1ce07bf5fe9cd911e0f9a1e46f9d325b1deff4`，原片和完整来源在 T490 `~/xk6/evidence/2026-10-14_t490-record-complete-1440/`。失败的全屏/小窗口调试片段均不属于提交物。

> 详细过程看 `report/NN` 与当日日志；本文件只留"不能再踩的坑 + 仍有效结论 + 下一步"。
> 2026-10-09 压缩重写（原文件超注入上限）。

## 硬约束与评分
- 赛题六：AArch64 QEMU，`kplat-aarch64`+`qemu_defconfig`；QEMU≥8；评分纯 TCG（无 `-accel`，CPU 为 `cortex-a76`，禁用 `-cpu host`）。
- 设备须含 virtio-gpu-pci/input/blk/net；功能证据**只认 monitor `screendump`**；性能≥5 次中位数+范围+宿主指纹；before/after 须有 git tag。
- 参数单一真源 `scripts/t490/platform.env`（`GRAPHIC=y ACCEL=n MEM=2g SMP=4 VSOCK=n`，输入靠 `--with-input`）。
- 初赛 100：兼容性与移植分析 25（缺口×1/个≤8 ＋ 上游 patch×4/个≤3 ＋ Linux 基线对比 5）｜图形启动与稳定 20 ＋ 浏览器基础功能 20｜性能观测 15｜文档 10｜演示 10（含**完整流程录屏 6**）。决赛另有开源回馈 9。
- 纪律：遇"图形起不来"先读内核能力表（`core/ksyscall/src/dispatch.rs` 251 项、`io/drmdevice/src/card0.rs` ioctl match 表），再定用户态怎么用。

## ⛔ 两次已撤销的误修（最重要的一条教训）
自写探针与内核共用同一错误假设 ⇒ 自洽变绿，而标准 libdrm 必落空。均已回退（`scripts/t490/p2_revert.sh`；回退后 `card0.rs` 与 HEAD 逐字节一致）。
- **误修 A（属性编号）**：曾改 `0xAA→0xA8`、`0xAC→0xAA`；**HEAD 原值才对**。uapi 真值：`0xA8`=MODE_ATTACHMODE（弃用）、`0xAA`=MODE_GETPROPERTY、`0xAC`=MODE_GETPROPBLOB。改坏后真实 libdrm 发 `0xc04064aa` 内核只认 `…a8` ⇒ errno=95 ⇒ 读不到属性名 ⇒ `plane->type=WDRM_PLANE_TYPE__COUNT` ⇒ `drm_plane_create()` 静默丢弃 ⇒ **这才是 `Failed to find primary plane` 的直接原因**。
- **误修 D（GETPLANE 结构体）**：曾 32B→48B，**是错的**。标准 uapi = 6×u32＋u64 = **32 字节**。机器证据 `DRM_IOCTL_MODE_GETPLANE=0xC02064B6`（`scripts/t490/abi_probe.c` 宿主+aarch64 双编译器）。weston6 同报该错 ⇒ D 与 A 独立。
- **铁律**：`io/drmdevice` 的 uapi 需系统核对（**编号 + 结构体字段/长度**双维度）；**任何内核算术改动必须用真实 libdrm/标准头文件验签，禁用自写探针自证**。

## 内核 DRM 缺口
- **缺口 C（待评估）**：sysfs 无 `/sys/class/drm`（`/sys/class` 只有 `graphics`）⇒ 经 libudev 找设备的现代合成器起不来；正解是内核补 sysfs 设备模型。正落在"配置…文件系统…所需内核能力"。
- **缺口 E（候选）**：`GETCONNECTOR` 报 `count_props=0`，而 `OBJ_GETPROPERTIES` 对同一 connector 返回 1。
- 未实现 ioctl：`MODE_ADDFB(0xAE)`、`GETFB(0xAD)`、`SETPLANE(0xB7)`、`OBJ_SETPROPERTY(0xBA)`、`CURSOR/CURSOR2(0xA3/0xBB)`、`GET/SETGAMMA(0xA4/0xA5)`。

## Weston 链路（report/30）
- 层 1–4（设备路径前缀／`/run` 空壳 socket 骗过 `[ -S ]`／LD_PRELOAD 逐符号／Weston14 经 libudev 查 `/sys/class/drm/<name>`）**已由「内核 sysfs 投射 + 真实 seatd」真实解决，shim 全拆**。
- 层 5 connector/EDID/Pixman renderer 就绪（`using /dev/dri/card0` ✅）；层 6 `drm_plane_create` 静默失败 = 误修 A，已回退。
- 镜像 `images/agentos-weston.img`（weston 全家桶）。**已排除归因**（勿再试）：GETPLANE ABI、会话/seatd、设备发现、IN_FORMATS blob 格式。
- 定位工具：`scripts/t490/weston_sim.c`（真实 libdrm 复现 plane 创建）+ `iocspy.c`（LD_PRELOAD 只观测不伪造）。

## T490 运行陷阱
- `mo@192.168.1.217`（主，2026-10-05 起）／`10.249.63.140`（备），密钥 `C:\Users\12697\.ssh\id_ed25519_t490`。远端 `~/x-kernel`（构建）、`~/xk6`（脚本+证据）。
- 本机 Bash 先加 PATH：`/c/Users/12697/.workbuddy/binaries/PortableGit/versions/1.2.0/usr/bin:/usr/bin:/bin:/c/Windows/System32`；`python` 不在 PATH。
- ⛔ **非交互 SSH 的 PATH 不含 `~/.cargo/bin`** ⇒ rustc 落到系统 1.93.1，而 `~/x-kernel/rust-toolchain.toml` pin 1.95.0 ⇒ 假故障 `error[E0658]: use of unstable library feature cfg_select` + `PLATFORM_NOT_COMPLIANT`。**任何构建/干跑前先** `export PATH="$HOME/.cargo/bin:$HOME/qemu-root/usr/bin:$PATH"`。修正后 kernel.bin 仍 `7584653b…`（构建可复现）。
- **VNC 演示路线**：`--qemu-args '-display vnc=<T490 LAN IP>:0'` ⇒ 端口 5900；与 `-serial mon:stdio` 并存（合规 15/15），`-vga none`+virtio-gpu-pci 下**有真实画面**。⚠️ 绑 LAN IP 无密码 ⇒ 录完立刻停 QEMU。工具 `scripts/vnc_grab.py`（纯标准库最小 RFB 客户端，`--probe`／`--frames N`）。
- **OBS（T490 已装 32.1.0）**：插件齐（`linux-pipewire.so`/`linux-capture.so`/`obs-x264.so`），`libx264-165` 已装。⛔ **profile 无法无头生成/校验**（`QT_QPA_PLATFORM=offscreen obs` 报 `Unable to open X display`、`Loading module`=0，只留空 `global.ini`；正解 `xvfb-run` 但未装 Xvfb）⇒ **不要手写 `basic.ini`**，让 OBS 先跑一次再改真实文件。键名陷阱：`RecFormat2`（非 `RecFormat`）、编码器 id `obs_x264`（非 `x264`）；`Profile`/`SceneCollection` 未核实。
- **`git add -f <目录>` 会递归强制暂存该目录下所有被 ignore 的文件**（只加某类须逐路径 add）。
- **`git check-ignore` 返回码取决于跟踪状态**：已跟踪→rc=1 无输出；未跟踪→rc=0 并打印规则。所以 rc=1 **不能**读成"规则失效"。
- **evidence 入库原则**：判据轮与演示轮 screendump **都入库**（`git add -f` 须显式写路径），只有纯诊断轮留 T490。⚠️ 漏交排查法 = **对"工作区 glob 出的 ppm 集合"与 `git ls-files` 做差集**（git 不跟踪空目录，看目录是否存在会误判）。Git Bash `sha256sum` 输出 `<hash> *path`，比对前归一化。
- 沙箱：含"通配符+删除循环"的脚本会被 SIGTERM（改 python 驱动）；**`sleep` 超前台超时也会 SIGTERM** → 长等待用 `run_in_background` 或拆 ≤100 s。

## agentos 镜像与判据坑（report/25、27、26）
- guest = **agentos kiosk 镜像**（Alpine 3.22 + Xorg 1.21.1.19 + jwm + chromium）；远端 `disk.img`、基准 `~/x-kernel/images/agentos-disk.img`。
- ⚠️ 该镜像**没有 `/etc/profile.d/99-autostart.sh`** ⇒ `/root/autorun.sh` 从不被拉起（"静默空跑"）。已做成 `t490_round.sh` 4a 步注入 `guest-autostart.sh` + 读回自证。**换新镜像第一件事就是确认这个钩子。**
- x-kernel PID1 是 `/bin/sh --login`（不跑 `/etc/inittab`）；镜像 `x11-session` 把 Xorg 日志重定向到**不存在**的 `/dev/ttyAMA0` ⇒ X11 走 `scripts/t490/autorun_x11.sh`（`-logfile /root/xorg.log -logverbose 7`）。
- **X11 阻塞（已定位，备选路线）**：`card0.rs:818` DrmModeCreateDumb **只收 bpp==32**，而 modesetting 在 glamor 不可用时强制 ShadowFB、前缓冲 24bpp(RGB888) ⇒ `ScreenInit failed` ⇒ QEMU 恒 `Display output is not active.`。**未闭环**（Xorg 未点名 CreateDumb）⇒ **不得当成已证**。
- 判据坑：`pgrep -x Xorg` 在本 guest **恒空** → 用 `/proc/<pid>`；**socket 存在 ≠ Xorg 可用**（约 7 s 假可用窗）→ 用 `xset q` 功能门禁。`/dev/shm` 是 **0 容量**，`remount,size=512m` 报成功但不生效。

## 官方测试页与判据
- `scripts/testpage/{index,interaction,layout}.html` 三页互链 ⇒ **必须整目录注入** `/usr/share/html-test/`。注入器 `t490_inject_pages.sh`（写盘 + debugfs dump 回读 cmp）。干跑 **19/19**，判据自检 **28/28**。
- 判据要点：不能复用 legacy；**`index` 不宜双帧差异**（纯静态，0 差异≠renderer 死，看结论条颜色）；**`interaction` 必须真实键鼠输入**（未点击灰、点击后绿底）；**`layout` 结论条在整页 y≈1450**，1280×800 首屏看不到。
- 参考图 `scripts/testpage/reference/ref-official-{index,interaction,layout}-{1280x800,640x480}.png` 是 `ppm_assert.py` 常量来源。

## 进度与下一步（2026-10-09）
- 单进程初赛路线已成形：功能 `2026-10-02_t490-single-initial-r5`（strict_fail=0、7/7×10）；交互 `…interaction-single-e2e-r20`（6/6＋回显 hello x-kernel＋计数 1）；布局 `…layout-e2e-r21`（几何 5/5）。性能 `measure-single-perf3`（5 轮 median 75.0 s／180.2 s）。提交索引 report/42；手动清单 report/45；**权威合规核对 = report/49**。
- 内核指纹：`dcb862c9…`(r5/perf3)、`7584653b…`(r20/r21/current)；镜像 `bb25e0b2…`；overlay `56dba17c…`。补丁 17 个（0001–0018 缺 0008）；`0011`/`0013` 内容已被 `0018`/`0017` 覆盖 ⇒ 勿重复应用。上游 MR !831 已合并。
- 提交前合规：内核 `git_dirty` 根因已消除（T490 41 项改动 10-05 提交为 5 commit：`0ba22d2`/`707ada7`/`670f80d`/`aff4f00`/`2a1b101`，工作区 CLEAN）；**仍需重建内核记录新 `git_commit`+`config_sha256`**。旧横幅 `c2eabd52…`/`128e17a1…` 对应归档前脏树。
- 术语：`git_commit`（仓库 HEAD）与 `kernel.bin sha256`（镜像）是两个量，report/41 曾混用。
- 已推：主仓库 GitHub `main`→`cd93f9c` + 分支 `codex/initial-round-single-process`；内核 Gitee `https://gitee.com/mofan0810/x-kernel` 分支 `t490-chromium-runtime`（=`2a1b101`）。⚠️ 该 Gitee 是 openkylin/x-kernel **完整 fork**，本地 main 与远端非 FF ⇒ **绝不能推 main**，只推新分支。318 MB 镜像走 GitHub Release（本机无 `gh`，用户网页上传）。
- **待办（report/49 §九）**：P0 完整流程录屏／根 README；P1 把 `docs/报名资料/`（仅留赛题六）与 `.workbuddy/memory/` 移出提交分支、README 登记 Gitee 分支+基线 tag+镜像地址、修 `.gitignore`/`AGENTS.md` 的 ppm 失实表述；P2 正式技术方案文档／before-after 配对测量／清 `round-0*.log` 空文件；P3 patches README 标"0008 未产出"。
- **红线**：用户态 flags/shim/测试页不得写入优化收益表；评分数据不得混 KVM/HVF；判定只认归档文件不凭报告转述。
- QEMU 显示已修正：`platform.env` 固定1280×800；GTK在guest启动前隐藏菜单并固定内容区（不含标题栏），桌面默认gtk、SSH无桌面默认none，显式用 `QEMU_DISPLAY=gtk|none`。T490 150秒和最终75秒窗口短测、90秒无窗口补测通过，原始PPM尺寸已核对；显卡初始化前640×480帧被门禁如实拒绝。六个最终运行文件已同步到 `~/xk6/scripts`，旧文件备份于 `~/xk6/tmp/display-script-backup-20261014-1521`。
