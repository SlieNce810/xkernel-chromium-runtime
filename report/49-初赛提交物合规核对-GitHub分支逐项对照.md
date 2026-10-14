# 初赛提交物与分支内容合规核对（`report/49` + `report/50` 合并版）

> **核对对象**：`https://github.com/SlieNce810/xkernel-chromium-runtime` → 分支 `codex/initial-round-single-process`
> **审计基线**：HEAD `efe8933`（2026-10-05，46 commits）—— 本文件所有"合规/多余/缺失"判定以该快照为准
> **当前 HEAD**：`a3df0ef`（2026-10-06 23:13）—— 已包含本文件 §七 记录的修复
> **判定依据**：《赛题六》PDF §六（统一验收场景与评分标准·初赛评分表）＋ §七（统一评测平台与测量规范）
> **盘点口径**：GitHub Trees API `?recursive=1` 全量列表，**9620 个文件 / 778 个目录 / 374.60 MiB**（未截断）
> **核对时间**：2026-10-06

### v3 修订（2026-10-13，权威核对已迁移 report/55）

本文件的审计基线（HEAD `efe8933`，2026-10-05）**早于 10-06 VNC 演示轮与 10-13 全部工作**，
其中对截图证据的静态描述已过期。截至 2026-10-13 的权威逐条核对以 **`report/55`** 为准，
本文件保留为历史审计。v2 之后的变化摘要：

- §五 M1（演示视频）：仍是唯一未闭合的六件套项；OBS 32.1 已装验（report/52），A3.3/A3.4
  由用户 10-12 在物理屏确认，正式录屏待执行；仓库两个 MP4 仍只是 screendump 合成片。
- §五 M2（README）：已完成（根目录 README.md，含六件套索引/复现步骤/内核与镜像入口）。
- §五 M3（正式技术方案文档）：已完成（report/56，含覆盖矩阵与 Linux 基线对比章）。
- §五 M4/M5（内核指引/镜像入口）：README 已登记 Gitee fork 分支/tag/提交；镜像下载入口
  待上传 Release 后回填；**根目录 agentos-disk.img.xz 已确认过期（解出 441b4504，非证据轮
  使用的 bb25e0b2），必须替换后上传**；overlay 已入库 guest-overlays/。
- §五 性能 before/after：已完成配对测量（report/57 + evidence/2026-10-13_measure-*）；
  基线 v0.1-first-runnable 实测无法完成页面加载，改善为功能性跃迁。
- §七 screendump 漏交模式复发两次并已补：verify-b2-1005（10 张）+ vnc-demo-smoke（2 张），
  提交 `b01fbc0`；ppm 现共 229 张在库。
- 新发现（详见 report/55 §五）：perf3 指标为脚本常量口径、内核构建不可位复现
  （build_time 嵌入）、autorun 竞态（已修）、测量脚本 set -e/pipefail 缺陷（已修）。

### 修订历史（合并说明）

| 版本 | 说明 |
|---|---|
| `report/49`（v1） | 首次核对，产出"合规 7 类 / 边缘 5 类 / 多余 2 类 / 缺失 5 项 / 口径不一致 2 处" |
| `report/50`（并行会话，同日 10:14） | 同一分支的独立核对，结论一致，但多了 2 处口径不一致（`report/41` 指纹、`round-0*.log` 空文件）与多处证据细节核验 |
| **本文件（v2）** | **两者合并为唯一权威版本**。冲突之处已**逐条实测裁定**（§八），并新增 §七 的完整漏交排查。`report/50` 已删除 |

> 两版对同一分支的独立核对**结论一致**（六件套 5 件已齐、缺演示视频；2 类非交付物共 21 个文件），
> 这本身就是交叉验证。差异只在一处计数口径与三处补充，已按下文裁定。

---

## 一、结论速览

| 判定 | 数量 | 说明 |
|---|---|---|
| ✅ **合规**（赛题明确要求或直接支撑评分） | 9 类 | §三 |
| ⚪ **边缘**（非交付物，保留可，需在 README 给定位） | 5 类 | §三 末段 |
| ❌ **多余**（不属于必须提交内容，建议移出提交包） | 2 类 / **21 个文件** | §四 |
| ❌ **缺失**（评分表点名，仓库内确无） | **5 项** | §五 |
| ⚠️ **口径不一致**（仓库自述与事实矛盾） | **4 处** | §六 |
| 🔴 **已修复的证据漏交** | **35 张 screendump** | §七（本轮实际补入） |

**一句话**：初赛六件套（技术方案文档 / 代码仓库 / 构建配置 / 自动化测试脚本 / 运行日志 / 演示视频）
**5 件已齐，缺演示视频**；仓库主体合规，混入 2 类非交付物（共 21 个文件）；
另有 5 处"评审入口"缺失与 4 处自述失实。**此外查出一处此前未被发现的严重缺陷：主功能证据轮的
screendump 根本没入库，已在本轮补齐 35 张**（详见 §七）。

---

## 二、比赛规定的提交清单（原文出处）

**§六 材料清单（六件套原文）**：

> 「初赛阶段统一基于 QEMU 模拟平台进行开发，采用材料评审形式。参赛队伍提交**技术方案文档、代码仓库、构建配置、自动化测试脚本、运行日志和演示视频**等材料。」

**评分表逐项反推的必交物证**（"缺证据按项计 0 分"，故等同必交）：

| 评分项 | 分值 | 原文要求的物证 |
|---|---|---|
| 图形环境启动与稳定性 | 20 | screendump 截图 + 启动日志（连续 ≥10 min、compositor 无退出） |
| 浏览器基础功能 | 20 | screendump 截图 + 日志 + **完整运行命令** |
| 系统兼容性与移植分析 | 25 | ①缺口清单 + 复现方法（≤8）②高质量 patch 被上游合并（≤3）③与 Linux 行为基线对比 |
| 性能观测与量化方法 | 15 | ①测量脚本与流程可复现 ②指标覆盖 ≥4 类 ③每项 ≥5 次取中位数 + 波动范围 ④**性能改善数据**（以首个可运行版本 git tag 为基线） |
| 技术文档与代码规范 | 10 | 设计报告结构完整 + 关键代码与配置说明详实 |
| 演示效果 | 10 | **完整流程录屏** + 现象与数据可复现 |

**§七 附加要求**：提交数据须注明**宿主机 CPU 型号、内存、QEMU 版本、操作系统**；
before/after 须**存档 git tag 与原始数据**，供组委会复核存档代码；
功能证据统一采用 **QEMU monitor screendump**，主机屏幕录像仅作演示辅助。

---

## 三、✅ 合规项（逐目录对照）

### 3.1 顶层结构总览

| 顶层路径 | 文件数 | 体积 | 判定 | 对应的赛题要求 |
|---|---:|---:|---|---|
| `evidence/` | 9132 | 364.97 MiB | ✅ 合规 | §六「运行日志」+ 评分表「screendump 截图 / 启动日志 / 现象与数据可复现」 |
| `report/` | 88 | 1.15 MiB | ✅ 合规 | §六「技术方案文档」；25 分兼容性分析 + 10 分文档的主载体 |
| `report/patches/`（17 patch + README） | 18 | 0.19 MiB | ✅ 合规 | 评分表「修复与补丁实现质量 12 分（上游合并 4 分/项）」 |
| `report/xk-mm-accounting-design/` | 13 | — | ✅ 合规 | 内核改动设计文档（兼容性 25 分的支撑材料） |
| `report/rendered-pages/*` | 6 | 0.21 MiB | ✅ 合规 | 三页渲染结果与 assert JSON，对应「正确渲染组委会指定 HTML」 |
| `scripts/` | 370 | 2.61 MiB | ✅ 合规 | §六「自动化测试脚本」+「测量脚本与流程可复现 5 分」 |
| `scripts/t490/platform.env` | 1 | 4.9 KiB | ✅ 合规 | §六「构建配置」；项目内 QEMU 参数的**唯一真源** |
| `scripts/testpage/**` | 14 | 0.49 MiB | ✅ 合规 | 「指定 HTML 正确渲染」的页面三件套 + 像素判据参考图 |
| `testpages.tar.xz` | 1 | 6.4 KiB | ✅ 合规 | 同上，guest 注入用的打包件 |

### 3.2 `scripts/` 细分

| 子目录 | 文件数 | 判定 | 说明 |
|---|---:|---|---|
| `scripts/t490/`（含 `README.md` 19.2 KB、`platform.env`） | 317 | ✅ 合规 | 平台合规预检、会话编排、autorun 系列 134 个、p0–p4 补丁应用器、CDP/QMP 输入驱动、measure/reproduce —— 「自动化测试脚本 + 测量可复现」的主体 |
| `scripts/testpage/`（含 `reference/` 9 张参考图） | 14 | ✅ 合规 | 三页套与像素判据常量来源 |
| `scripts/`（根） | 11 | ✅ 合规 | `run-session.py`（36.7 KB，含**平台合规断言**）、`collect_single_metrics.py`、`measure*.py/sh`、`ppm2png.py`、`env-check.sh`、`profile-single-host.sh` |
| `scripts/wsl2/` | 28 | ⚪ 边缘 | WSL2 阶段脚本；当前主平台为 T490 原生 Ubuntu（§七要求纯 TCG，WSL2 不满足）。建议 README 标注「历史阶段，非当前复现路径」 |

### 3.3 `evidence/` 资产分类（364.97 MiB）

| 类别 | 文件数 | 体积 | 判定 |
|---|---:|---:|---|
| `console.log`（串口日志） | 2482 | 157.24 MiB | ✅ 合规（启动日志/运行日志本体） |
| 结构化判据 `.json/.txt/.csv/.jsonl` | ~6390 | ~20 MiB | ✅ 合规（assert JSON、`timestamps.csv`、`manifest.txt`、`env.txt`、`raw.csv`、`summary.json`） |
| `.png`（人类可读截图） | 84 | 2.37 MiB | ✅ 合规（screendump 转换件） |
| `.ppm`（原始帧缓冲） | **172** | 186.04 MiB | ✅ 合规但冗余，见 §六.1 |
| `_ppm-sha256-t490-20261005.txt` | 1 | 0.31 MiB | ✅ 合规（**2415 行** sha256 清单） |

**关键功能证据核验**（`2026-10-02_t490-single-initial-r5/`，29 个跟踪文件）：

- `ppm-summary.txt`：`GATE strict_fail=0 probe_fail=0` → **`GATE: PASS`**；严格判据 7/7 × 10 张全通过；尺寸不一致 0 张；
- `ppm-assert-shot-*.json` × 10 + `ppm-diff-*.json` × 9；`console.log` / `cmd.txt` / `env.txt` / `manifest.txt` / `build-manifest.txt` / `timestamps.csv` / `platform-check.txt` / `platform-compliance.txt` 齐备；
- 全部 10 张 screendump **哈希相同**（`afe8ba58…`），与 `ppm-summary.txt` 记「心跳=0/9」一致 —— 官方 index 页静态无变化，**属预期**，不是采集失败；
- 🔴 **该轮此前 10 张 ppm/PNG 一张都没入库** —— 见 §七，已修复。

**性能证据核验**（`2026-10-02_measure-single-perf3/` + 5 个配对轮）：

- `raw.csv`：5 轮 × 5 指标 = 25 行原始数据 ✓
- `summary.json`：`samples=5`、`median`、`min`、`max`、`range` 齐备 ✓
- `host.txt`：`QEMU emulator version 10.2.1`、内核与镜像 sha256 ✓
- **配对轮目录确实存在**：`2026-10-02_t490-single-perf3-01-152259` … `-05-154454`，**每轮 27 个文件**（含 `console.log`、`guest/` 12 个文件）✓ ⇒ **原始数据未丢失**
- ⚠️ `round-01.log` … `round-05.log` 全为 **0 字节**（见 §六.3）

**宿主机指纹核验**（§七(二)4 要求"注明 CPU 型号、内存、QEMU 版本与操作系统"）：

`env.txt` 含 `cpu_model: Intel(R) Core(TM) i7-8665U CPU @ 1.90GHz`、`cpu_logical: 8`、
`mem_total: 14.7 GiB`、`os_pretty: Ubuntu 26.04.1 LTS`、`qemu-system-aarch64: QEMU emulator version 10.2.1`
—— **四项齐备 ✓**

### 3.4 ⚪ 边缘项（非交付物，保留正常，但需给定位）

| 路径 | 说明 |
|---|---|
| `AGENTS.md`（3438 B） | 面向 AI 编码工具的仓库指引；对复现也有用，但对评委不是材料 |
| `.gitignore`（2506 B）/ `.gitattributes`（1295 B） | 仓库元数据。`.gitattributes` 让 `evidence/**` 逐字节保持一致，**有实质作用，必须保留** |
| `docs/赛题六-前期准备清单与分阶段执行指南.md` / `docs/赛题六-基础任务操作手册.md` | 项目自建操作手册，可算技术文档补充 |
| `docs/refs/ozone_overview.md` / `ozone_overview.zh-CN.md` | 上游 Chromium 参考文档（引用材料，非本项目产出） |
| `tools/build_hd_animation.py`（1433 B） | 生成 `cool_cat_float_hd.gif/webp` 的动图小工具，与赛题六评分项**无对应关系**，建议移出 |

---

## 四、❌ 多余项（21 个文件，建议移出提交包）

### 4.1 `docs/报名资料/` —— 组委会下发的原始材料，13 个文件 / 5.66 MiB

| 文件 | 为什么多余 |
|---|---|
| `关于第三届"中国电子杯"…报名的通知.pdf` | 组委会下发的通知，非选手产出 |
| `附件1：…赛道方案.pdf` | 同上 |
| `附件2/1 赛题一…（上海贝岭）.pdf` | **其他赛题** |
| `附件2/2 赛题二…（华大九天）.pdf` | **其他赛题** |
| `附件2/3 赛题三…（飞腾）.pdf` | **其他赛题** |
| `附件2/4 赛题四…（中国长城）.pdf` | **其他赛题** |
| `附件2/5 赛题五…（中软）.pdf` | **其他赛题** |
| `附件2/6 赛题六…（麒麟软件）.pdf` | 本队赛题原文 —— **唯一有保留价值的 1 个** |
| `附件2/7 赛题七…（中电金信）.pdf` | **其他赛题** |
| `附件2/8 赛题八…（中电云）.pdf` | **其他赛题** |
| `附件2/9 赛题九…（奇安信）.pdf` | **其他赛题** |
| `附件3：…团队报名表.docx` | 空白报名表模板 |
| `附件4：…报名汇总表.xlsx` | 空白汇总表模板 |

> **处置**：仅留 `附件2/6 赛题六….pdf`（或在 README 给出官方链接后全部删除）。
> **9 个赛题的命题书同时出现在一个赛题的提交仓库里，会给评委"仓库未整理"的直观印象。**

### 4.2 `.workbuddy/memory/` —— AI 助手工作记忆，8 个文件 / 0.18 MiB

`2026-09-16.md` / `2026-09-20.md` / `2026-09-21.md`（67 KB）/ `2026-09-22.md`（61 KB）/
`2026-10-02.md` / `2026-10-05.md` / `2026-10-06.md` / `MEMORY.md`。

- 不属于六件套任何一项，也不是"设计报告"（是逐日过程流水，含大量已被推翻的中间结论）；
- **信息暴露**：含本机绝对路径 `C:\Users\12697\.ssh\id_ed25519_t490`、内网 IP
  `192.168.1.217` / `10.249.63.140`、Gitee 个人仓库地址，以及推送/凭据排查过程；
- 与 `report/42` 自列检查项「复核不含私钥、**临时 tmp/ 文件和个人路径凭据**」直接冲突；
- 已确认**未泄露**任何真实私钥或 token（全仓 `BEGIN (RSA|OPENSSH|EC) PRIVATE KEY` / `ghp_` /
  `github_pat_` / `AKIA[0-9A-Z]{16}` 扫描均无命中）。

> **处置**：从提交分支移除。若要保留工作过程，另建 `docs/process-log/` 并把内网地址与本机路径脱敏。

### 4.3 未入树但需说明的大文件

| 文件 | 状态 | 说明 |
|---|---|---|
| `agentos-disk.img.xz`（318 MB） | 被 `.gitignore` 正确排除 ✓ | 未入树，合规。但**取回地址未在仓库内任何可见文档记录** → §五 M5 |
| `evidence/2026-09-22_t490-stage0-freeze/src-snapshot.tar.gz` | 已入树 | 内核源码快照，与"代码仓库"相关，可保留 |

---

## 五、❌ 缺失项（评分表点名，仓库内确无）

| # | 缺失项 | 严重度 | 依据 | 现状核查 |
|---|---|---|---|---|
| **M1** | **演示视频（完整流程录屏）** | 🔴 高 | §六六件套之一；评分表「演示效果 10 分 → 完整流程录屏 6 分」 | 审计基线时全仓视频类文件 = **0 个**。现已有 `report/rendered-videos/*.mp4`（screendump 时延样例），**但那是"证据帧合成"，不是"完整流程录屏"**，不能顶替本项。录制方案见 `report/51` 与 `docs/demo/` 两份操作卡 |
| **M2** | **根目录 `README.md`（评审入口）** | 🔴 高 | 「技术文档与代码规范 10 分 — 设计报告结构完整」 | 仓库根目录**无 README**。评委落地页只有 `AGENTS.md`（面向 AI 编码工具），1 秒内看不到"这是什么 / 怎么复现 / 材料在哪" |
| **M3** | **正式《技术方案文档》** | 🟠 中 | §六「技术方案文档」；`report/42` 自列未完成项 | `report/01–52` 是**工作笔记形态**（含勘误、撤销结论），不是一份结构完整的设计报告；缺组委会模板要求的队伍/成员/联系方式/盖章页 |
| **M4** | **内核源码仓库指引** | 🟠 中 | §七(二)3「提交时存档 git tag 与原始数据，组委会复核存档代码」 | 内核改动在 Gitee 个人 fork 分支 **`t490-chromium-runtime`（= `2a1b101`）**，但该分支名在**已入树的** `report/`、`docs/`、`AGENTS.md` 中**零命中**（仅在 `.workbuddy/memory/` —— 而该项本身被判定为多余）。仓库内也找不到基线 tag `v0.1-first-runnable`（`f8b9224`）/ `v0.2-compat-p0p4`（`7b60564`）与 `dcb862c9…` / `c2eabd52…` 两个 commit 的对应关系 |
| **M5** | **318 MB 镜像的 Release 附件地址** | 🟡 低 | §六「构建配置 / 代码仓库」 | `agentos-disk.img.xz` 正确排除未入树 ✓，但取回地址未在仓库内任何可见文档记录 |

**另有非阻塞瑕疵**：

- `report/patches/` 编号 **0001–0018 缺 0008**（跳号）。`README.md` 已记录覆盖关系，
  建议显式写"0008 未产出"以免评委误判丢文件。
- **性能改善 before/after 数据缺失**：`report/47` S19 自述"只有 `measure-single-perf3` 单配置数据，
  **没有'首个可运行版本 vs 当前版本'的配对测量**"。评分表「性能改善数据 3 分…无对比数据 0 分」。
- 8 个 0 字节文件：`measure-single-perf3/round-0{1..5}.log`（见 §六.3）+
  `profile-single/{perf.data, perf-record.stdout, round.log}`（权限受限，已有 `perf-record.stderr` 说明，属如实归档 ✓）。

---

## 六、⚠️ 口径不一致（仓库自述 vs 事实）

### 6.1 `.gitignore` 的 ppm 规则：对未跟踪文件有效，但从未取消已有跟踪 ⚠️

`.gitignore:44` 声明：

```
evidence/**/*.ppm
```

**实测的精确语义**（三个样本对照，2026-10-06）：

| 样本文件 | 跟踪状态 | `git check-ignore -v` 返回 |
|---|---|---|
| `evidence/2026-09-21_t490-basic-render-audio-shot-08.ppm` | **已跟踪** | **rc=1**，无输出 |
| `evidence/.../single-initial-r5/screenshots/shot-01-at0180s.ppm` | 未跟踪 | **rc=0**，打印规则 `.gitignore:44:evidence/**/*.ppm` |
| `evidence/.../interaction-single-e2e-r20/screenshots/shot-01-at0120s.ppm` | **已跟踪**（本轮补齐） | **rc=1**，无输出 |

⇒ **结论**：`git check-ignore` **会考虑跟踪状态** —— 已跟踪的文件一律报"未被忽略"。
所以规则本身是有效的，问题在于**它对已经入库的 172 张 ppm 无能为力**，`git add` 也不会取消跟踪。
（两版报告的差异正源于此：`report/49` 测的是已跟踪文件得 rc=1，`report/50` 测的是未跟踪文件得 rc=0，
**两者都对，但都只覆盖了一半**。详见 §八。）

**关联误导**：该规则的提交说明写着「影响/验证：…**git status 中 ppm 条目为 0**」。
这句话是**误导**——`git status` 只显示未跟踪/已修改文件，与"是否入库"无关。
现状：仓库里 ~50% 的体积（186 MiB / 374 MiB）是"声明不入库"的 ppm。

### 6.2 `AGENTS.md` 的 Large binaries 小节与事实不符

> 「`evidence/**/*.ppm` … Their SHA-256 manifests … are committed in their place; the originals stay on the T490 host」

事实：原图**也在仓库里**（172 张），而 `_ppm-sha256-t490-20261005.txt` 覆盖的是 T490 上**全部 2415 张**。
⇒ 表述应改为：清单覆盖 T490 全部 ppm；仓库内保留其中**判据轮与演示轮**的帧，诊断轮只留清单。

### 6.3 性能批次的 `round-0*.log` 全为 0 字节

`2026-10-02_measure-single-perf3/round-01.log` … `round-05.log`（同批 `measure-single-perf` /
`perf2` 亦同）均为 **0 字节**。实际轮次日志在配对目录 `2026-10-02_t490-single-perf3-0N-*` 中
（每轮 27 文件），所以原始数据**未丢失**；但 0 字节文件出现在性能证据目录里，会被评委视为"缺证据"。

> **处置**：补内容，或删空文件，或在同目录 `README` 说明"分轮日志见 `../2026-10-02_t490-single-perf3-0N-*`"。

### 6.4 `report/41` 的"内核指纹"与 `env.txt` 的 `git_commit` 是两个量，报告未说明

`report/41` 表中列 `Kernel SHA-256 = dcb862c9…`，而 `2026-10-02_t490-single-perf3-0N-*` 等 8 个轮的
`env.txt` 一律显示 `git_commit: c2eabd5244…`、`git_describe: basic-baseline-20260922-dirty`。
核对 `build-manifest.txt` 后确认**证据自洽**：

| 量 | 值 | 出处 |
|---|---|---|
| 内核**仓库** HEAD | `c2eabd5244…`（`-dirty`） | `env.txt` / `build-manifest.txt` 的 `git rev-parse HEAD` |
| 内核**镜像** `kernel.bin` sha256 | `dcb862c9…` | `build-manifest.txt` 的 `sha256sum kernel.bin` |

r5 与 perf3-01 的 `kernel.bin`、基础镜像、页面三件套 sha256 **完全一致**，
故"perf 批次与功能候选同内核"成立 ✓。但 `report/41` 未区分这两个量，易被误读为矛盾；
且 `git_describe` 含 `-dirty`，「采数二进制 ≠ 存档代码」的质疑点仍在
（`report/15` R1 已识别；**2026-10-05 已把 T490 工作区 41 项改动按主题提交为 5 个 commit，工作区转 CLEAN**，
但**旧证据里的 `-dirty` 字样不会改变**，需在正式技术方案文档中说明"采数时的树已被事后提交"）。

---

## 七、🔴 screendump 漏交：完整排查与已执行修复

> 这是**本次核对查出的最重要缺陷**，且比 v1 最初判断严重得多。

### 7.1 缺陷范围（全仓排查，非抽样）

```bash
# 统计口径：工作区有 ppm 的轮次 vs 该轮 ppm 在 git 中的跟踪数
```

| 范围 | 数量 |
|---|---|
| T490 `~/xk6/evidence` 上的 ppm 总数 | **2415** |
| 本地工作区 ppm 总数 | **730** |
| 含 ≥5 张 ppm 的轮次 | **81 个** |
| 这 81 个轮次盘上合计 | **591 张** |
| 其中**未入库** | **431 张** |
| 其中属于 **`report/42` 推荐提交项**的 | **22 张**（r5 10 + xdg-libwayland r6/r7/r8 各 4） |
| 另有 r19/r20/r21 共 **13 张**（v1 阶段发现） | 13 张 |

### 7.2 根因

`.gitignore` 的 `evidence/**/*.ppm` 只对**未跟踪**文件生效：

1. 规则加入**之前**已 `git add` 的 ppm → 规则管不到（如 09-20/09-21 那批诊断轮，172 张）；
2. 规则加入**之后**新产生的 ppm → 在 `git add` 时被**静默跳过**（r19/r20/r21、r5、r6~r8、以及 409 张诊断轮）；
3. 只有 `git add -f` 能强制加入。

v1 之所以只发现 r19/r20/r21，是因为当时只核对了"`manifest.txt` 声称的成功数 vs 目录里实际张数"；
而 **r5 与 r6~r8 更彻底** —— 它们连"规则生效前入库"的机会都没有，`screenshots/` 目录在工作区存在
但**在 git 树里根本不存在**（git 不跟踪空目录），所以从 `git ls-tree` 看就像"没有截图目录"。
（`report/50` §6.4 说的"r5 没有 `screenshots/` 子目录"在 **git 树**层面是对的；
v1 说的"r5 只有 ppm 没有 png"在 **工作区**层面是对的 —— 同一事实的两个粒度，见 §八。）

### 7.3 已执行的修复（三个 commit，共补入 45 张）

| commit | 内容 | 张数 |
|---|---|---|
| `6b88d58` | r19 / r20 / r21 的 interaction 与 layout 证据轮 | **13** |
| `a3df0ef` | **r5 主功能证据轮** + Wayland 协议对照 r6/r7/r8 | **22** |
| `18f40c6` | 新增的 VNC 演示轮（非补齐，是新证据） | 10 |

**验证**（每张都逐文件核对，不是抽检）：

| 验证项 | 结果 |
|---|---|
| r19/r20/r21 回传后与 T490 重算 sha256 比对 | **17/17 一致** |
| r5 + r6/r7/r8 与库内 `_ppm-sha256-t490-20261005.txt` 比对 | **22/22 一致**，不符 0、缺文件 0 |
| 仓库原有 4 张（r19/r20/r21 的部分）与回传件比对 | 一致 |
| 入库方式 | 逐路径 `git add -f`（**不用目录形式**，避免连带暂存同目录其它被忽略文件） |
| 补齐后跟踪数 | r19 5/5、r20 5/5、r21 7/7、r5 10/10、r6 4/4、r7 4/4、r8 4/4 |
| 同时补 PNG | 32 张（r19/r20/r21 + r5 + r6/r7/r8），让评委**可直读** |
| 内容核验（非只看哈希） | r20 末帧 PNG 可见官方 interaction 页「**核心检查 6/6 全部通过**」+ 回显 `hello x-kernel` + 点击计数 1 |

**当前状态**：`git ls-files "*.ppm"` = **217 张**（审计基线时 172）。

### 7.4 仍未入库的 409 张（有意保留，非缺陷）

均为 09-20 ~ 10-02 的**过程诊断轮**（`mp-*`、`x11p*`、`input-seat*` 等），
每张都有 `_ppm-sha256-t490-20261005.txt` 里的哈希可校验，**按既定策略留在 T490**。

> **入库策略（2026-10-06 定，已写入 `.workbuddy/memory/MEMORY.md`）**：
> **判据轮与演示轮的 screendump 都入库**；只有纯诊断轮留在 T490。
> 这与"排除全部 ppm"的旧策略不同，须同步修正 `.gitignore` 与 `AGENTS.md` 的表述（见 §六.1/6.2）。

---

## 八、对两版差异的逐条裁定

| # | 争议点 | v1（`report/49`）主张 | v2 前身（`report/50`）主张 | **裁定（实测）** |
|---|---|---|---|---|
| 1 | `git check-ignore` 返回码 | rc=1（未忽略） | rc=0（规则命中），并据此称 v1 "结论有误" | **两者都对，各测一半**：rc 取决于**该文件是否已被跟踪**。v1 测的是已跟踪文件 → rc=1；v50 测的是未跟踪文件 → rc=0。**50 号文"49 结论有误"的判断本身不成立**；正确表述见 §6.1 |
| 2 | r5 有没有 `screenshots/` 目录 | "只有 ppm 没有 png"（工作区视角） | "没有 `screenshots/` 子目录"（git 树视角） | **两者都对，粒度不同**。工作区**有**该目录（10 张 ppm）；git 树中该目录**不存在**（0 个跟踪文件）。但 50 号文未点出"工作区有"，导致读者会以为截图不存在 —— 现已由 §七.3 补齐，两种表述都成立 |
| 3 | `report/41` 的内核指纹 | 未提及 | 新增：sha256 与 git_commit 是两个量，证据自洽 | **采纳**，列为 §6.4（并补充"T490 工作区已于 10-05 转 CLEAN，但旧证据里的 `-dirty` 不会改变"） |
| 4 | `round-0*.log` 0 字节 | 列为"非阻塞瑕疵" | 列为独立口径不一致项 §6.3 | **采纳 50 的升格**，列为 §6.3（它确实会被评委读成"缺证据"） |
| 5 | 多余项计数 | 2 类（13 + 8 = 21 个文件） | 2 类 / 21 个文件 | **一致**（两版独立得出同一数字，可交叉验证） |
| 6 | 证据核验深度 | 目录级分类 | 补入 r5 `GATE: PASS`、perf3 `raw.csv`/`summary.json`/配对轮存在性、`env.txt` 宿主指纹四项齐备 | **采纳 50 的细化**，全部并入 §三.3 |

---

## 九、建议动作清单（按优先级）

| 优先 | 动作 | 影响的评分项 | 状态 |
|---|---|---|---|
| **P0** | 补 **完整流程录屏** | 演示效果 6/10 | ⏸ 方案已就绪（`report/51`、`docs/demo/`），**待录制** |
| **P0** | 写**根目录 `README.md`**：项目一句话 + 材料索引表（六件套 → 路径）+ 复现最短路径 + 内核仓库 / 镜像取回链接 | 文档 5/10 | ⏸ 未做 |
| ~~P0~~ | ~~为 r5 补 PNG，让主功能证据可直读~~ | 图形 20 + 浏览器 20 | ✅ **已完成**（`a3df0ef`，32 张 PNG） |
| ~~P0~~ | ~~补齐被漏交的 screendump~~ | 图形 20 + 浏览器 20 + 布局/交互 | ✅ **已完成**（35 张，`6b88d58` + `a3df0ef`） |
| **P1** | 移除 `docs/报名资料/`（仅留赛题六 PDF）与 `.workbuddy/memory/` | 评审印象 + 个人路径暴露 | ⏸ 未做 |
| **P1** | 在 README 登记 **Gitee 内核分支 `t490-chromium-runtime`(`2a1b101`) + 基线 tag `v0.1-first-runnable`(`f8b9224`) / `v0.2-compat-p0p4`(`7b60564`) + 镜像 Release 附件地址** | 兼容性 25 分（复核存档代码） | ⏸ 未做 |
| **P1** | 修正 `.gitignore` / `AGENTS.md` 的 ppm 失实表述，落定"判据轮+演示轮入库、诊断轮留 T490"策略 | 文档规范性 | ⏸ 未做 |
| **P2** | 按组委会模板产出**正式《技术方案文档》**（含队伍/成员/联系方式/盖章页；并说明旧证据中的 `-dirty` 已由 10-05 的 5 个 commit 消除） | 文档 5/10 | ⏸ 未做 |
| **P2** | 补 before/after 配对测量（以 `v0.1-single-initial` 为基线，同页面同指标 ≥5 轮） | 性能 3 分 | ⏸ 未做 |
| **P2** | 清理 `round-0*.log` 空文件或在同目录加说明 | 性能项完整性 | ⏸ 未做 |
| **P3** | `report/patches/README.md` 显式标注"0008 未产出"；`scripts/wsl2/` 与 `tools/` 加历史/工具标注 | 文档完整性 | ⏸ 未做 |

---

## 附：命令与数据来源

```bash
# 全量文件树（GitHub API，未截断）
curl -fsSL --ssl-no-revoke \
  "https://api.github.com/repos/SlieNce810/xkernel-chromium-runtime/git/trees/codex/initial-round-single-process?recursive=1"

# 一致性
git rev-parse HEAD                                       # 审计基线 efe8933…；当前 a3df0ef
git rev-parse origin/codex/initial-round-single-process  # 审计时同值
git status --short                                       # 审计时为空
git ls-files "*.ppm" | wc -l                             # 审计基线 172 -> 当前 217

# ppm 忽略规则语义（关键：rc 取决于跟踪状态）
git check-ignore -v evidence/2026-09-21_t490-basic-render-audio-shot-08.ppm      # 已跟踪 -> rc=1
git check-ignore -v evidence/…/single-initial-r5/screenshots/shot-01-at0180s.ppm # 未跟踪 -> rc=0 + 规则

# 漏交范围排查（工作区有 ppm 但未跟踪的轮次）
git ls-files > /tmp/tracked.txt   # 与 glob 出的 evidence/*/screenshots/*.ppm 做差集

# 凭据扫描（无命中）
grep -rn -E "BEGIN (RSA|OPENSSH|EC) PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|github_pat_|AKIA[0-9A-Z]{16}" report/ docs/ scripts/
```

- 赛题原文：`docs/报名资料/附件2：…/6 赛题六：…(麒麟软件有限公司).pdf`（§六、§七）
- 分支基线 tag：`v0.1-single-initial` → `65161a4`（是分支 HEAD 的祖先）
- 数据来源：GitHub Trees API 全量列表 9620 blob + 778 tree；工作区 `git ls-files` 交叉验证
- 注：核对期间 GitHub 22 端口连接曾被拒（`CRYPT_E_NO_REVOCATION_CHECK`，须 `curl --ssl-no-revoke`），
  但本地 `HEAD` 与 `origin/codex/initial-round-single-process` 一致，故以本地 git 对象为权威依据
