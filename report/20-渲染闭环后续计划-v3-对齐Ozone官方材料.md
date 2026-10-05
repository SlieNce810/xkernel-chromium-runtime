# report/20 · Chromium 页面渲染闭环后续计划（v3 · 对齐官方《Ozone Overview》）

- 日期：2026-09-22
- 前序：`report/18`（最终验收·已否证）、`report/19`（阶段零至二实测与纠错）
- 官方依据：赛题材料《Ozone Overview》（Guiding Principles / Ozone Platform Interface /
  Ozone in Chromium / Porting with Ozone / Adding an Ozone Platform to the build /
  Building with Ozone / GN Configuration notes / Running with Ozone / Ozone Platforms）
- 本轮新增交付物：`scripts/t490/ppm_assert.py`、自检页 v1.1、`scripts/testpage/reference/ref-1280x800.png`

---

## 0. 结论先行（三句话）

1. **官方材料确认我们的路线是对的，不是权宜之计。** Ozone 的 Guiding Principle 明确写着
   "Runtime binding of platforms … We allow this and provide a command-line flag to select a
   platform (`--ozone-platform`)"，官方 run 示例本身就是
   `chrome --ozone-platform=wayland`。我们固定 Wayland 后端，正是官方设计意图下的正常用法。

2. **但官方材料的另一个作用是把"替代路径"逐条关掉，逼出真正的战场。** 官方推荐的嵌入式目标是
   `content_shell`——本镜像 **不存在**；官方 DRM/GBM 后端需要系统的 `libgbm`/`libdrm` 与
   DRM/KMS 设备——本镜像 `libgbm.so.1` 是 **15 字节**、`libdrm.so.2` 是 **17 字节**的符号链接
   占位、`/dev/dri` 不存在；X11 后端需要 X server——guest 里没有。
   **唯一可行的仍是 Wayland + 软件 GL**，所以战场不在"平台选择"，而在更下层的两件事：
   **browser 进程 `rc=191` 静默退出** 与 **renderer 从未被 fork**。

3. **验收判据必须机器可读，否则 10 分钟长稳这类结论无法复核。** 本轮交付 `ppm_assert.py`：
   把"渲染正确"落成 9 条像素谓词 + 1 条双帧心跳判据，并完成 **正 / 负 / 差三重对照**
   （正向 9/9 PASS、真实历史截图负向 1/9 PASS-only、差图三情形 3/3 符合预期）。
   自检页升级 v1.1，新增"渲染心跳"，把"renderer 存活"与"JS 在执行"变成截图可直接证明的事实。

---

## 1. 官方材料带来的三处修正（本节结论直接改写阶段一冻结基线）

### 1.1 修正一：`--ozone-platform=wayland` 有官方依据，冻结它

官方 Guiding Principles 第二条 "Runtime binding of platforms"：平台在**编译期**形成候选集，
**运行期**由命令行旗标选择。这解释了我们此前观察到的现象——为什么换 `--ozone-platform` 会
改变 Ozone 初始化路径与 GPU 行为，而二进制本身不变。

> **行动**：这条不再是"临时选择"，写进冻结基线并注明官方依据。

### 1.2 修正二：三条替代路径**不是"没试"，是"试不了"**（已逐一取证）

| 官方路径 | 官方描述 | 本镜像实测（本轮核实） | 结论 |
|---|---|---|---|
| **Headless** | "draws graphical output to a PNG image (no GPU support; software rendering only)"，配 `--ozone-dump-file=` | `/usr/lib/chromium/content_shell` → **ext2_lookup 失败（不存在）**；全量 `chrome` 是否含 headless 后端**未验证** | 探针待做（阶段 A0）；即便可用也只证明"渲染管线通"，**不能替代窗口验收** |
| **DRM / GBM** | Linux direct rendering + mesa GBM + DRM/KMS | `libgbm.so.1` = **15 B**、`libdrm.so.2` = **17 B**（皆符号链接占位，非实体）；`/dev/dri` 不存在；日志有 `drmGetDevices2() has not found any devices (2)` | **不可行** |
| **X11** | 默认平台 | guest 内无 X server；Weston 只暴露 `wayland-0` socket | 不可行（补 Xwayland 是新增工作量且不解决 GL，不列为路线） |
| **Wayland** | 官方示例 `chrome --ozone-platform=wayland` | weston `drm-backend.so` + `--socket=wayland-0` 已稳定；browser 能创建窗口 | **唯一可行** |

> ⚠️ 官方 "Building with Ozone" 那一节（GN 旗标 `use_ozone` / `ozone_platform_*`）对我们**只作参考系**：
> 我们拿到的是 248 MB 预编译 Chromium，**不能重编**，只能在已编译进二进制的后端集合里用运行时旗标选。
> 这条约束决定了整个计划的行军路线：**一切靠运行时旗标，一切靠实测，不靠猜 GN 配置。**

### 1.3 修正三：GL 旗标取值错误，必须改正（当前冻结基线的硬伤）

`ui/gl/init/gl_factory.cc:110` 打印：

```
Requested GL implementation (gl=none,angle=none) not found in allowed implementations:
[(gl=egl-angle,angle=opengl),(gl=egl-angle,angle=opengles),(gl=egl-angle,angle=vulkan)]
```

→ `--use-gl=swiftshader` 这个取值**在本 build 上不存在**（`gl=none`）。去掉 `--disable-gpu` 后
依旧 `gl=none`，证明与 `--disable-gpu` 无关，就是这个取值本身不被接受。

本 build 的软件光栅化只有一条路：**ANGLE + Vulkan + SwiftShader ICD**。镜像里三件套齐全
（`libvk_swiftshader.so` 19.7 MB、`vk_swiftshader_icd.json`、`libvulkan.so.1` 698 KB）。

```diff
- --use-gl=swiftshader
+ --use-gl=angle --use-angle=vulkan          # 环境变量 VK_ICD_FILENAMES=/usr/lib/chromium/vk_swiftshader_icd.json
```

---

## 2. 目标与验收判据（可测量的定义）

把赛题"基础任务"拆成 6 条**机器可判**的验收项。每条都有判据、判据工具、证据路径——
这是"如何验证基础任务已达成"的正式回答。

| # | 验收项 | 判据（机器可判） | 判据工具 | 证据 |
|---|---|---|---|---|
| **V1** | Weston 图形会话稳定 | ≥600 s 观察窗内每次快照 `pgrep -x weston` 非空；weston.log 含 `Output 'Virtual-1'` 且无 `Quitting`/`fatal`；`/run/user/0/wayland-0` 存在 | 快照脚本 | `weston.log`、`console.log` |
| **V2** | Chromium browser 存活 | browser PID 在快照中**连续**存在 ≥600 s | `chrome-snap.log` | 同上 |
| **V3** | ≥1 个 renderer 持续 ≥60 s | 同一个 `type=renderer` 的 PID 连续出现 ≥12 次（5 s 间隔） | `chrome-snap.log` | 同上 |
| **V4** | 页面确实绘制 | `ppm_assert.py --strict` → **9/9 PASS** | `ppm_assert.py` | `ppm-assert-*.json` |
| **V5** | JS 在执行 / renderer 未死 | 间隔 ≥30 s 的两张 screendump，`--diff` 两项均 PASS | `ppm_assert.py --diff` | `ppm-diff-*.json` |
| **V6** | 页面内容符合指定要求 | ①–⑦ 逐项映射（见 §6.2） | 同上 + 人工目视 | 同上 |

### 2.1 截图格式前提（真源）

QEMU `screendump` 在 1280×800 下产出 **3072016 字节** 的 PPM：
header `P6\n1280 800\n255\n` = **16 B** + raster `1280×800×3` = **3072000 B**。
`ppm_assert.py` 会校验这两个数——**不匹配就说明 screendump 没写完或被 Ctrl-A c 打断**，
这本身就是一种证据完整性检查（历史上出现过被截断的伪证据，见 `report/19 §1`）。

---

## 3. 任务拆解：六阶段 A–F

每阶段给出：**目标 / 输入 / 动作 / 产出 / 判据 / 不达标怎么办**。

### 阶段 A（≈0.5 天）定标 Ozone 运行期三元组

**目标**：找出"本 build 真正接受"的 (`--ozone-platform`, GL 实现, GPU 进程模型) 组合。
**输入**：`pkg-installed.img`（sha256 `56302b8f…`）、`autorun_full.sh`、自检页 v1.1。
**动作**：
1. **A0 后端枚举探针**（5 min）：向不存在的平台名发起一次 20 s 启动，读错误信息里 Ozone 是否
   列出可用后端；同时用 `strings`/`grep -a` 在二进制里找 `ozone-platform`、`ozone-dump-file`、
   `xdg-shell`、`wl_compositor` 等符号，确认 Wayland 后端确实编译在内。
2. **A1 五组正交短轮**（每组 180 s）：

   | 组 | ozone-platform | GL 旗标 | `--in-process-gpu` | `--disable-gpu` | 目的 / 假设 |
   |---|---|---|---|---|---|
   | **C0** 控制 | wayland | 默认 | 否 | **是** | 历史"窗口能画出来、browser 活 90 s+、但页面不渲染"。作为**存活基线**，用于隔离 GPU 初始化是否是崩溃源 |
   | **C1** 主目标 | wayland | `angle+vulkan` + ICD | 是 | 否 | 命中 allowed 列表里的 `angle=vulkan` |
   | **C2** 备选 | wayland | `angle+opengles` | 是 | 否 | SwiftShader 亦经 GLES 暴露，作为 fallback |
   | **C3** 隔离 | wayland | `angle+vulkan` + ICD | **否** | 否 | 独立 GPU 进程：GPU 初始化失败不再拖死 browser；快照里能看到 `type=gpu-process` |
   | **C4** 旁证 | **headless** | — | — | — | 20 s 探针：后端是否存在、是否产出 PNG dump。用于把"渲染管线"与"Wayland 呈现"解耦 |

3. **A2 差异分析先行**：阶段 A 一旦出现"某组不崩"，立刻做**崩溃组 vs 不崩组的旗标/日志差异**
   对比——这比 strace 便宜得多，应优先。

**产出**：`evidence/2026-09-2x_t490-ozone-matrix/`（每组独立子目录）+ `report/21`。
**判据（阶段 A 只看三条）**：① `gl=none` / `not found` 是否消失；② browser 存活时长；
③ 快照 `type=` 统计里是否出现 `gpu-process` / `renderer`。
**不达标**：五组全崩且全部打印同一 GL 错误 → 转阶段 B，且**不再试新旗标**。

### 阶段 B（≈0.5 天）抓 browser `rc=191` 的临终现场

**目标**：把"静默退出"变成"有判决性证据的退出"。
**已知现场**：`02:30:14 browser 启动` → `02:31:25 FileURLLoader::Start: file:///…` →
`02:31:29 最后一条日志` → `02:32:16 rc=191（存活约 40 s）`；无 FATAL、无 `Goodbye`、无崩溃报告；
30 次快照里 `type=renderer` **一次都没出现**。

**动作**：
1. **B1 attach 模式 strace（便宜，先做）**：browser 起来 3 s 后附加，抓临终前最后的系统调用。

   ```sh
   # guest 侧（注意 guest /tmp 是 tmpfs，日志必须写 /root）
   bp=$(pgrep -f 'chromium .*--ozone-platform' | head -1)
   strace -f -tt -s 256 -o /root/browser.strace -p "$bp" &
   ```
2. **B2 全量模式 strace（attach 无结论时）**：从启动就 `-f` 跟踪，`timeout 150` 兜底。

   ```sh
   strace -f -tt -s 200 -o /root/browser.strace timeout 150 \
     chromium $FROZEN_ARGS --user-data-dir=/tmp/chromium-baseline \
     file:///usr/share/html-test/index.html
   ```
   ⚠️ TCG 下 strace 开销会改变时序，可能"一贴就不崩"。**两种模式都要留证**，并在报告里
   明确标注"哪一条是加了 strace 才改变的"。
3. **B3 判读（决定分支）**：

   ```sh
   tail -n 40 /root/browser.strace
   grep -nE 'SIG(SEGV|ABRT|BUS|ILL|SYS|KILL)|exit_group|\+\+\+ killed' /root/browser.strace | tail -20
   ```
   - 末行 `exit_group(191)` → **主动退出码**。下一步查上游 `content/public/common/result_codes.h`
     与调用点，定位是哪个检查触发的（这是唯一能"顺着代码找到根因"的情形）。
   - 末行 `--- SIGxxx ---` → **信号致死**。191 = 128 + 63，对应实时信号 63；
     需取 `si_addr`/指令指针，并用崩溃前采集的 `/proc/<pid>/maps` 映射到模块。
   - 无 strace 结论且无信号 → 检查是否被 **seccomp** 拦（`/proc/<pid>/status` 的 `Seccomp:` 字段）。
4. **B4 补低开销伴随证据**：把快照采集从"仅 cmdline/stat"扩展到
   `/proc/<pid>/status`（`State`/`SigQ`/`Seccomp`/`Threads`）与 `maps` **行数**（用于判断
   GPU 驱动/ICD 是否真的被 `dlopen` 进来）。

**产出**：`report/22-浏览器退出码191归因.md`。
**判据**：给出一个**可复现的判决**（退出码语义 或 信号+模块），而不是"疑似"。
**不达标**：超过 1.5 天仍无判决性证据 → 触发 §8 停止规则。

### 阶段 C（≈1 天）证据驱动补内核缺口（严格串行、一次一个）

**原则**：只补 **B 阶段指认的 syscall**，不夹带新功能；errno 修正类与新功能类分开提交与评审。

| 类别 | 例子 | 处理方式 |
|---|---|---|
| **errno 修正类** | 已有 P0–P4、G17 的形状 | 复用 `scripts/t490/p*.py` 幂等应用器风格，补 `p7_*.py` |
| **新功能类** | inotify 系统调用本体、landlock | 单独分支 + 单独补丁 + 单独 PR，不与主任务混提 |

**每轮固定动作**：改**一个**接口 → `make build`（增量 ~5 s）→ 跑一轮 180 s → 出判据。
**产出**：`scripts/t490/p7_*.py`、`report/patches/0011-*.patch`、`report/23`。
**判据**：browser 存活时长是否抬升 / renderer 是否出现。两轮同根因不收敛即停手（§8）。

### 阶段 D（≈0.5 天）renderer 出现 + 页面渲染验收

**动作**：
1. **D1** 从快照统计 `type=renderer` 的 PID 与连续出现次数（V3）。
2. **D2** 对每张 screendump 跑 `ppm_assert.py --strict`（V4）。
3. **D3** 对间隔 ≥30 s 的截图对跑 `--diff`（V5）。
4. **D4** 三项全绿 → 进入阶段 E；`type=renderer` 为 0 但 V4 全绿 → 说明页面画出来了但进程模型
   与预期不同，**优先复核快照脚本是否漏抓**（`--in-process-gpu` 不影响 renderer 独立性，
   但 `--single-process`/`--no-zygote` 会）。
5. **D5 降级声明（最后手段）**：若 V3 始终不达标，交付"部分完成"，明确写出未达成项与证据链，
   **不得用参数试错冒充完成**。

**判据**：V3 ∧ V4 ∧ V5 同时成立。
**产出**：`report/24-渲染闭环达成.md`。

### 阶段 E（≈0.5 天）10 分钟长稳 + 采样汇总

**动作**：
1. 单轮 **600–720 s**，每 30 s 快照（≥20 次），每 60 s `screendump`（≥10 张）。
2. 10 张截图逐张 `ppm_assert.py --json`；相邻对跑 `--diff`（≥5 对，间隔 60 s）。
3. `scripts/measure.py` 汇总 ≥5 次独立启动样本：`T_renderer`（首条 chromium 日志 → renderer 出现）、
   `T_page`（→ 首帧页面截图）、`L_browser`（browser 存活时长）；给中位数与波动范围。
4. 宿主指纹 + 平台合规：`t490_platform_check.sh`（35 项）+ `run-session.py` 的 15 项断言。

**判据**：V1–V6 全绿，且样本数 ≥5、`T_*` 波动范围可交代。
**产出**：`evidence/2026-09-2x_t490-stability-10min/` + `report/25`（四项完成声明 + 证据索引）。

### 阶段 F（≈0.5 天）冻结与提交

```sh
git diff --check
make build                      # 构建检查
bash scripts/t490/t490_platform_check.sh          # RC=0 才合规
python3 scripts/run-session.py --dry-run --cwd ~/x-kernel --out evidence/dry-run
git tag base-task-render-closed     # 不覆盖 p0-drm-version-fix / R1 / G17
git push origin main
```

**产出**：新 tag + `report/15` 证据索引更新。

---

## 4. 关键实现步骤（可直接粘贴）

### 4.1 阶段 A0：后端枚举探测

```sh
# guest 侧（20s 即退出，不进入观察窗）
chromium --ozone-platform=__nonexistent__ --no-sandbox --enable-logging=stderr --v=1 \
  about:blank 2>&1 | grep -iE "ozone|platform|available" | head -20

# 二进制层面确认后端是否编译在内（busybox strings 缺失时退回 grep -a）
grep -aoE "ozone-platform[a-z-]*|ozone-dump-file|xdg-shell|wl_compositor|wl_shm" \
  /usr/lib/chromium/chromium | sort -u | head -20
```

### 4.2 阶段 A1：单轮命令（三元组参数化）

需把 `autorun_full.sh` 扩展成 `autorun_v3.sh`，只加三个环境变量入口（其余逻辑一字不改）：

```sh
OZ_PLATFORM="${OZ_PLATFORM:-wayland}"      # --ozone-platform=
GL_VARIANT="${GL_VARIANT:-angle-vulkan}"   # none | angle-vulkan | angle-opengles | legacy
GPU_MODEL="${GPU_MODEL:-in-process}"       # in-process | separate
```

各组调用（在 `~/xk6` 下）：

```sh
BASE_IMG=~/x-kernel/images/pkg-installed.img \
PAGE_HTML=~/xk6/scripts/testpage/local-check.html \
OZ_PLATFORM=wayland GL_VARIANT=angle-vulkan GPU_MODEL=in-process \
  bash scripts/t490/t490_round.sh ozone-c1 180 30 autorun_v3.sh
```

> ⚠️ `BASE_IMG` **必须显式覆盖**为 `pkg-installed.img`——`t490_round.sh` 的默认值
> `p0-drmversion-fixed.img` 里 chromium 是 **0 字节空壳**。

### 4.3 阶段 B：strace 判读

见 §3 阶段 B 的 B1–B3 命令块。要点：
**日志一律写 `/root/`**（guest `/tmp` 是 tmpfs，关机即失）；**不要用 `pkill -f <pat>`**（会自杀），
用 `pkill -f "qemu-syste[m]"`。

### 4.4 阶段 D/E：判据命令

```sh
# 单张截图判定（9 条谓词 + 尺寸校验，全绿才 exit 0）
python3 scripts/t490/ppm_assert.py shot-01.ppm --expect-size 1280x800 --strict \
        --json ppm-assert-01.json

# 双帧心跳（间隔 ≥30s 的两张截图；局部变化 ⇒ renderer 活着且 JS 在跑）
python3 scripts/t490/ppm_assert.py shot-01.ppm --diff shot-05.ppm \
        --min-changed 200 --json ppm-diff-01-05.json

# 批量：把一轮里所有 png 转回 ppm 后逐张判定（若证据目录里只留了 png）
#   scripts/ppm2png.py 是 png 方向的；反向可用 tools/ 下的转换器或 QEMU 原始 ppm
```

---

## 5. 所需资源与工具

| 资源 | 位置 / 取值 | 用途 | 备注 |
|---|---|---|---|
| 测试机 | `mo@10.249.63.140`（备用 `10.157.181.239`） | 全部实跑 | 连不上先 **ping 两个 IP** |
| QEMU | `~/qemu-root/usr/bin/qemu-system-aarch64`（10.2.1） | AArch64 纯 TCG | 命令行**不得出现任何 `-accel`** |
| 基础镜像 | `~/x-kernel/images/pkg-installed.img`<br>sha256 `56302b8f4d1c56d99f2ba6e84998448ed5caa09093ee3663fbc07c8741e091de` | 含实体 chromium 249957096 B | **唯一**可用基础镜像 |
| 内核源码 | `~/x-kernel`（分支含 P0–P4/G17 补丁） | 增量 `make build` | 工具链 PATH 见 §5.1 |
| 轮次编排 | `~/xk6/scripts/t490/t490_round.sh` | 注入 autorun + probe，跑一轮 | 产出标准证据目录 |
| guest 脚本 | `~/xk6/scripts/t490/autorun_full.sh` → `autorun_v3.sh` | 冻结旗标 + 采集 | 新增三元组参数 |
| 平台合规 | `scripts/t490/t490_platform_check.sh`（35 项）<br>`scripts/run-session.py`（15 项断言） | 合规预检 | 证据目录共 8 文件 |
| 像素判据 | `scripts/t490/ppm_assert.py` | **本轮新增**，9 谓词 + 心跳 | 仅标准库，1280×800 约 **0.6 s/张** |
| 参照图 | `scripts/testpage/reference/ref-1280x800.png` | 判据的**正对照基准** | 107 KB，随仓库留存 |
| guest 侧 gl 资源 | `/usr/lib/chromium/{libvk_swiftshader.so 19.7 MB, vk_swiftshader_icd.json, libEGL.so, libGLESv2.so, libvulkan.so.1}` | 软件 GL | 三件套齐全 |
| guest 侧调试器 | `strace`（1.2 MB） | 阶段 B | 已确认在镜像里 |
| 汇总脚本 | `scripts/measure.py` | 阶段 E 采样汇总 | 需按 §3-E 的指标补齐 |

### 5.1 工具链 PATH（缺一即构建失败，务必记住）

```sh
export PATH="$HOME/.cargo/bin:$HOME/qemu-root/usr/bin:$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"
```

- 缺 `$HOME/.cargo/bin` → `cargo +nightly-2026-03-08 fmt` 报 `no such command`（pre-commit 会拦住提交）；
- 缺 `qemu-root/usr/bin` → 宿主的旧 QEMU 被调用，平台合规直接失败。

---

## 6. 验证方法

### 6.1 如何验证"基础任务已达成"（← 用户要求之一）

**判定顺序（不可跳步）**：先 V1（图形会话），再 V2（窗口），再 V3（renderer），最后 V4/V5/V6（内容）。
每一步的证据都必须来自**当轮**证据目录，且截图必须来自 **QEMU monitor `screendump`**
（赛题第七节(一)3 唯一认可方式），不得用 guest 内截图工具替代。

**最终声明模板（阶段 E/F 产出）**：

| 要件 | 完成 | 判据实测值 | 证据路径 |
|---|---|---|---|
| 图形会话（Weston） | ☐ | weston 存活 ___ s，`Output 'Virtual-1'` 出现 | `evidence/.../weston.log` |
| Chromium 窗口 | ☐ | browser pid=___ 存活 ___ s | `evidence/.../chrome-snap.log` |
| ≥1 renderer ≥60 s | ☐ | renderer pid=___ 连续 ___ 次快照（=___ s） | 同上 |
| HTML 页面正确渲染 | ☐ | `ppm_assert` 9/9 PASS，心跳 diff PASS | `evidence/.../ppm-assert-*.json` |
| 稳定性 ≥10 min | ☐ | 观察窗 ___ s，截图 ___ 张，中途无退出 | `evidence/.../screenshots/` |
| 平台合规（纯 TCG） | ☐ | `t490_platform_check.sh` RC=0，`run-session.py` 15/15 | `evidence/.../platform-*.txt` |

### 6.2 如何验证"HTML 渲染结果符合指定要求"（← 用户要求之二）

自检页 v1.1（`scripts/testpage/local-check.html`）把"符合要求"翻译成 **7 条可见特征 + 9 条像素谓词**：

| 页面特征 | 期望像素表现 | 自动判据（`ppm_assert.py`） | 报告字段 |
|---|---|---|---|
| ① 三原色块 | `#ff0000`/`#00ff00`/`#0000ff`，各 120×72，**自左向右**，同一水平带 | `swatches_3channels` + `swatches_left_to_right` + `swatches_same_row` | bbox 与 x0/y 中心 |
| ② 黑白棋盘 | 24 px 格，**边缘锐利**（无灰边/模糊） | `checkerboard_24px`：暗块长 ≈ 亮块间距 ≈ 行高，且**相位翻转** | `cell_px`、`y_steps` |
| ③ 表格与边框 | ≥4 条长横线 + ≥4 条长竖线 | `table_borders` | `h_lines`、`v_lines` |
| ④ 文本（ASCII+中文） | 非白像素成行分布 | `non_white_ratio` | 占比 |
| ⑤ JS 执行 | **绿字** `#0b6b2f`（CSS 默认是红 `#b3261e`，**只有 JS 会改绿**） | `js_executed_green_text` | 绿字像素数 |
| ⑥ 环境指纹 | UA 文本行存在 | 由 `non_white_ratio` + 目视兜底 | — |
| ⑦ **渲染心跳**（v1.1 新增） | 计数每秒自增 + 移动块（限定在小盒内） | `--diff`：`changed ≥ 200` **且** 变化 bbox 覆盖率 ≤ 0.60 | 变化像素数、变化 bbox |
| marker | banner 文字 `marker=XK-CHROMIUM-OK` | 由 `banner_c8102e` 色条存在间接证明；**文字需人工目视**（无 OCR） | banner bbox |

**⑦ 的设计动机（重要）**：本地判断渲染结果的模型不可读图，因此不能把结论建立"我看了一眼"上。
把"计数器每秒自增"写进页面后，**两张不同时刻的截图必然存在差异**：

- 有差异且差异**局部** → renderer 在跑、JS 在执行、合成在刷新（V5 达成）；
- 无差异 → renderer 已死或从未绘制；
- 差异铺满全屏 → 整屏重绘 / 闪屏 / 崩溃恢复，不是稳定的渲染。

### 6.3 如何验证"判据本身可信"（元验证，本轮已完成）

一个没被验证过的门禁比没有门禁更危险。`ppm_assert.py` 已做**三重对照**：

| 对照 | 输入 | 预期 | 实测 |
|---|---|---|---|
| **正向** | 本机 Chrome 无头 1280×800 渲染自检页 v1.1 → PPM | 9/9 PASS | ✅ **9/9 PASS**（含 `checker_bands=4, cell_px=26, y_steps=[24,24,24], phase_alternates=True`） |
| **负向** | 真实历史 screendump（`2026-09-21_t490-v8-shim2`，页面当时未渲染） | 几乎全 FAIL | ✅ **1/9**，8 项正确 FAIL |
| **差图-局部** | 参照图 + 仅改动一块 48×20 区域 | 两项 PASS | ✅ 变化 1920 px，bbox 覆盖率 0.0025 |
| **差图-整屏** | 参照图 vs 全图反色 | `localized` 必须 FAIL | ✅ 变化 1024000 px，覆盖率 1.0 → FAIL |
| **差图-自比** | 同一张图自比 | `changed` 必须 FAIL | ✅ 变化 0 px → FAIL |

> 复现命令见 `report/21` 附录；参照图已随仓库留存（`scripts/testpage/reference/ref-1280x800.png`）。
> **纪律**：每轮证据目录里必须同时留下该轮截图的 `ppm_assert --json` 输出，
> 否则"渲染正确"只是口头结论。

---

## 7. 风险与应对

| 风险 | 触发信号 | 影响 | 应对 |
|---|---|---|---|
| GL 组合仍不被接受 | `gl_factory.cc:110` 仍打印 `not found` | 页面不渲染 | 依次试 `(vulkan)→(opengles)→(opengl)`；同时保留 C0 控制组 |
| browser 仍 `rc=191` | 快照中 browser 消失 | 无窗口 | 阶段 B：attach strace → 全量 strace → 信号/退出码分叉 |
| ANGLE 初始化触发 FATAL | 日志出现 `FATAL` / `GPU process isn't usable` | browser 秒退 | 回退 C0（`--disable-gpu`，历史可活 90 s+）**先保住"窗口可见"分项**，再单独攻渲染 |
| `/dev/dri` 缺失 | `drmGetDevices2() has not found any devices` | ANGLE 枚举不到设备 | 用 `VK_ICD_FILENAMES` 指向 SwiftShader ICD **绕过** `/dev/dri`；确有必要再评估 devfs 补 `renderD128` |
| `libgbm`/`libdrm` 是符号链接占位 | 15 B / 17 B | 一切走 GBM 的路径必败 | **明示放弃** DRM/GBM 后端，不浪费时间 |
| inotify 未实现 | `inotify_init() failed: ENOSYS` | 部分子系统降级 | `/proc/sys/fs/inotify/*` 已补；若 strace 证明确有 inotify 依赖，按"新功能类"单独立项 |
| CJK 字体缺失（tofu） | 中文显示为方框 | 文本判据失效 | 判据只用 ①–③ + marker（英文 + 色块）；补字体放最后，不阻塞主链 |
| 无窗口管理器致窗口尺寸/位置不定 | 固定 ROI 取不到 | 判据误判 | `ppm_assert.py` **全部特征检测，零硬编码坐标**（本轮已按此实现并验证） |
| TCG 下 strace 开销改变时序 | 加 strace 后不崩 | 归因错误 | 双模式留证 + 报告显式标注；优先用 A2 差异分析替代 |
| 10 分钟长稳中途崩 | renderer 消失 | 稳定性分丢失 | 每 30 s 快照 + 每 60 s 截图，崩点可定位到最近快照；必要时 `--v=0` 降 stderr 压力 |
| 证据被覆盖/改写 | — | 合规风险 | 每轮独立 `evidence/<date>_t490-<tag>/`，**只增不改**；截图格式校验（3072016 B） |
| 时间成本失控 | 轮次越跑越长 | 错过材料节点 | 短轮（180 s）只判"renderer 是否出现"；长稳轮单独跑 |

---

## 8. 停止 / 回退策略（沿用并强化用户原计划的失败默认值）

1. **两轮同根因不收敛** → 暂停堆补丁，产出四件套：Linux 对照行为、x-kernel 实际行为、
   最小复现、失败证据。**禁止把参数试错误判为完成。**
2. **阶段 B 预算 1.5 天** → 仍无判决性证据，改为"每次只改一个旗标 + 全量快照"的穷举，
   同时开始写"部分完成"报告，把已知项与未达成项分开陈述。
3. **任何一轮出现证据污染**（日志被手改、证据目录被覆盖） → 立即停止该方向，重建证据后再前进。
4. **绝不做的事**：用 `--single-process` 作为最终交付形态（赛题明确禁止）；
   在 dirty 工作区采数（违反第七节(二)3）；用 guest 内截图冒充 `screendump`。

---

## 9. 立即执行的下一步（三条命令）

```bash
# 1) 同步本轮新增/修改到 T490
#    ⚠️ Windows 的 scp 不处理含中文的绝对路径 → 先 cd 到仓库根再用相对路径
cd <中电杯仓库根>
ssh mo@10.249.63.140 'mkdir -p ~/xk6/scripts/t490 ~/xk6/scripts/testpage/reference'
scp scripts/t490/ppm_assert.py            mo@10.249.63.140:~/xk6/scripts/t490/
scp scripts/testpage/local-check.html     mo@10.249.63.140:~/xk6/scripts/testpage/
scp scripts/testpage/reference/*.png      mo@10.249.63.140:~/xk6/scripts/testpage/reference/

# 2) 阶段 A0：后端枚举 + 二进制符号探测（5 分钟，无观察窗）—— 见 §4.1

# 3) 阶段 A1：C1 主目标短轮（180 s）
ssh mo@10.249.63.140
cd ~/xk6
BASE_IMG=~/x-kernel/images/pkg-installed.img \
PAGE_HTML=~/xk6/scripts/testpage/local-check.html \
OZ_PLATFORM=wayland GL_VARIANT=angle-vulkan GPU_MODEL=in-process \
  bash scripts/t490/t490_round.sh ozone-c1 180 30 autorun_v3.sh
```

**本轮 T490 侧还需要补的东西（就一件事）**：把 `autorun_full.sh` 参数化成 `autorun_v3.sh`
（新增 `OZ_PLATFORM` / `GL_VARIANT` / `GPU_MODEL` 三个环境变量入口，并落地 §1.3 的 GL 旗标修正）。
除此之外不改任何现有逻辑——**基线可复现优先于功能扩展**。

---

## 10. 与 `report/19` 的关系

**继承**：
- `report/19 §4` 的结论"`Failed to initialize cpuinfo` 非致命（上游 `cpuinfo_arm_linux_init()`
  只有 `log_error` + `return`，无 `return false`）"继续有效；
- `report/19 §5` 的两条修正建议（GL 旗标改 `angle+vulkan`；阶段四判据拆分）在本计划中**正式采纳**
  （§1.3、§2）。

**修正**：
- 本轮把"判据不可复核"从隐患升级为一等公民问题，并给出工具与三重对照（§6.3）；
- 阶段二（矩阵）从"逐项排查接口"收敛为"**只排查 B 阶段指认的接口**"，避免把时间花在
  已被证否的方向（cpuinfo / inotify 均已修复且均非阻塞）。

**新增事实（本轮取证，写入项目记忆）**：
- `/usr/lib/chromium/content_shell` 不存在（排除官方 headless/content_shell 路线）；
- `libgbm.so.1` = 15 B、`libdrm.so.2` = 17 B（符号链接占位，排除 DRM/GBM 路线）；
- `libvulkan.so.1` 实体存在（`angle=vulkan` + SwiftShader ICD 是唯一软件 GL 路线）。

---

## 附录 A · 本轮代码与脚本变更

| 文件 | 变更 | 说明 |
|---|---|---|
| `scripts/testpage/local-check.html` | **v1.0 → v1.1** | ① `#runtime` 默认色改红 `#b3261e`，由 JS 改绿 ⇒ 绿字成为 JS 执行的硬证据；② 新增 ⑦ 渲染心跳（每秒自增计数 + 限定盒内移动块）⇒ 双帧差异可证 renderer 存活；③ 判据尾注改 ①–⑦ |
| `scripts/t490/ppm_assert.py` | **新增** | 9 条单图谓词 + 双帧心跳判据；`--strict` / `--json` / `--diff` / `--expect-size`；纯标准库；全部走 `bytes.translate` + 大整数位运算（1280×800 约 0.6 s） |
| `scripts/testpage/reference/ref-1280x800.png` | **新增** | 判据正对照基准（本机 Chrome 无头渲染自检页 v1.1） |

## 附录 B · 判据实现中踩过并修掉的坑（供后续维护者参考）

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| 1 | `#c8102e` banner 的 bbox 被撑成满屏 `[0,0,1279,799]` | 用**并集 bbox**（`mask_blob`）；ClearType 次像素抗锯齿产生零星彩色像素 | 单图改用 `dominant_bbox`（行/列投影取最长高位段）；差图仍用并集（差异散布本身是信息） |
| 2 | 红色块检不出，bbox 落在 banner 上 | banner 底色 `#c8102e` 也满足 `r≥200,g≤60,b≤60`，且面积大 10 倍 | 纯色块谓词收紧为 `g,b ≤ 30` |
| 3 | 表格线全部漏检（`h_lines=0`） | `table.data` 边框是 `#444444`(=68)，而"暗"阈值是 60 | `DARK_MAX = 100` |
| 4 | 棋盘检不出（`candidate_rows=0`） | ① 用"整行暗像素占比"判据，棋盘只占行宽 192/1280 被稀释到 0.075；② 全行游程里掺入同行标题文字 | 改为**尺度无关自洽判据**：等间距暗块分组 + 「暗块长 ≈ 亮块间距 ≈ 行高」+ 跨行相位翻转 |
| 5 | 差图 `OverflowError: int too big to convert` | 把整个 ROI 当成"一行"做通道合并 | 逐行合并三通道后再拼成 2D 掩码 |
| 6 | JS 绿字阈值定 40 时假阴性（实测 24 px） | 15 px 字号的纯粹像素本就少 | 阈值降到 15，并在 docstring 写明实测基准 |
| 7 | `#runtime` 的绿色由 CSS 写死 ⇒ 不能证明 JS 执行 | 判据逻辑漏洞 | 页面 v1.1 把 CSS 默认色改成红，只有 JS 会改绿 |
