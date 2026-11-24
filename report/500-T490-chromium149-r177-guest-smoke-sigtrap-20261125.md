# T490 Chromium 149 R177 Guest Smoke 退出码 133（2026-11-25）

## 实跑条件

本轮把 R177 隔离链接包注入 T490 的 2 GiB、AArch64、纯 TCG、Weston 原生 Wayland 会话：

```text
BASE_IMG=/home/mo/x-kernel/images/agentos-weston.img
PKG_TARBALL=/home/mo/xk6/tmp/r177-package/chromium149-r177-isolated.tar.gz
SINGLE_HOLD_VALUE=60
autorun=autorun_single_initial.sh
QEMU=-m 2g -smp 4 -cpu cortex-a76 -machine virt,gic-version=3
```

平台合规断言通过 15/15，输入设备、Weston 和第一张 1280x800 PPM 均生成。原始证据保存在
[evidence/2026-11-25_t490-r177-smoke](../evidence/2026-11-25_t490-r177-smoke)。

## 结果

Guest 中 Browser PID 为 55。Chromium 进入了运行阶段并触发了多轮 futex、epoll、mmap、
Wayland/输入相关调用，但在约 75 秒时退出：

```text
SANDBOX_EXIT pid=55 parent=5 exit_code=133 signal=Some(SIGCHLD)
[single] BROWSER_EXITED before hold elapsed=75
[single] SINGLE_GATE=0
```

`133 = 128 + SIGTRAP`，因此本轮不能算页面通过、单轮稳定性通过或源码二进制运行通过。
现有 console 没有在退出点前给出可归因的 Chromium `FATAL` 文本；随后只出现了 ANGLE Vulkan、
VAAPI、DBus 和 single-process V8 proxy resolver 的普通错误日志。由于 R177 使用了符号级
诊断 stub，当前最直接的定位方向是先在同一对象集上移除或逐个替换 V8 Wasm/基础 ABI stub，
再复跑最小 Browser 启动。

## 证据摘要

```text
console.log sha256=283c3e83c73cee926373138b574d4c30e718a06e85d088ba50712715fe5a196e
shot-01-at0060s.ppm sha256=d4e96a65fd4f8e97bc1d762fc90cf2593bc2efb53a3125a72502fdae0f09395c
platform-compliance=PASS=15/15
SINGLE_GATE=0
browser_exit_code=133
```

本轮只证明 R177 ELF 能被 guest 加载到 Browser 启动阶段；它没有进入三次冷启动、稳定性或
四项性能统计，正式性能状态继续为 `0/4`、before/after `0/0`。
