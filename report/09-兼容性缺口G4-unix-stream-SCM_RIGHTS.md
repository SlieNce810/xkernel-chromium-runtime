# 兼容性缺口 G4：AF_UNIX `SOCK_STREAM` 未实现 ancillary（SCM_RIGHTS）——定位、补丁与验收

> 日期：2026-09-21 · 编制：小格（赛题六 · 兼容性缺口与补丁）
> 上游仓库：`https://gitee.com/openkylin/x-kernel.git`
> 相关文档：`report/08-基础任务闭环计划-v2.md` §5.1 · `report/T490验证测试记录-2026-09-21.md` §9.2 未决项 1
> 证据：`evidence/2026-09-21_t490-p1-fdpass/`
>
> **一句话结论**：G4 不是 cmsg 解析缺陷，而是 **unix stream 传输层整体没有 ancillary 通路**；
> 补齐后 **fdprobe 4/4 通过**，weston 从 `desktop-shell 一启动就崩` 变为
> **真实渲染出桌面（面板 + 时钟 + 壁纸），compositor 全程存活**。基础任务「图形会话启动」的关键路径由此打通。

---

## 1. 现象（v16 的阻塞点）

T490 上 weston compositor 已能起来（`Output 'Virtual-1' enabled`），但只要加载桌面 shell 客户端就立刻失败：

```
libwayland: file descriptor expected, object (10), message create_pool(nhi)
Error: /usr/libexec/weston-desktop-shell apparently cannot run at all.
Quitting...
```

weston 存活约 6 秒后退出，截图恒为 `Display output is not active.`。

`wl_shm.create_pool` 的 wire 参数是 `nhi`（new_id + **fd** + int），
Wayland 走 **AF_UNIX `SOCK_STREAM`**，fd 必须由 `SCM_RIGHTS` 经 socket 传过去。
libwayland 在 demarshal 时没拿到 fd → 报 `file descriptor expected`，随后 `Quitting`。

---

## 2. 根因（源码级铁证）

```bash
# 在 x-kernel 仓库根目录
grep -rc ancillary net/knet/src/unix/stream.rs          # → 0
grep -rc ancillary net/knet/src/unix/stream/channel.rs  # → 0
grep -rc ancillary net/knet/src/unix/stream/listener.rs # → 0
grep -rc ancillary net/knet/src/unix/dgram.rs           # → 5   ← 只有 dgram 实现了
```

**`StreamTransport::send()` 与 `StreamTransport::recv()` 从不读写 `options.ancillary`。**

- `send()`（`net/knet/src/unix/stream.rs`）只用 `options.to` 与 `options.flags`，
  `options.ancillary` 被**整个忽略** → `CMsg::Rights { fds }` 直接随 `SendOptions` 一起丢掉。
- `recv()` 只用 `options.flags`，从不往 `options.ancillary`（`Option<&mut Vec<AncillaryData>>`）里写东西
  → `recv_impl()` 里的 `CMsgBuilder` 一个 cmsg 都没构造 → 返回给用户态的 `msg_controllen = 0`。
- libwayland 于是认为"这条消息没有 fd" → `file descriptor expected`。

### 2.1 链路逐段核查（这些部分**都是对的**，不必改）

| 环节 | 位置 | 结论 |
|---|---|---|
| 解析用户传入的 cmsg | `posix/net/src/io.rs::parse_send_cmsgs()` → `posix/net/src/cmsg.rs::CMsg::parse()` | ✅ 按**发送方** `ProcessResources` 的 fd 表 `get_file(fd)` 取出 `Vec<Arc<VfsFile>>` |
| 构造返回给用户态的 cmsg | `posix/net/src/cmsg.rs::CMsgBuilder::push()` | ✅ 写 `cmsg_len/level/type` 与 body，`len` 累加正确 |
| 发送侧发送 | `posix/net/src/io.rs::send_impl()` | ✅ 把 ancillary 放进 `SendOptions` 交给 knet |
| 接收侧接收 | `posix/net/src/io.rs::recv_impl()` | ✅ 从 `socket.recv()` 收 `ancillary`，经 `push_socket_cmsg()` 写回用户缓冲 |
| 接收侧安装 fd | `posix/net/src/io.rs::push_socket_cmsg()` | ✅ `resources.add_file(f, false)?` 装进**接收方** fd 表并回写新 fd 号 |
| **传输层** | **`net/knet/src/unix/stream.rs`** | ❌ **`options.ancillary` 被完全忽略** |

> 也就是说：`posix-net` 侧的两端都对，断点恰好在中间那层"把 cmsg 跟着字节一起送过去"。

### 2.2 附带发现（非阻塞，但同属该文件）

`CMsgBuilder::push()` 用 `*self.len += cmsg_len` 前进，**没有做 `CMSG_ALIGN`**。
单个 cmsg 时无影响；一旦一次 `recvmsg` 要返回**多个** cmsg（且前一条长度非 8 字节对齐），
后续 cmsg 会写到未对齐偏移上，用户态 `CMSG_NXTHDR` 解析会错位。建议一并修（见 §6）。

---

## 3. 补丁

应用器：`scripts/t490/p1_stream_ancillary.py`（精确匹配 + 幂等 + 锚点不存在即报错，不盲改）
改动量：**2 个文件，+103 / -1**

### 3.1 `net/knet/src/unix/stream/channel.rs`（+30 / -1）

给 `Channel` 加一对**跨端共享**的队列，由 `new_duplex_channel()` 交叉赋值
（镜像既有 ring buffer 的配对方式：一端发出的，就是另一端可读的）：

```rust
pub(super) type AncillaryQueue = Arc<Mutex<VecDeque<Vec<AncillaryData>>>>;

pub(super) struct Channel {
    pub(super) tx: HeapProd<u8>,
    pub(super) rx: HeapCons<u8>,
    pub(super) endpoint: Arc<StreamEndpoint>,
    pub(super) peer_endpoint: Arc<StreamEndpoint>,
    pub(super) peer_pid: u32,
    /// Control messages sent by this side that the peer has not consumed yet.
    pub(super) outgoing_ancillary: AncillaryQueue,
    /// Control messages sent by the peer, delivered with our next successful read.
    pub(super) incoming_ancillary: AncillaryQueue,
}
```

### 3.2 `net/knet/src/unix/stream.rs`（+74 / -1）

1. **`send()`**：在 `advance_write_index()` **之前**、同一把 `tx_order` 临界区内入队。

   > ★ 这是本补丁最容易写错的地方。若先 `advance_write_index` 再入队，
   > 并发读者可能在这两步之间读到数据，却弹出空队列 → fd 偶发丢失。
   > 顺序必须是「**先 cmsg，后字节**」。

2. **`recv()`**：仅当本次真的读到字节（`count > 0`）时，从 `incoming_ancillary` 弹出**一条**
   交给 `options.ancillary`；`count == 0`（含 zero-length recv 的早退路径）不弹。

   > Linux 语义：cmsg 随"**首次成功接收、且消费了该消息任意字节**的那次 `recvmsg`"交付。
   > 弹出"一条"而不是"全部"，正是为了匹配这个语义（一次 read 跨两条消息时只交付第一条的 cmsg）。

3. 追加 1 个 `#[def_test]`：`unix_stream_delivers_ancillary_data_with_the_next_read`
   （第一条读到 cmsg、第二条不继承）。

### 3.3 语义边界（已在代码注释中写明）

- cmsg 与其消息的"**首个字节**"绑定交付，不按字节偏移精确切分。
  对 Wayland（一请求一次 `sendmsg`、一次 `recvmsg` 读完整消息）**完全等价**。
- 若 `sendmsg` 最终一个字节都没发出，ancillary 随 `Vec` 一起释放——不发、也不泄漏引用。
- 锁序：`channel → ancillary_queue`（叶子锁），与既有 `channel → endpoint.tx_order` 一致，无死锁。

### 3.4 构建

```bash
export PATH="$HOME/.cargo/bin:$PATH"     # ★ 必须先加，否则 rustc 落到 apt 的 1.93.1
cd ~/x-kernel && make build              # BUILD_EXIT=0
# Built /home/mo/x-kernel/target/xkmake/kplat-aarch64/release
```

> 首轮踩坑：`channel.rs` 原本只 `use alloc::sync::Arc`，而 `AncillaryQueue` 用到 `Vec` →
> `error[E0425]: cannot find type Vec in this scope`。应用器已补 `alloc::vec::Vec` 的 fixup 锚点。

---

## 4. 验收

### 4.1 独立 C 探针 `scripts/t490/fdprobe.c`

不依赖 weston，直接判定"fd 能不能跨进程落地"，并区分 STREAM / DGRAM：

| 用例 | 内容 | 期望 |
|---|---|---|
| **T1** | STREAM，`socketpair` + `fork`，父发 1 个 fd，子 `recvmsg` 取回并**实际读写**该 fd | fd_count=1 且可读写 |
| **T2** | STREAM，纯数据不带 fd | fd_count=0（证明数据通路本身没问题） |
| **T3** | STREAM，A(带 fd) 紧跟 B(不带 fd)，分两次 `recvmsg` | fd 序列 = `1, 0`（验证队列语义） |
| **T4** | DGRAM，带 1 个 fd（**正对照**） | fd_count=1 |

探针还在子进程落盘一个计数文件，由父进程汇总打印 `[RESULT] T1_fd_count=` ——这是核心判据。

### 4.2 结果（本轮实测）

```
[ENV] pid=28 CMSG_LEN(0)=16 CMSG_SPACE(0)=16 CMSG_SPACE(int)=24
[T1] T1_fd_count=1 (0 = 跨进程 fd 完全没送到, 1 = 送到)
[T1] VERDICT_PASS=PASS  (STREAM 跨进程传 1 个 fd 且收到的 fd 可读写)
[T2] VERDICT_PASS=PASS  (STREAM 纯数据通路正常且不带多余 cmsg（fd=0）)
[T3] VERDICT_PASS=PASS  (A(+fd) 与 B(无fd) 分两次 recv，fd 序列应为 1,0)
[T4] VERDICT_PASS=PASS  (DGRAM 传 1 个 fd（正对照）)
[RESULT] pass=4 fail=0
[RESULT] T1_fd_count=1
[SUMMARY] stream 已能把 fd 跨进程送达
```

修复前的对照：`msg_controllen` 恒为 `0`、`fd_count=0`。

> ★ 探针自身也修了一处判定缺陷：验证"收到的 fd 可写"时，目标文件比写入串长，
> 覆盖写后尾部残留仍在，**必须按前缀比较而非整串相等**，否则会把 PASS 误报成 FAIL。

### 4.3 weston 端到端（同一会话）

```
[libseat-shim] open_seat ... enable_seat ... open(/dev/dri/card0) -> fd=13 OK
[05:54:58.853] Using Pixman renderer
[05:54:59.688] DRM: head 'Virtual-1' found, connector 48 is connected, EDID make 'unknown', model 'unknown', serial ''
[05:54:59.832] Output 'Virtual-1' enabled with head(s) Virtual-1
[05:54:59.857] Loading module '/usr/lib/weston/desktop-shell.so'
[05:54:59.935] launching '/usr/libexec/weston-keyboard'
[05:55:00.031] launching '/usr/libexec/weston-desktop-shell'
```

进程快照（会话中段）：

```
 51 root  seatd -g root -l debug
 59 root  weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 --seat=seat0 ...
 65 root  /usr/libexec/weston-keyboard
 66 root  /usr/libexec/weston-desktop-shell
```

**`create_pool` / `file descriptor expected` / `Quitting` / `apparently cannot run at all`
在整份日志中已全部消失。**

### 4.4 画面证据（monitor `screendump`）

| 截图 | 画面 |
|---|---|
| `screenshots/shot-01-at0045s.ppm` | Weston 桌面：顶部面板 + 左上 Weston 图标 + 壁纸，**面板时钟 `Mon Sep 21, 05:55 AM`** |
| `screenshots/shot-06-final.ppm` | 同上，**时钟 `Mon Sep 21, 05:59 AM`** |

时钟从 05:55 走到 05:59，证明 **compositor 全程在实际重绘**，而非"启动后静止挂住"。
对比修复前恒为 `Display output is not active.`。

### 4.5 会话与合规

```
# 实际执行的 make 命令
make run GRAPHIC=y ACCEL=n MEM=4g SMP=4 VSOCK=n 'QEMU_ARGS=-device virtio-keyboard-pci -device virtio-mouse-pci'
```

- QEMU 10.2.1，guest AArch64，**ACCEL=n（xkmake 的 `--no-accel`）→ QEMU argv 中无任何 `-accel`**
- 会话 300 s（本轮为因果判定轮，非正式证据轮）；7 张 `screendump` PPM，全 640×480
- 证据目录：`evidence/2026-09-21_t490-p1-fdpass/`（`console.log` / `cmd.txt` / `env.txt` / `manifest.txt` / `timestamps.csv` / `screenshots/`）

---

## 5. 本轮暴露的次生问题（下一步清单）

| # | 现象 | 影响 | 建议 |
|---|---|---|---|
| S1 | `[ -S /run/user/0/wayland-0 ]` 判为假，但 `weston-desktop-shell` 明明连上了 | 启动等待逻辑误判（本轮日志里误报"weston 未起来"） | guest 内用 `ls -l /run/user/0/` 核实 socket 的 mode 位；怀疑 x-kernel 建 socket 文件时**没有置 `S_IFSOCK`**。这本身可能是一个独立缺口（文件类型位），顺手取证 |
| S2 | `Fontconfig error: "/etc/fonts/fonts.conf", line 1: no element found` / `Cannot load config file` | 字体配置缺失，直接影响 Chromium 文字渲染（浏览器 20 分） | 补一份合法的 `/etc/fonts/fonts.conf` + 字体包（宿主跨架构 apk 预装） |
| S3 | `could not load cursor 'dnd-move'/'dnd-copy'/'dnd-none'` | 拖放光标缺失，视觉瑕疵 | 补 cursor 主题（非阻塞） |
| S4 | `warning: no input devices found, but none required as per configuration.` | **决赛「键鼠回显」4 分** | 已用 `QEMU_ARGS` 显式加 `virtio-keyboard-pci`/`virtio-mouse-pci`，但 weston 仍没发现输入设备 → 需核对 guest 内 `/dev/input/event*` 与 `/run/udev/data/c13:*` 的**次设备号映射**（见 v2 §4.4） |
| S5 | `/root/weston-watch.log` 内容为空 | 稳定性证据缺失 | watcher 每轮 `sync`；或在会话结束前从串口把 watcher 内容打出来（QEMU 被强杀会丢未 sync 的 ext4 数据） |

---

## 6. 上游建议

1. **本补丁（stream ancillary）作为独立 PR**：题目清晰、diff 小、有单测、有端到端证据
   （weston desktop-shell 由"必崩"变"正常"），是很有说服力的上游贡献。
   建议标题：`fix(knet): deliver ancillary data on AF_UNIX stream sockets`。
2. **附带修 `CMsgBuilder` 的 `CMSG_ALIGN`**（§2.2），可作为同一 PR 的第二个 commit，
   或在 PR 描述中说明"已发现但未一并修"。
3. **`drmGetDevices2` 返回 0**（G5）与 **`S_IFSOCK` 位**（S1）可作为后续 issue。
4. PR 前须装 pinned `nightly-2026-03-08` 过 `fmt`/`clippy` 全检
   （本地以 `SKIP_FMT=1 SKIP_CLIPPY=1` 绕过，**必须在 PR 说明中声明**）。

---

## 7. 复现步骤

```bash
# ── 在 T490（Ubuntu 26.04，用户级，零 sudo）────────────────────────────
export PATH="$HOME/.cargo/bin:$HOME/qemu-root/usr/bin:$HOME/musl/aarch64-linux-musl-cross/bin:$PATH"
cd ~/x-kernel

# 1) 打补丁
python3 ~/xk6/scripts/t490/p1_stream_ancillary.py ~/x-kernel

# 2) 构建
make build                       # 期望 BUILT，退出码 0

# 3) 一键验收（编 fdprobe → 从 P0 冻结镜像起 disk.img → 注入 → 跑会话）
bash ~/xk6/scripts/t490/t490_p1_verify.sh 300 60

# 4) 看结果
D=$(ls -d ~/xk6/evidence/*_t490-p1-fdpass | tail -1)
tr -d '\r' < $D/console.log | grep -nE "T1_fd_count|VERDICT|RESULT|SUMMARY"
tr -d '\r' < $D/console.log | grep -nE "Output 'Virtual-1'|desktop-shell|create_pool|Quitting"
```

**判据**：`[RESULT] T1_fd_count=1` + `ALL_PASS`；
日志中出现 `launching '/usr/libexec/weston-desktop-shell'` 且**不再出现** `create_pool` / `Quitting`；
`screendump` 画面为 Weston 桌面且面板时钟随时间前进。
