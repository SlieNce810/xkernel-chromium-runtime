# report/21 · 阶段 A 实测：Ozone 运行期三元组定标

- 日期：2026-09-22
- 计划依据：`report/20-渲染闭环后续计划-v3-对齐Ozone官方材料.md`
- 平台：T490 `mo@10.249.63.140`，QEMU 10.2.1 纯 TCG（命令行无任何 `-accel`），内核 HEAD `c2eabd5`
- 基础镜像：`~/x-kernel/images/pkg-installed.img`
  sha256 `bab5c9f5dbf1e4a910bab569635bb9e44fe38c3b8cea94ae8eae4ce3f7a9fdb1`
  （**更正**：此前记录的 `56302b8f…` 有误；镜像内 chromium 实体 249957096 B，
  其自身 sha256 `d7d89bcb466c1d9a7ab209220c8ab997f66c02b77c5e80d3ea10ed64c772a641`）
- 四轮证据：`evidence/2026-09-22_t490-phaseA/{ozone-c0-nogpu-r3, ozone-c1-anglevulkan-r2,
  ozone-c2-angleopengles, ozone-c3-gpuseparate}/`

---

## 0. 结论先行

1. **GL 门禁被打开了。** `--use-gl=angle --use-angle=vulkan`（+ SwiftShader ICD 环境变量）是本 build
   唯一被接受的 GL 实现：`not found in allowed implementations` 与 `gl=none` **双归零**，
   且 ANGLE 的 Vulkan 后端真的执行到了设备选择
   （`ui/gl/angle_platform_impl.cc:52 vulkan_icd.cpp:388 (ChoosePhysicalDevice)`）。
   这是项目史上第一次。

2. **`--use-angle=opengles` 是被拒的**，而且拒绝形态与历史那条一模一样：
   `Requested GL implementation (gl=none,angle=none) not found in allowed implementations:
   [(gl=egl-angle,angle=opengl),(gl=egl-angle,angle=opengles),(gl=egl-angle,angle=vulkan)]`。
   原因不是"不被允许"，而是**旗标词汇表不匹配**：allowed 列表打印的是 ANGLE 内部显示类型名
   （`opengl/opengles/vulkan`），而 `--use-angle=` 的 CLI 取值是 `gl/gles/vulkan`。
   ⇒ 备选组应改用 `--use-angle=gles`（下次单变量复测）。

3. **`GPU_MODEL=separate` 明显优于 `--in-process-gpu`。** 只有把 GPU 拆成独立进程的那一轮
   （C3）才真正出现 `type=gpu-process`：pid 257 运行约 20 s 后崩溃、Chromium 随即重启为 pid 306。
   即"GPU 进程"从此成为一个**可独立观察、有明确退出码**的对象；而 `--in-process-gpu`
   把整条 GPU 栈塞进 browser 进程，历史上会把 browser 一起带走。

4. **`rc=191` 这条线被大幅推进（本轮最重要的单点发现）。** C3 里 browser 报出：
   ```
   ERROR content/browser/gpu/gpu_process_host.cc:1005 GPU process exited unexpectedly: exit_code=48896
   WARNING content/browser/gpu/gpu_process_host.cc:1447 The GPU process has crashed 1 time(s)
   ```
   48896 = **0xBF00**。Linux wait 状态里低 8 位为 0 ⇒ `WIFEXITED` 成立，
   `WEXITSTATUS = 48896 >> 8 = 0xBF = 191`。
   **即 GPU 进程与历史上 browser 的 `rc=191` 是同一个退出码。**
   而上游 `content/public/common/result_codes.h` 里根本没有 191
   （`RESULT_CODE_NORMAL_EXIT=0 / KILLED=1 / HUNG=2 / KILLED_BAD_MESSAGE=3 /
   GPU_DEAD_ON_ARRIVAL=4`，`base::Process::kResultCodeKilledBadMessage=3`），
   上游 `content/gpu/gpu_main.cc` 在 GPU 初始化失败时返回的是 `RESULT_CODE_GPU_DEAD_ON_ARRIVAL`(=4)。
   ⇒ **191 不是 Chromium 定义的结果码**；browser 与 GPU 进程共用同一个未定义码，
   指向一个**共用组件**（crashpad 侧，或内核 wait 状态编码）。这条留阶段 B 用 strace/信号定音。

5. **三元组不是 renderer 的阻塞点 —— "换旗标"这条路的收益已经吃尽。**
   四组实验 `renderer` 计数**全部为 0**，四组截图的主色**完全一致**（`(124,117,114)` 占 33%），
   页面一次都没画出来。把 GL 从"被拒"推进到"接受并初始化"之后，renderer 依然不存在。

6. **本轮的四个配置都没有复现 browser 静默退出**（`已退出 rc=` 全部为"无"）。
   历史上"40–74 s 静默退 191"出现在 `--use-gl=swiftshader`（无效取值）的轮次；
   换成有效 GL 取值或 `--disable-gpu` 后不再复现。这与结论 4 的"191 来自 GPU 栈"互相印证。

---

## 1. 本轮修掉的真缺陷（每条都有实测证据，不是推测）

阶段 A 的价值有一半在"把测量管线本身修对"。以下 D1–D5 都是先用实测现象定位、再修、再回归验证的。

| # | 缺陷 | 实测现象（证据） | 修法 |
|---|---|---|---|
| **D1** | `snapshot()` 对每个进程 fork `tr`/`awk`/`grep` | C0 轮：单次迭代 **13–16 s**（t=0 在 04:16:48，t=30 在 04:18:09）⇒ `j=75` 需 ~225 s，而会话只有 180 s，**观察循环被整段砍掉** | 改为纯 shell 内建、**零 fork**（`read` 读 `cmdline`/`stat` + 参数展开切字段 + `case` 认 type）；合成 `/proc` 夹具单元测试 **7/7 通过** |
| **D2** | 观察窗用计数器 `j`（每次 +5）而不是墙钟 | 同上；隐含假设"每轮迭代恰好 5 s" | 改**墙钟**约束，并在每次快照**之后**再判一次截止（一次慢快照不至于吃掉整轮） |
| **D3** | 轮后小节在 guest 内重复做宿主能做的事；A0 还要在 guest 内**再启动一个 chromium** | C1 轮：窗口吃满、`§6.1/6.2/6.9` 与 A0 **全部未执行**（三轮连续复现） | 全部移到宿主侧 `round_assert.sh`；A0 改 `RUN_A0` 开关，**默认关** |
| **D4** | `round_assert.sh` 用**首图尺寸**做 `--expect-size` | 同一轮内首帧 640×480、其余 1280×800（weston 中途设模式）⇒ 正确的 1280×800 帧被记成"尺寸不符" | 改用**众数尺寸**；非众数帧只记"尺寸不符"，不计入渲染失败 |
| **D5** | 残留占位符检测正则 `__[A-Z_]+__` 不含数字 | 新增的 `__RUN_A0__` 会**漏检**，未替换的占位符会被当合法取值传进 chromium | 改 `__[A-Za-z0-9_]+__` |
| 附 | `pull_guest_logs.sh` 默认清单缺本轮新增的 4 个日志 | 会 dump 出 0 字节，被误判成"guest 根本没写日志" | 补进默认清单 |

修完后四轮的观察窗分别跑到 **80/84/81/82 s**、快照 **10/10/10/9** 次，`6.1/6.2 已在宿主侧完成`
与 `done` 标记齐全 ⇒ 采样管线稳定可复现。

---

## 2. 实验矩阵与结果

四轮均为 `--ozone-platform=wayland`、`--no-sandbox`、`--disable-dev-shm-usage`、
`--disable-gpu-sandbox`、`--disable-crash-reporter`、`--enable-logging=stderr --v=1`，
会话 180 s / interval 30 s / 观察窗 80 s。

| 组 | GL 变体 | GPU 模型 | GL 拒绝 | `gl=none` | ANGLE/VK 行 | **renderer** | **gpu-process** | zygote | utility | crashpad | browser 退出 | 观察窗 | 主色 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **C0-r3** | `--disable-gpu` | in-process | 0 | 0 | 0 | **0** | 0 | 1 | 5 | 19 | 无 | 80 s / 10 次 | (124,117,114) 33% |
| **C1-r2** | `angle` + `vulkan` + ICD | in-process | **0** | **0** | **3** | **0** | 0 | 2 | 5 | 15 | 无 | 84 s / 10 次 | (124,117,114) 33% |
| **C2** | `angle` + `opengles` | in-process | **1** | **1** | 0 | **0** | 0 | 2 | 5 | 14 | 无 | 81 s / 10 次 | (124,117,114) 33% |
| **C3** | `angle` + `vulkan` + ICD | **separate** | **0** | **0** | **6** | **0** | **3** | 2 | 4 | 14 | 无 | 82 s / 9 次 | (124,117,114) 33% |

四轮的像素判据一致：`ppm=6  严格集未通过=6  尺寸不符=0  心跳=0/5`。

**逐条判据的证据（阶段 A 只看三条）**

- **① GL 错误**：C0/C1/C3 的 `not found in allowed implementations` 与 `gl=none` 均为 **0**；
  C2 各 1 次，原文见 §0.2。C1/C3 的 `ChoosePhysicalDevice` 警告原文：
  ```
  WARNING ui/gl/angle_platform_impl.cc:52 vulkan_icd.cpp:388 (ChoosePhysicalDevice):
          Preferred device ICD not found. Using default physicalDevice instead.
  ```
  ⚠️ 注意：日志里 **`SwiftShader` 字样 0 次**，且警告说"偏好 ICD 未找到、改用默认物理设备"。
  即 `VK_ICD_FILENAMES` 指向的 SwiftShader ICD **没有被 ANGLE 当作偏好设备采用**；
  ANGLE 走的是"默认 physicalDevice"。这条要在阶段 B 里核实（是否真的拿到了可用设备）。
- **② browser 存活**：四轮 `browser 主 pid` 分别为 188/180/180/188，**全部无 `已退出 rc=`**，
  且观察窗结束时 `browser 仍在: yes`。
- **③ type= 直方图**：只有 **C3** 出现 `type=gpu-process`（`[t25] pid=257 st=R`、`[t30] pid=257 st=S`、
  `[t40] pid=306 st=R`）；`type=renderer` **四轮全为 0**。

---

## 3. 关键新事实（本轮实测得到，不是推断）

1. **分辨率之谜解开**：同一轮里 screendump 会先是 640×480、随后变成 1280×800。
   C3 的截图字节数：`shot-01` = 921615（640×480），`shot-02..06` = 3072016（1280×800）。
   日志给出了原因——weston 在会话中途才把输出模式设上：
   `Output 'Virtual-1' enabled with head(s) Virtual-1`，随后
   `Display: EVENT: wayland_screen.cc:149 Display[14] bounds=[0,0 1280x800], workarea=[0,0 1280x800]`。
   ⇒ 历史 351 张里 640×480 与 1280×800 混杂，是**同一原因**，不是两种平台配置。

2. **导航从未提交 —— 这是 renderer 不存在的直接原因（比"renderer 起不来"更靠前）**：
   C1-r2 的时序是
   `04:57:49 URL to scan: file:///usr/share/html-test/index.html` →
   `04:57:52 [180:221] FileURLLoader::Start: file:///usr/share/html-test/index.html` →
   **此后没有任何 navigation commit / render_process_host / renderer 相关行**。
   日志最后一条是 `AddComponentExtension Google Hangouts`（04:57:56），
   与 `report/19` 里历史轮次的"最后一条日志"**完全一致**。
   ⇒ 之前把问题描述成"renderer 从未被 fork"是对的，但更准确的描述是：
   **导航卡在 `FileURLLoader::Start` 之后、提交之前，因此根本不会去创建 renderer。**

3. **零窗口/表面创建日志**：对 `xdg_surface|shell_surface|wl_surface|wayland_window|PlatformWindow|
   CreateSurface|ShowWindow` 的检索在四轮 chrome 日志里**全部 0 命中**（`--v=1` 下）。
   目前没有任何证据表明 Chromium 成功创建并映射了 Wayland 表面。

4. **屏幕内容统计（新增 `ppm_assert.py --histogram`）**：
   | 截图 | 主色分布 | 判读 |
   |---|---|---|
   | C0-r3 (1280×800) | **白 66.7%** + 灰 (124,117,114) 7.3% + (138,132,129) 6.9% + (221,227,233) 3.1%，共 272 色 | 有大片**纯白面**（像窗口内是空白页），与其余三组不同 |
   | C1-r2 / C2 / C3 (1280×800) | (124,117,114) 33% + (138,132,129) 32% + …，**零白像素**，共 116 色 | 纯灰色系，无白面 |
   | 历史 `g17chr` (1280×800) | 与 C1-r2 **逐项完全相同** | C1 复现了历史画面状态 |
   | 历史 `v16-final` (640×480) | **黑 99.89%** + 灰 0.11%，仅 2 色 | 该轮取景时屏还没初始化 |
   ⇒ C0 与 C1/C2/C3 的**画面内容确实不同**（GL 三元组改变了渲染行为），但都不是本页内容。

5. **A0 后端枚举（C0-r3 内执行成功）**：
   ```
   FATAL ui/ozone/platform_selection.cc:46 Invalid ozone platform: xk-nonexistent
   ```
   ⇒ Ozone 的**运行期平台选择**确实存在并且在二进制里（与官方《Ozone Overview》的
   "Runtime binding of platforms" 一致）；非法平台名会让 Chromium FATAL。
   但该 FATAL 信息**不列出可用后端**，所以"哪些后端被编译进来"仍以宿主侧符号探测为准
   （`ozone-platform`×3 / `ozone-platform-state`×1 / `ozone-dump-file`×1 / `wl_compositor` /
   `wl_shm` / `wl_seat` / `libvk_swiftshader` / `vk_swiftshader_icd` / `VK_ICD_FILENAMES` 均在）。

6. **其余已知缺口的当轮原样复现**（均非本轮新引入）：
   `drmGetDevices2() has not found any devices`、
   `Failed to find drm render node path` / `Failed to initialize drm render node handle`、
   `file_path_watcher_inotify.cc:338 inotify_init() failed: Function not implemented (38)`、
   `Binding to wl_shm version 1 but version 2 is available`、
   `No wl_seat object. The functionality may suffer.`、
   `Gdk: gdk_seat_get_keyboard: assertion 'GDK_IS_SEAT (seat)' failed`、
   dbus 连接失败（`/run/dbus/system_bus_socket` 不存在）、
   crashpad `missing credentials`。

---

## 4. 未达成项（如实记录，不宣称任何完成度）

- **renderer 仍为 0**，页面**一次都没有渲染出来**；四轮的像素严格集全部未通过。
- 阶段 A 的目标是"定标三元组"，这个目标达成了（见 §0.1–0.3）；
  但**它同时证明了三元组不是阻塞点**，所以"基础任务"的完成度**没有推进**——
  本轮的价值在于把探测范围从"平台/GL 选择"收缩到"导航提交与 GPU/crashpad 栈"。
- 阶段 B/C/D/E/F 未执行（用户指定本轮只做阶段 A）。

---

## 5. 下一步：阶段 B 的具体着手点（比原计划更聚焦）

原计划 B 阶段的目标是"抓 browser rc=191 临终现场"。基于本轮证据，目标对象应改为三个：

1. **优先抓 `gpu-process`**（C3 配置下它是独立进程、有明确退出码）。
   建议基线配置固化为一轮：
   `--ozone-platform=wayland --use-gl=angle --use-angle=vulkan` + `GPU_MODEL=separate`（去掉 `--in-process-gpu`）。
   此时 `strace -f -p <gpu-pid>` 的临终末调用与信号/退出码就是"191 从哪来"的判决性证据。
2. **同时抓 browser 在 `FileURLLoader::Start` 之后的路径**——导航不提交才是 renderer 缺失的直接原因。
   关注点：是否发起 renderer 创建、是否在等某个 IPC/子进程、是否被 `wl_seat` 缺失卡住。
3. **单变量对照**（各一轮，避免同时改多个变量）：
   - `GL_VARIANT=angle-gles`（修正 `opengles` 拼写，验证备选 GL 是否可行）；
   - 去掉 `--disable-features` 里的 `Vulkan`（原计划 R6：与 `--use-angle=vulkan` 是否相冲）。
4. `VK_ICD_FILENAMES` 是否真的被 ANGLE 采用 —— 用 `--use-angle=vulkan` +
   检查 ICD 是否被加载（`ANGLE ` 的 `Preferred device ICD not found` 说明没被当偏好设备，
   需要确认它是否至少被当作默认设备加载了）。

---

## 6. 判据工具的状态（本轮同步更新）

- `scripts/t490/ppm_assert.py` 现为 **921 行**，含：
  - 9 条单图谓词（分 core / viewport / info 三组，`--full-page-min-height` 控制 viewport 组是否卡关）；
  - 双帧心跳 `--diff`；
  - **新增 `--histogram`**：屏幕内容统计（主色占比 / 不同颜色数 / 平均色）。
    在参照图上可精确还原页面 CSS 配色：白 77.19% + banner `#c8102e` 7.04% +
    状态条 `#f0f0f0` 6.36% + `#111111` 2.11% + 纯红 0.84% + 纯绿 0.84%。
- 回归（本轮改动后复跑）：640×480 正对照 **5/5 exit=0**、1280×800 正对照 **7/7 exit=0**、
  真实历史 640×480 负对照 **0/5 exit=1**、同轮两帧 diff 无差异 **exit=1**。
- `scripts/t490/round_assert.sh` 已在真实流程里端到端生效：
  四轮各自产出 `ppm-assert-*.json`×6、`ppm-diff-*.json`×4、`ppm-summary.txt`、`guest/*.log`。

---

## 7. 证据索引

| 内容 | 位置 |
|---|---|
| 四轮完整证据（证据目录内） | T490 `~/xk6/evidence/2026-09-22_t490-ozone-c{0,1,2,3}-*` |
| 四轮已回收副本（本地） | `evidence/2026-09-22_t490-phaseA/<tag>/`（每轮 18–19 个文件，共 421 KB） |
| 逐张像素判据 | 各轮 `ppm-assert-shot-*.json` |
| 双帧心跳判据 | 各轮 `ppm-diff-*.json` |
| 轮次汇总（尺寸/严格集/心跳/关键行/type 直方图） | 各轮 `ppm-summary.txt` |
| guest 持久日志 | 各轮 `_root_full.log`、`_root_chrome-full.log`、`_root_chrome-snap.log`、`_root_a0.log`(仅 C0-r3) |
| 平台合规 | 各轮 `platform-check.txt`、`platform-compliance.txt` |
| 会话时间轴与 QEMU 全量输出 | 各轮 `console.log` |
| 本轮脚本 | `scripts/t490/{autorun_v3.sh, t490_round.sh, round_assert.sh, ppm_assert.py, pull_guest_logs.sh, run_session_t490.sh}` |
| 自检页与参照图 | `scripts/testpage/local-check.html`(v1.2)、`scripts/testpage/reference/{ref-640x480,ref-640x480-heartbeat,ref-1280x800}.png` |

---

## 8. 对 `report/20` 的修正

1. `report/20 §2.1` 把截图格式写成"1280×800 / 3072016 字节"是**不完整**的：
   实测同一轮内会先出现 640×480（921615 B），weston 设上模式后才变 1280×800。
   已在本报告 §3.1 给出原因。**判据必须动态取尺寸 + 轮内一致性校验**（已实现）。
2. `report/20` 沿用记忆里的 `pkg-installed.img` sha256 `56302b8f…` —— **有误**，
   实测为 `bab5c9f5…`（见本报告文件头）。
3. `report/20 §3 阶段 A` 假设"观察窗 W=80 足够" —— 实测发现真正的瓶颈不是窗长，
   而是 `snapshot()` 的 fork 风暴与会话尾段的 guest 侧计算（D1/D3）。W=80 在修完 D1/D3 后可用。
4. `report/20` 提到 `run-session.py` 用 `kill -0` 判活并会被僵尸骗过 —— 实测是
   `self.proc.poll() is None`（`run-session.py:182`）；"僵尸也算活"是 guest 侧 autorun 的坑。
