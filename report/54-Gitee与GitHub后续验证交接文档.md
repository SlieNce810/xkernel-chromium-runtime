# Gitee 与 GitHub 后续验证交接文档

整理日期：2026-10-09  
交接范围：`xkernel-chromium-runtime` 材料仓库、x-kernel 内核仓库、T490 验证与提交材料收口。  
交接原则：先固定远端 commit 和本地输入，再验证；旧 evidence 只读保留；失败轮次不删除、不覆盖。

本文给接手人使用。接手人应把命令输出、T490 证据目录和结论写回本仓库的新报告或交付目录，不直接改写旧报告中的历史结果。

## 1. 交接时已经核对的仓库状态

### GitHub：材料与验证仓库

- 页面：[SlieNce810/xkernel-chromium-runtime](https://github.com/SlieNce810/xkernel-chromium-runtime)
- SSH remote：`git@github.com:SlieNce810/xkernel-chromium-runtime.git`
- 本地工作分支：`codex/initial-round-single-process`
- 本地 HEAD：`f33e5faa8f2835cbfb9ff63ec843520248b669e4`
- 本地 remote 分支 `origin/codex/initial-round-single-process`：`efe89331d2425b2d8b5c14b6a7f80ddab47bcbdb`
- 本地分支比该 remote **领先 7 个提交**。远端 `main` 也仍指向 `efe8933`，因此远端页面目前看不到本地最近的 OBS、VNC、证据和报告更新。
- 这 7 个待同步提交（从旧到新）是：`6b88d58`（补 r19/r20/r21 PPM）、`fca83ef`（报告 49/51/52 与证据工具）、`18f40c6`（VNC 演示轮/RFB/OBS 操作卡）、`3f0c213`（三线执行记录）、`a3df0ef`（补 r5 与 xdg PPM/PNG）、`c351a9f`（合并 report/49 与 report/50）、`f33e5fa`（OBS 32.1 验证与无头边界）。
- 本地已有 tag：`v0.1-single-initial`；远端 tag 是否已发布必须由接手人再用 `git ls-remote` 确认，不能从本地 tag 推断 GitHub 已有。
- 当前本地工作区不是交接后的干净状态：有 `.workbuddy/memory/MEMORY.md` 修改、一个外部资料目录下的 `.workbuddy/` 未跟踪目录，以及本交接相关的新文件。接手人不得直接执行全目录 `git add .`。

### Gitee：内核仓库存在两个不同角色

接手人必须先区分下面两个地址，不能把它们合并为“Gitee 仓库”。

| 角色 | 地址 | 已核对的远端引用 | 用途 |
|---|---|---|---|
| 官方上游 | [openkylin/x-kernel](https://gitee.com/openkylin/x-kernel) | `main` = `53d894bdcb919646b1dd56e9e5e86868cb0dd02f`；`feature/wayland-drm-input-test` = `783df7d7...` | 对照上游代码、确认上游是否包含某项修复 |
| 参赛内核个人 fork | [mofan0810/x-kernel](https://gitee.com/mofan0810/x-kernel) | `main` = `cea097dfde8d6a4b057e03152f9462008e3c1c5e`；`t490-chromium-runtime` = `2a1b101ccf97ed255821b85628f366700089cda3`；tag `v0.1-first-runnable` 的 peeled commit = `f8b92247922fb1127138bbd8830bec504913908f`；tag `v0.2-compat-p0p4` 的 peeled commit = `7b6056439f3ef276ccbde6c466be95ebea5f1d96`；`basic-baseline-20260922` 的 peeled commit = `c2eabd524461c79631d7b737f4c8fa09bd24e96e` | T490 构建和提交材料应追溯的参赛内核来源 |

`openkylin/x-kernel` 的 `main` 与个人 fork 的 `t490-chromium-runtime` 不是同一个引用。接手人不得在 T490 上直接用 Gitee 官方 `main` 替换已验证的参赛分支。

### 已知验证坐标

- 归档的单进程功能轮使用过 kernel SHA 前缀 `dcb862c9...`；交互/布局和演示相关轮次记录过 `7584653b...`。
- 基础镜像历史 SHA 前缀：`bb25e0b2...`。
- p31 用户态 overlay 历史 SHA 前缀：`56dba17c...`。
- 本地报告已明确：单进程首页和稳定性有证据；virtio-input 内核事件消费、独立 renderer/zygote、多窗口/多标签仍需要按实际结果记录，不能自动沿用单进程 PASS。
- layout 的“6/6 结论条”在旧材料中存在证据目录不一致问题；补齐同一轮证据后才能把它写成该轮的完整 PASS。

## 2. 接手人的第一阶段：只读固定两个仓库

在新的工作目录执行。以下命令是只读核对，不要先 `git pull`、`git reset`、`git checkout` 或 `git push`。

```bash
mkdir -p "$HOME/handoff-2026-10-09"
cd "$HOME/handoff-2026-10-09"
git ls-remote --symref git@github.com:SlieNce810/xkernel-chromium-runtime.git HEAD refs/heads/main refs/heads/codex/initial-round-single-process refs/tags/v0.1-single-initial
git ls-remote --symref https://gitee.com/openkylin/x-kernel.git HEAD refs/heads/main refs/heads/feature/wayland-drm-input-test
git ls-remote --symref https://gitee.com/mofan0810/x-kernel.git HEAD refs/heads/main refs/heads/t490-chromium-runtime refs/tags/v0.1-first-runnable refs/tags/v0.1-first-runnable\^{} refs/tags/v0.2-compat-p0p4 refs/tags/v0.2-compat-p0p4\^{} refs/tags/basic-baseline-20260922 refs/tags/basic-baseline-20260922\^{}
```

预期：输出中应能明确看到各地址的 HEAD、分支和 tag SHA。对于带 `^{}` 的行，预期分别得到 peeled commit `f8b9224...`、`7b60564...`、`c2eabd5...`。若某个引用不存在、网络访问失败或远端 SHA 与本文记录不一致，先把完整输出保存为 `remote-refs.txt`，标记 `REMOTE_DRIFT`，不要继续做二进制结论。

接着核对本地 GitHub checkout：

```bash
cd /path/to/中电杯
git remote -v
git branch -vv
git rev-parse HEAD
git rev-parse origin/main
git rev-parse origin/codex/initial-round-single-process
git log --oneline origin/codex/initial-round-single-process..HEAD
git status --short
git tag --list
```

预期：能复现“本地 HEAD 为 `f33e5fa`、GitHub remote 分支为 `efe8933`、本地领先 7 提交”的交接基线。若 GitHub 远端已经变化，以新输出为准，并把差异列入 `github-drift.md`。不要把工作区未跟踪文件提交进去。

接手人必须回答三件事：

1. GitHub 远端是否已经包含本地最近 7 个提交；
2. `v0.1-single-initial` 是否已在 GitHub 远端发布；
3. 计划交付的分支是继续使用 `codex/initial-round-single-process`，还是创建新的 `codex/` 分支。

创建新分支、合并或 push 属于外发/历史变更动作，本交接只要求准备审计结果，不默认授权执行 push。

## 3. 接手人的第二阶段：核对 Gitee 内核来源

### 3.1 核对参赛 fork 的分支和 tag

```bash
git clone --no-checkout https://gitee.com/mofan0810/x-kernel.git "$HOME/handoff-2026-10-09/x-kernel-fork"
cd "$HOME/handoff-2026-10-09/x-kernel-fork"
git fetch --all --tags --prune
git show -s --format='%H%n%P%n%ad%n%s' refs/heads/t490-chromium-runtime
git show -s --format='%H%n%P%n%ad%n%s' refs/tags/v0.1-first-runnable
git show -s --format='%H%n%P%n%ad%n%s' refs/tags/v0.2-compat-p0p4
git merge-base refs/tags/v0.2-compat-p0p4 refs/heads/t490-chromium-runtime
git diff --stat refs/tags/v0.1-first-runnable..refs/heads/t490-chromium-runtime
```

预期：`t490-chromium-runtime` 能解析到 `2a1b101...`，两个基线 tag 的 peeled commit 能解析到本文第 1 节的 SHA；`merge-base` 和 diff 结果要保存。Gitee 的 `git ls-remote` 可能先显示附注 tag 对象 SHA；验证人必须再查询 `refs/tags/<tag>^{}` 或用 `git rev-parse <tag>^{}`，交付时写 peeled commit，不能把 tag 对象 SHA 当作构建 commit。

### 3.2 与官方上游比较

```bash
git clone --no-checkout https://gitee.com/openkylin/x-kernel.git "$HOME/handoff-2026-10-09/x-kernel-upstream"
cd "$HOME/handoff-2026-10-09/x-kernel-upstream"
git fetch --all --prune
git show -s --format='%H%n%P%n%ad%n%s' origin/main
git branch -r --contains 2a1b101ccf97ed255821b85628f366700089cda3
git log --oneline --decorate --all --grep='831\|DRM\|Chromium\|wayland' -i -20
```

预期：能证明 `2a1b101` 是参赛 fork 的提交；若官方上游没有该提交，属于 fork 与上游的正常差异，不能写成“官方 main 已包含全部参赛改动”。关于上游 MR 或提交，只能在找到可追溯的提交、页面或 diff 后写入材料。

### 3.3 补丁应用前检查

在参赛 fork 的**临时 detached checkout** 中检查，不在工作中的 T490 源码树直接应用：

```bash
cd "$HOME/handoff-2026-10-09/x-kernel-fork"
git switch --detach refs/tags/v0.2-compat-p0p4
git status --short
git apply --check /path/to/中电杯/report/patches/0014-feat-inotify-subsystem.patch
git apply --check /path/to/中电杯/report/patches/0015-feat-evdev-sysfs-and-virtio-input.patch
git apply --check /path/to/中电杯/report/patches/0016-feat-proc-stat-uptime-loadavg-meminfo.patch
git apply --check /path/to/中电杯/report/patches/0017-feat-knet-af-unix-credentials-and-socket-options.patch
git apply --check /path/to/中电杯/report/patches/0018-fix-ksyscall-ppoll-time64-and-pr-set-pdeathsig.patch
```

补丁文件名以实际 `ls report/patches` 输出为准；若名称不同，先打开 `report/patches/README.md` 对照。输出必须保存。`0011`、`0013` 是已被 `0018`、`0017` 覆盖的历史补丁，不能重复应用。`0012` 基于旧基线，不能未经 `git apply --check` 强行纳入当前提交。

## 4. 接手人的第三阶段：T490 验证顺序

T490 验证应使用本仓库的[逐条手动验证指南](53-T490完整手动验证操作指南（逐条命令无自动化脚本）.md)，每轮使用新的 `evidence/YYYY-MM-DD_t490-<scenario>/` 目录。接手人需要完成下面四个优先级，完成一个才进入下一个。

### P0：恢复可追溯的基础单进程证据

1. 固定 kernel、基础镜像、overlay、三个 HTML 页面 SHA-256。
2. 确认 QEMU 命令为 AArch64、TCG、`cortex-a76`、2 GiB、4 vCPU，包含 virtio GPU、块、网络和键鼠设备。
3. 手动启动 Weston 和 Chromium 单进程首页。
4. 从首页正确出现开始连续观察至少 600 秒，并保留截图、console、时间和 PID 状态。
5. 人工确认首页四类元素正确显示。

P0 完成条件：新 evidence 同时有 `env.txt`、实际 QEMU 命令、输入指纹、console、时间表、至少一组原始 screendump 和结果表；页面正确且稳定区间达到 600 秒。只要任一进程中途退出、重启、页面为空或证据缺失，P0 记 FAIL，保留该轮后用新目录重做。

### P1：真实交互和 layout 证据

1. 默认 `interaction.html` 页面中手动点击运行自检，确认 T1–T6 和 F1 的实际页面状态。
2. 通过 QEMU monitor 的虚拟键盘逐字符输入 `hello x-kernel`，确认文本框和回显区一致。
3. 通过虚拟鼠标点击真实按钮，确认计数由 0 变 1。
4. 手动打开默认 `layout.html`，分别保存首屏与滚动到底部的截图。
5. 只有确实拍到绿色“布局检查 6/6 全部通过”才记录完整 layout PASS；首屏几何正确但结论条没入镜，只记录部分证据。

P1 完成条件：interaction、输入、layout 每项都有本轮原始截图和明确 PASS/FAIL/BLOCKED；不得用 CDP、页面 JS 注入或 `?e2e=1` 自动输入冒充硬件/虚拟设备输入通过。

### P2：多进程边界验证

1. 去掉 `--single-process --no-zygote`，单独使用新的 profile 启动 Chromium。
2. 用 `ps`、`/proc/<pid>/cmdline`、`/proc/<pid>/status` 核对 browser、zygote、renderer 的实际关系。
3. 对多进程场景保存截图、Chromium 日志和 QEMU 命令。
4. 若 renderer/zygote 起不来，保留失败日志，并将其写入兼容性缺口清单；不能沿用单进程结果。

### P3：材料和远端收口

1. 核对报告中的 Gitee 分支、tag、kernel SHA 与新 evidence 完全一致。
2. 核对 GitHub 远端是否已包含本地 7 个提交；形成 `github-sync.md`，列出尚未推送的提交。
3. 核对 `report/49` 中 P0/P1/P2/P3 待办：根 README、Gitee 分支和基线 tag 登记、镜像 Release 地址、技术方案、before/after 配对数据、空的 `round-0*.log`、patch README 的 0008 说明。
4. 做脱敏检查，不能把私钥、个人路径、SSH 命令中的密钥路径和未授权联系信息放进提交包。
5. 只有获得明确授权后，才执行 push；push 前给出待推送 commit 列表和 `git diff --stat`，push 后再用 `git ls-remote` 回读确认。

## 5. 接手人交付物

接手人完成验证后，应交回以下文件；文件名可以带实际日期，但不能覆盖旧 evidence：

| 文件 | 必须包含 |
|---|---|
| `remote-refs.txt` | GitHub、官方 Gitee、个人 Gitee fork 的远端 HEAD、分支、tag SHA |
| `github-sync.md` | 本地 HEAD 与 GitHub 分支差异、7 个待推提交、tag 是否远端存在、是否建议 push |
| `gitee-sync.md` | 官方上游与参赛 fork 的关系、`t490-chromium-runtime`、两个基线 tag、merge-base 和差异 |
| `t490-validation.md` | 每个 P0–P2 项的 PASS/FAIL/BLOCKED/NOT RUN、实际命令、异常和 evidence 路径 |
| `evidence/<date>_t490-handoff-*/` | 环境、QEMU 命令、kernel/image/page SHA、console、时间、原始截图、manifest、结果表 |
| `material-gap.md` | report/49 P0–P3 待办逐项完成状态，未完成项的原因和下一步 |

每个结论必须能回到一个具体的 commit、命令输出或 evidence 文件。只写“已验证”“已同步”而没有引用，视为未完成。

## 6. 接手完成判定

交接任务完成需要同时满足：

1. 三个远端角色（GitHub 材料仓库、官方 Gitee 上游、个人 Gitee 参赛 fork）已分别记录 SHA；
2. 本地 GitHub 工作分支与远端差异已解释，未授权的 push 没有擅自执行；
3. `t490-chromium-runtime` 和 `v0.1-first-runnable`、`v0.2-compat-p0p4` 可被独立解析；
4. T490 至少完成 P0；P1、P2 若失败或未执行，结果表必须如实标为 FAIL/BLOCKED/NOT RUN；
5. 新 evidence 能通过 SHA/manifest 复核，旧 evidence 没被覆盖；
6. 所有 report/49 的材料缺口都有“已完成、未完成或需要授权”的明确状态。

最终对外口径应按实际结果写。例如只完成 P0 时，只能写“单进程基础运行验证通过”；P1 或 P2 有未完成项时，不能写“完整浏览器功能全部通过”。

## 7. 当前不应直接执行的动作

- 不要把官方 Gitee `main` 直接合并到参赛 fork。
- 不要把本地 GitHub 分支直接强推到远端 `main`。
- 不要对整个工作区执行 `git add .`。
- 不要删除旧 evidence、失败轮日志或历史 PPM。
- 不要把 `tmp/` 工作文件当成提交证据。
- 不要把单进程成功写成多进程、硬件键鼠或多窗口已经成功。
- 不要用自动页面参数、CDP 事件或旧 evidence 替代接手人的新一轮现场验证。

## 8. 当前材料收口待办（交接人必须逐项回填）

这些事项在本地核对时仍未完成或需要重新确认：

| 优先级 | 事项 | 完成标准 |
|---|---|---|
| P0 | 根目录 `README.md` 与完整流程录屏 | README 登记 GitHub 分支、Gitee fork 分支、基线 tag、镜像 Release 地址；录屏能覆盖启动、页面、交互和收尾，且不把录屏当唯一功能证据 |
| P1 | 提交分支与大文件收口 | 明确是否同步本地 7 个提交；不把 318 MB 镜像写入 Git；按实际发布渠道记录 Release 附件；检查 `docs/报名资料/` 和 `.workbuddy/memory/` 是否应移出交付分支 |
| P1 | evidence 清理与声明 | 清点并处理 `round-0*.log` 空文件；修正 `.gitignore`、`AGENTS.md` 中关于 PPM 的过时表述；保留原始失败日志，不手改已完成 evidence |
| P2 | 正式技术方案和 before/after | 为至少三个补丁保留前后场景、回归命令、内核 hash 和来源 commit；性能改善必须有一致口径的至少五次 before/after 数据 |
| P2 | layout 结论条 | 在 T490 串行补一轮，截图实际拍到绿色“布局检查 6/6 全部通过”；r21 现有 `layout-verdict-pass=false` 只能写证据缺口 |
| P2 | OBS 物理屏验证 | L3.1/L3.2 已有记录；L3.3 portal 授权、真实 profile 和 L3.4 10 秒录制仍需在 T490 物理屏完成，不能手写未经验证的 `basic.ini` |
| P3 | patch 索引 | `report/patches/README.md` 明确写出“0008 未产出”，并说明 0011/0013 被 0018/0017 覆盖；抽查 0014–0018 的 `git apply --check`、前后证据和 kernel hash |

每一项都要填写“完成 / 未完成 / 阻塞原因 / 证据路径”。完成交接不等于这些事项全部已完成；它要求状态真实、路径可复核。

