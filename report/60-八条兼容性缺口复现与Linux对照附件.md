# 八条兼容性缺口复现与 Linux 对照附件

本附件将八条缺口展开为现象、最小复现、Linux 对照、影响、补丁或限制。当前 Guest 源码为 `2a1b101ccf97ed255821b85628f366700089cda3`、AArch64。Linux 对照同时执行 native x86_64/glibc 与 AArch64 静态 musl 经 qemu-user 两组；后者仍调用 Linux 宿主内核，不是独立 AArch64 Linux VM。

## 最短复现命令

```bash
export PATH="$HOME/musl/aarch64-linux-musl-cross/bin:/usr/sbin:/sbin:$PATH"
python3 scripts/t490/run_linux_gap_baselines.py \
  --out "evidence/$(date +%F)_t490-linux-gap-baselines-$(date +%H%M%S)"

BASE_IMG="$HOME/x-kernel/images/agentos-weston.img" \
FIRST_SHOT=120 STRICT_GATE=0 \
bash scripts/t490/t490_round.sh \
  "submission-gaps-$(date +%H%M%S)" 360 120 autorun_submission_gaps.sh \
  submission_gap_probe.c compatprobe.c sandboxipcprobe.c fdprobe.c seqpacketprobe.c evprobe.c
# 停机后、下一轮写盘前回收 /root/submission-gaps.log 与各 probe 输出。
```

宿主驱动记录编译命令、源码与二进制哈希、运行命令、退出码及原始输出。Guest runner 每个探针等待不超过 45 s；未注入与超时单列，不启动 Chromium，也不把截图当成 syscall PASS。

## 八条缺口逐项映射

| 缺口与现象 | 最小复现及 Linux 对照 | 影响 | 补丁与未覆盖范围 |
|---|---|---|---|
| G1 fd 下界/zygote 继承：历史控制 fd 与 fd 3 预期不一致 | submission_gap_probe 的 F_DUPFD,100 和 fd3 fork/exec 读字节；本次两组 Linux 都返回 fd=100、子进程退出 0 | 子进程控制通道可能指错对象 | 当前 fork commit 为复测落点；现有导出集无独立 fd 下界补丁，不能虚构编号；不覆盖完整 Chromium sandbox/zygote 协议 |
| G2 Unix ancillary、凭据、半关闭：共享 fd 丢失与 crashpad 缺凭据 | fdprobe T1–T4；sandboxipcprobe 的 SEQPACKET/DGRAM、SCM_RIGHTS、CLOEXEC 与 shutdown/reply；seqpacketprobe pathname；compatprobe 收端启用 SO_PASSCRED 后收凭据。两组 Linux 的三项 socket 专项退出 0 | Wayland wl_shm 与 Chromium IPC 依赖这些契约 | 0002、0007、最终 0017/aff4f00；0013 被 0017 覆盖；局部测试不替代 renderer 运行 |
| G3 ppoll/time64：历史等待失败或 ENOSYS | 有数据管道调用 libc ppoll 检查 1/POLLIN；两组 Linux 通过。AArch64 另观察 raw 414，Linux 返回 ENOSYS、原生 SYS_ppoll=73 | 事件 watcher 与控制 socket 依赖 readiness | 0018/2a1b101；414 不可当 Linux AArch64 原生 ppoll ABI；不覆盖信号掩码、超时精度及全部 ABI |
| G4 procfs：uptime 曾固定 0，线程/内存字段不全 | 读取 status 的 State/Threads/VmRSS、statm、meminfo，间隔 200 ms 读 uptime；Linux 有字段且 uptime 递增 | 影响用户态探测与资源观测 | 0016/670f80d；0012 是其他基线的独立记账实验；字段存在不等于完整记账语义。Guest VmRSS 不能作为有效浏览器 RSS |
| G5 PDEATHSIG：历史返回 EINVAL | 设置 SIGTERM 后 GET 读回，再清零；两组 Linux 都通过 | 子进程跟随回收语义 | 0018 的最小 ABI；set/get 成功不证明父死亡投递、subreaper、fork/exec 或凭据转换，完整语义未覆盖 |
| G6 TCP keepalive：历史 ENOPROTOOPT | TCP socket 分别设置 KEEP IDLE/INTVL/CNT 为 60/10/3，读取同值；两组 Linux 均通过 | 消除用户态配置失败 | 最终 0017/aff4f00；不证明实际 keepalive 包与超时调度 |
| G7 PI futex/NOFILE：ENOSYS 使 musl/PulseAudio 回退失败，D-Bus 请求 65536 超容量 | PI lock 成功后解锁，读取 NOFILE 再保持 hard 不变请求 soft=65536；两组 Linux PI 成功，soft 1024/hard 524288，提升成功 | libc 回退与 fd 容量声明必须一致 | 0018 覆盖 0011；Guest PI 未实现时的 EOPNOTSUPP 是回退约定，不是 Linux PI 功能完成；固定 1024 表不宣称支持 65536 |
| G8 virtio-input：QMP 注入后没有对应 evdev 消费 | evprobe 仅枚举节点、名字、能力。完整复现需 QMP 注入→evdev read/poll→页面回显并保存时间戳；本次 Linux 普通用户枚举不构成同设备硬件输入对照 | 真实键鼠输入仍为缺口，CDP/页面事件不能代替 | 0015/707ada7 涉及 sysfs/事件入口，不能凭标题宣称消费链闭合；硬件全链当前未覆盖 |

## 原始证据索引与判定

Linux 最终对照在 evidence/2026-10-13_t490-linux-gap-baselines-v3-prctl/；Guest 最终对照在 evidence/2026-10-13_t490-submission-gaps-prctl-recheck/。更早的 v2/v3 与初版输出保留为诊断过程，最终 prctl 探针显式传入足宽参数并将未用参数清零，避免把不完整的可变参数调用误当内核失败。

| 当前 Guest 实测 | 结果 |
|---|---|
| G1 F_DUPFD 下界、fd3 fork/exec | 均 PASS |
| G2 socket 专项及启用 SO_PASSCRED 的凭据接收 | PASS |
| G3 原生 ppoll 与 raw 414 扩展 | 原生 PASS；扩展返回 1/POLLIN，与 Linux 原生 ABI 的 ENOSYS 分开记录 |
| G4 uptime | 从 1.867 增到 2.070；procfs 其他字段是观察项 |
| G5 set/get | set=0；get=0 且读回信号 0，未保持 SIGTERM，完整信号状态 FAIL |
| G6 TCP 三项 set/get | 均 PASS |
| G7 PI/NOFILE | PI errno=95；soft/hard=1024/1024；请求 soft=65536 errno=22，容量限制保留 |
| G8 evdev | 仅枚举；事件消费全链未覆盖 |

compatprobe 的 madvise 空洞检查仍失败：Guest 返回 0，native Linux 返回 ENOMEM。该差异保留，不将“探针已跑”写成全部 Linux 语义已对齐。

G1 的历史线索见 [report/38](38-2026-09-29-干净多进程复核与zygote-fd诊断补充.md)；G7 D-Bus 现场见 [report/39](39-2026-09-30-初赛进度与后续计划.md)；G8 边界见 [report/44](44-键鼠与JavaScript-CSS交互验收报告.md)。补丁来源与覆盖关系见 [补丁索引](patches/README.md)。

## 本次修正的探针边界

旧 compatprobe 在 native Linux 上有两处错误预期：含未映射空洞的 madvise 错误期待返回 0；收凭据前没有设置 SO_PASSCRED。已按文档与实测修正，native compatprobe 退出 0。AArch64 qemu-user 仍对空洞返回 0，保留这项与 native Linux 的差异，不把期待改回。

Linux 对未映射区间处理其余映射但返回 ENOMEM，参见 [madvise(2)](https://man7.org/linux/man-pages/man2/madvise.2.html)；接收 SCM_CREDENTIALS 需 SO_PASSCRED，参见 [unix(7)](https://man7.org/linux/man-pages/man7/unix.7.html)。原生等待、父死亡信号与 TCP 选项契约分别参见 [ppoll(2)](https://man7.org/linux/man-pages/man2/ppoll.2.html)、[PR_SET_PDEATHSIG](https://man7.org/linux/man-pages/man2/PR_SET_PDEATHSIG.2const.html)、[tcp(7)](https://man7.org/linux/man-pages/man7/tcp.7.html)。

没有任何一个探针覆盖全部八条，更没有替代多进程 Chromium 与硬件输入验收。

## 宿主探针副作用说明

在 T490 原生 Linux 宿主执行 fdprobe 时，探针曾对固定路径 /tmp/fdprobe-target 与 /tmp/fdprobe-t1.count 使用 O_TRUNC，覆盖了这些路径上的内容。运行前没有保存存在状态或文件内容，无法证明原值或恢复未知的先前状态。2026-10-14 的只读复核记录到 target 为 25 字节，内容为 CHILD-WROTE-9876543210789，SHA-256 为 ab1e899df1575cf9a233b89d2f45a285a6f14dbf3fd106401287b8623bf4e57a；count 文件内容为 1，SHA-256 为 4355a46b19d348dc2f57c046f8ef63d4538ebb936000f3c9ee954a27460dd865，二者 mtime 均为 2026-10-13 14:21（北京时间）。后续 fdprobe.c 已改为接受 FDPROBE_TARGET_PATH 和 FDPROBE_COUNT_PATH，Linux 对照驱动把它们指向本轮独立证据目录。该修正仅适用于后续复测，不改变或掩盖宿主原路径的既有状态。
