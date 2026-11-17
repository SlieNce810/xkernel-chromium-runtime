# T490 Chromium 149 cmsg 对齐修复 A/B（2026-11-12）

## 修复内容

x-kernel 的 POSIX ancillary 路径此前按 `cmsg_len` 连续推进，没有按 Linux `CMSG_SPACE` 对齐。现在补齐了：

- 发送侧多 cmsg 解析按 CMSG_ALIGN 读取下一个 header；
- 接收侧 `CMsgBuilder` 在多个 cmsg 之间写入 padding；
- 最终 cmsg 仍允许 `msg_controllen` 只覆盖实际 cmsg 长度；
- 组合 `SCM_RIGHTS + SCM_CREDENTIALS` 不再把第二个 cmsg 放到错误偏移。

补丁正文：[report/212-xkernel-cmsg-align.patch](212-xkernel-cmsg-align.patch)。

## 内核验证

本轮 kernel SHA-256：

```text
d182fc8ca0d9846b07ec6e59a67f84ecad23082088079e6a2d70e4d77a1c6642
```

组合 cmsg 探针证据：

```text
/home/mo/xk6/evidence/2026-11-12_t490-cmsg-combo-align-20261112-r1/
[CMSG_COMBO] byte=x rights=1 creds=2 fd=6 flags=0 controllen=88
[CMSG_COMBO_EXIT] 0 aligned_multi_cmsg_ok
```

这条探针同时打开 `SO_PASSCRED`、发送 `SCM_RIGHTS` 和 `SCM_CREDENTIALS`，并用 Linux `CMSG_NXTHDR` 遍历接收结果；因此它直接覆盖此前没有覆盖的多 cmsg 对齐场景。

## Chromium A/B

在相同 Chromium 149、Wayland、SwiftShader、纯 TCG 条件下使用该 kernel 重跑默认多进程：

```text
/home/mo/xk6/evidence/2026-11-12_t490-mp-cmsg-align-fix-20261112-r1/
```

结果：

```text
renderer 观察：出现
FileURLLoader::Start：出现
DocumentLoader / DidCommitNavigation：未出现
MP_RENDERER_RECEIPT_COUNT=0
MP_GATE=0
```

## 结论

这是一个真实的 Linux cmsg ABI 修复，并且组合 ancillary 探针已通过；但 Chromium 149 页面首帧 A/B 没有改善。因此该修复应保留为 IPC 基础正确性修复，却不能单独宣称已经恢复 renderer 文档提交。下一步仍需定位 browser/zygote 在 primordial Mojo host 连接失败后回收 renderer 的具体 attachment 或 disconnect 原因。
