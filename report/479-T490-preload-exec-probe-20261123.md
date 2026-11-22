# T490 preload-exec 诊断轮归档（2026-11-23）

## 结论

本轮使用 T490 `10.249.11.192` 的 AArch64、2 GiB、纯 TCG、Weston/原生
Wayland 和默认 Browser→Zygote→Renderer 启动参数，运行了约 300 秒的
`preload-exec-probe` 诊断。QEMU 会话正常收尾（`SESSION END (exit=0)`），
10/10 定时 PPM 截图和 strict 判据文件均生成，页面注入与读回校验通过。

这不是正式稳定性或性能样本：本轮的串口/观测日志没有出现 Browser 进程、
`renderer_ready`、`renderer_exec` 或 `preload_attached` 事件，观测器连续报告
`MP_RENDERER_COUNT=0`。因此不能把这轮的 300 秒保持、截图序列或缺失的
renderer 事件写入三次冷启动、30 分钟稳定性或四项性能统计。

## 固定条件

| 项目 | 实际值 |
| --- | --- |
| T490 | `mo@10.249.11.192` |
| guest | AArch64，2 GiB，4 vCPU，QEMU 10.2.1，纯 TCG |
| 图形 | Weston 原生 Wayland，virtio-gpu，virtio keyboard/mouse |
| 页面 | `file:///usr/share/html-test/index.html` |
| Chromium 参数 | `--ozone-platform=wayland --no-sandbox --disable-gpu --disable-dev-shm-usage` |
| 观测开关 | lifecycle preload，MP trace/ledger/memory sampler 均按本轮命令固定 |
| 会话 | 请求 300 s，截图间隔 30 s，实际 303.7 s |
| 内核 SHA-256 | `51c4028594e4aff9fc5b9964c4294a2904621c93e84093ac711858c454aed284` |
| 基础镜像 SHA-256 | `bb25e0b298d619a62df06b0ab044750c0885adc2d34602eb0c5875a022aaee09` |

完整命令和实际 QEMU 参数见 T490 证据目录中的 `cmd.txt`。该目录记录的源码
树为历史冻结根 `b73e5814087c9d33c5f0a35b66cc56be689d3dee`，含已有工作树改动；
本轮没有将其误写成干净提交。

## 结果

- `pages.txt`：测试页注入、逐字节读回、入口存在检查均为 `OK`。
- `timestamps.csv`：`shot-01` 至 `shot-10-final` 共 10 个截图，时间点约为
  45.0、75.3、105.5、135.7、165.9、196.1、226.3、256.6、286.8、303.4 s，
  每行 `result=True`。
- `ppm-summary.txt`：10 个截图的判据结果已保存在 T490；原始 PPM 按仓库约定
  不复制进 Git，仅保留远端文件和哈希索引。
- `console.log`：会话末尾为 `QEMU: Terminated` 和 `SESSION END (exit=0)`；
  期间可见 zygote 与 Chromium futex/Unix IPC 诊断，但未见 renderer ready 链。
- `MP_RENDERER_COUNT=0` 在多个监视点出现，且没有可用于 renderer 创建延迟的
  request/ready 配对。

## 验收边界

本轮计入：

1. lifecycle preload 的 T490 运行期诊断入口确实能完成固定时长会话并产生可复核
   的截图、页面清单和命令指纹；
2. 10 个截图判据文件和会话收尾状态可作为后续排查的原始材料；
3. 没有 QEMU 残留进程，随后已恢复 Chromium R114 后台构建。

本轮不计入：

1. 三次独立冷启动；
2. 30 分钟/十次真实导航稳定性门禁；
3. Browser 启动、首帧、renderer 创建或峰值 RSS/PSS/USS 性能样本；
4. preload exec 继承在 Chromium 149 guest 中已实际触发的证明。

## 原始证据

原始目录保存在 T490：

```text
/home/mo/xk6/evidence/2026-11-23_t490-preload-exec-probe/
```

主要文件哈希（远端采集完成后计算）：

```text
7ca417d3386d9e4588d254c195c00571d63dcf1ec388466b7777f290ce15155  console.log
fec548d54f699eb0a6bb35df36991e6ca6e440c987a9d10fd758114b5e6efa02  cmd.txt
2a1ea584d91f465bb0a6825f09bdb3eca936b36b7451e54df677ec2216901dfb  env.txt
748549549e275cde19f5651cfffb67c74444260dca0db3891b90967535528f0b  manifest.txt
06fe3e0efbdaf9f6653889d2c6687273f35abca5ffbd2294d224eb1910c8833c  timestamps.csv
6a715425d60f29140bf088075c9ade368d353b74b9dd151cbc8f08ba4a56d7c4  pages.txt
87573548cc31541ba466c551a7760a3891271c6d213ec89d56141e7b37156dd6  ppm-summary.txt
```

下一步是等待 R114 exact Chromium 149 构建完成，先做二进制/对象校验，再用同一
preload 在真实 Chromium 运行期检查 `renderer_ready` 配对；在该事件实际出现并且
内存采集完整前，正式性能状态保持 `0/4`、`0/0`。
