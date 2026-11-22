# 257 · SOCK_STREAM ancillary 首次读取语义 A/B（2026-11-14）

## 目的

检查现有 stream ancillary 边界修复是否符合 Linux 的 `recvmsg` 语义。此前实现把
`SCM_RIGHTS` 延迟到整条 `sendmsg` 字节边界消费完才交付；这与 Linux 的部分读取行为
不一致，可能影响 Chromium Mojo 的大消息句柄绑定。

## Linux 对照

在 T490 宿主 Linux 上用 `AF_UNIX/SOCK_STREAM` socketpair 发送 100 字节并携带一个
`SCM_RIGHTS` fd，接收端每次只提供 1 字节缓冲区：

```text
send=100
recv0=1 got=1 flags=0
recv1=1 got=0 flags=0
recv2=1 got=0 flags=0
```

因此 ancillary 必须在第一次成功消费对应 stream 写入的 `recvmsg` 中交付；后续部分
读取不能再次交付同一批 fd。原 x-kernel 实现只有在 `bytes_remaining == 0` 时才弹出并
交付，延迟了这一回执。

## 临时修复

诊断 patch：[257-xkernel-stream-ancillary-first-read.patch](257-xkernel-stream-ancillary-first-read.patch)

改动保持已有字节边界限制，但在首次成功读取时将 `AncillaryBatch.data` 移出并交给
`recvmsg`，剩余字节继续保留在同一个边界中。`MSG_PEEK` 路径不推进边界，也不提前
消费控制数据。

编译结果：

```text
kernel.bin (diagnostic): b6aae717021b92e3cb5bb345b6c7ddb9064df78635e85f2ac47bc8e0ee1c2294
```

## Chromium 149 A/B

证据：[evidence/2026-11-14_t490-stream-first-read-fix](../evidence/2026-11-14_t490-stream-first-read-fix/)

运行形态保持决赛默认路径：

```text
pkg-installed.img / Chromium 149.0.7827.53
browser → zygote → renderer
Wayland + SwiftShader + in-process GPU
纯 TCG，未使用 single-process、no-zygote 或页面注入
```

本轮确认 stream 控制消息和 renderer 句柄传递仍然正常，`FileURLLoader::Start` 和
HTML 请求继续出现；但仍没有：

```text
DocumentLoader
DidCommitNavigation
有效 1280×800 页面像素
```

`score-page-gate.json` 结果为 4 张截图全部失败，HTML 项仍为 0/4。也就是说，首次
读取 ancillary 语义是一个真实的 Linux ABI 修复，但不是当前 renderer 首帧的唯一根因。

## 收尾

为保持正式基线可重算，T490 已恢复：

```text
formal kernel SHA-256 = 20ce1d46320fa21745ab17acda4d835de6c7671bc23a89081100ed8f1dbb041b
```

该 patch 作为后续 Chromium 多进程兼容性候选保留，当前不把它写成页面 PASS。
