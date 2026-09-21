#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P1 补丁：为 AF_UNIX **SOCK_STREAM** 补齐 ancillary（SCM_RIGHTS）收发。

背景
----
T490 v16 实测：weston compositor 起来后 desktop-shell 客户端立即失败——
    libwayland: file descriptor expected, object (10), message create_pool(nhi)
Wayland 的 `wl_shm.create_pool` 必须把 memfd 经 AF_UNIX **SOCK_STREAM** 传过去。
源码核查：`ancillary` 在 `net/knet/src/unix/stream.rs`、`stream/channel.rs`、
`stream/listener.rs` 中出现 **0 次**，而 `unix/dgram.rs` 有 5 次
→ stream 传输层整体丢弃了 ancillary，fd 静默丢失。

修法（最小改动，不动 `StreamEndpoint` / listener / dgram）
--------------------------------------------------------
1. `stream/channel.rs`：`Channel` 增加一对**跨端共享**的队列
   `outgoing_ancillary`（本端发出）与 `incoming_ancillary`（对端发来），
   由 `new_duplex_channel` 交叉赋值（镜像 ring buffer 的配对方式）。
2. `stream.rs::send()`：**在 bytes 发布之前**（`advance_write_index` 之前、
   同一把 `tx_order` 临界区内）把 ancillary 入队，保证并发读者不会
   "看到数据却拿不到 cmsg"。
3. `stream.rs::recv()`：在本次实际读到字节（`count > 0`）时，从
   `incoming_ancillary` 弹出**一条**交给 `options.ancillary`，
   与 Linux「cmsg 随该消息的首次成功 receive 交付」一致。
4. 追加一个 `#[def_test]` 单测覆盖"第一条读到 cmsg、第二条不继承"。

语义与已知简化
--------------
- 一条 `sendmsg` 的 ancillary 与"其首个字节"绑定交付，而非按字节偏移精确切分。
  对 Wayland（一请求一 sendmsg、一次 recvmsg 读完整消息）完全等价。
- 若 `sendmsg` 最终一个字节都没发出，ancillary 随 `Vec` 一同释放（不发、不泄漏），
  与 Linux 失败即不传递的语义一致。

用法
----
    python3 p1_stream_ancillary.py <x-kernel 根目录>

行为
----
逐个锚点精确匹配替换；锚点不在（已打过）则跳过；匹配数 != 1 则报错退出（不盲改）。
"""

import os
import sys

CHANNEL_RS = "net/knet/src/unix/stream/channel.rs"
STREAM_RS = "net/knet/src/unix/stream.rs"

# ---------------------------------------------------------------- channel.rs

CH_IMPORTS_TARGET = """use alloc::{
    collections::VecDeque,
    sync::Arc,
    vec::Vec,
};
use core::sync::atomic::{AtomicBool, AtomicI32, Ordering};

use kerrno::LinuxError;
use kpoll::{IoEvents, PollContext, PollRegisterError, PollSet};
use kspin::SpinNoPreempt;
use ksync::Mutex;

use crate::AncillaryData;
"""

# 未打过补丁的原始形态
CH_IMPORTS_FRESH_OLD = """use alloc::sync::Arc;
use core::sync::atomic::{AtomicBool, AtomicI32, Ordering};

use kerrno::LinuxError;
use kpoll::{IoEvents, PollContext, PollRegisterError, PollSet};
use kspin::SpinNoPreempt;
"""

# 首版补丁的中间形态（漏了 `alloc::vec::Vec`，编译报 E0425）→ 单独补救，幂等
CH_IMPORTS_V1_OLD = """use alloc::{collections::VecDeque, sync::Arc};
"""

CH_DUPLEX_OLD = """pub(super) fn new_duplex_channel(
    client_endpoint: Arc<StreamEndpoint>,
    server_endpoint: Arc<StreamEndpoint>,
    pid: u32,
) -> (Channel, Channel) {
    let (client_tx, server_rx) = new_ring_pair();
    let (server_tx, client_rx) = new_ring_pair();
    (
        Channel {
            tx: client_tx,
            rx: client_rx,
            endpoint: client_endpoint.clone(),
            peer_endpoint: server_endpoint.clone(),
            peer_pid: pid,
        },
        Channel {
            tx: server_tx,
            rx: server_rx,
            endpoint: server_endpoint,
            peer_endpoint: client_endpoint,
            peer_pid: pid,
        },
    )
}

pub(super) struct Channel {
    pub(super) tx: HeapProd<u8>,
    pub(super) rx: HeapCons<u8>,
    pub(super) endpoint: Arc<StreamEndpoint>,
    pub(super) peer_endpoint: Arc<StreamEndpoint>,
    pub(super) peer_pid: u32,
}
"""

CH_DUPLEX_NEW = """/// Control-message batches travelling in one direction.
///
/// One entry is one `sendmsg` that carried ancillary data (e.g. `SCM_RIGHTS`
/// file descriptors). It is handed to the peer's next successful `recvmsg`,
/// mirroring how Linux attaches control messages to the message whose bytes
/// that `recvmsg` consumes.
pub(super) type AncillaryQueue = Arc<Mutex<VecDeque<Vec<AncillaryData>>>>;

fn new_ancillary_queue() -> AncillaryQueue {
    Arc::new(Mutex::new(VecDeque::new()))
}

pub(super) fn new_duplex_channel(
    client_endpoint: Arc<StreamEndpoint>,
    server_endpoint: Arc<StreamEndpoint>,
    pid: u32,
) -> (Channel, Channel) {
    let (client_tx, server_rx) = new_ring_pair();
    let (server_tx, client_rx) = new_ring_pair();
    // Pair the queues the same way as the rings: what one side sends is read
    // by the other, so `client_to_server` is the client's outgoing queue and
    // the server's incoming queue at the same time.
    let client_to_server = new_ancillary_queue();
    let server_to_client = new_ancillary_queue();
    (
        Channel {
            tx: client_tx,
            rx: client_rx,
            endpoint: client_endpoint.clone(),
            peer_endpoint: server_endpoint.clone(),
            peer_pid: pid,
            outgoing_ancillary: client_to_server.clone(),
            incoming_ancillary: server_to_client.clone(),
        },
        Channel {
            tx: server_tx,
            rx: server_rx,
            endpoint: server_endpoint,
            peer_endpoint: client_endpoint,
            peer_pid: pid,
            outgoing_ancillary: server_to_client,
            incoming_ancillary: client_to_server,
        },
    )
}

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
"""

# ---------------------------------------------------------------- stream.rs

ST_SEND_SETUP_OLD = """        let size = src.remaining();
        let mut total = 0;
        let non_blocking = self.options.nonblocking() || options.flags.nonblocking();
        self.options
            .send_poller_with_nonblocking(self, non_blocking, || {
"""

ST_SEND_SETUP_NEW = """        let size = src.remaining();
        let mut total = 0;
        let non_blocking = self.options.nonblocking() || options.flags.nonblocking();
        // Control messages are held back until the first byte of this message is
        // published: a send that ends up writing nothing must not queue anything.
        let mut ancillary = options.ancillary;
        let mut ancillary_published = ancillary.is_empty();
        self.options
            .send_poller_with_nonblocking(self, non_blocking, || {
"""

ST_SEND_PUBLISH_OLD = """                    // SAFETY: `count` is the sum of bytes written into the vacant
                    // slices above, so it never exceeds the producer capacity that
                    // was exposed while the channel lock excluded other producers.
                    unsafe { chan.tx.advance_write_index(count) };
"""

ST_SEND_PUBLISH_NEW = """                    // Publish the control messages *before* the bytes they belong
                    // to become visible, so a concurrent reader can never observe
                    // this message's data without its ancillary data.
                    if count > 0 && !ancillary_published {
                        chan.outgoing_ancillary
                            .lock()
                            .push_back(core::mem::take(&mut ancillary));
                        ancillary_published = true;
                    }
                    // SAFETY: `count` is the sum of bytes written into the vacant
                    // slices above, so it never exceeds the producer capacity that
                    // was exposed while the channel lock excluded other producers.
                    unsafe { chan.tx.advance_write_index(count) };
"""

ST_RECV_SETUP_OLD = """        let is_zero_length = dst.remaining_mut() == 0;
        self.options
            .recv_poller_with_nonblocking(self, options.flags.nonblocking(), || {
"""

ST_RECV_SETUP_NEW = """        let is_zero_length = dst.remaining_mut() == 0;
        let mut ancillary_out = options.ancillary;
        self.options
            .recv_poller_with_nonblocking(self, options.flags.nonblocking(), || {
"""

ST_RECV_DELIVER_OLD = """                if count > 0 {
                    let occupied_after = occupied_before - count;
                    if !channel::is_stream_writable(occupied_before)
                        && channel::is_stream_writable(occupied_after)
                    {
                        chan.peer_endpoint.polls.writable.wake();
                    }
                    return Ok(count);
                }
"""

ST_RECV_DELIVER_NEW = """                if count > 0 {
                    // Hand the peer's control messages to this read. Linux delivers
                    // a message's ancillary data with the first successful receive
                    // that consumes any of its bytes, so pop exactly one batch.
                    if let Some(out) = ancillary_out.as_mut()
                        && let Some(mut received) = chan.incoming_ancillary.lock().pop_front()
                    {
                        out.append(&mut received);
                    }
                    let occupied_after = occupied_before - count;
                    if !channel::is_stream_writable(occupied_before)
                        && channel::is_stream_writable(occupied_after)
                    {
                        chan.peer_endpoint.polls.writable.wake();
                    }
                    return Ok(count);
                }
"""

ST_TEST_ANCHOR_OLD = """        listener.endpoint.polls.readable.wake();
        assert_eq!(listener_read.0.load(Ordering::SeqCst), 1);
    }
}
"""

ST_TEST_ANCHOR_NEW = """        listener.endpoint.polls.readable.wake();
        assert_eq!(listener_read.0.load(Ordering::SeqCst), 1);
    }

    #[def_test]
    fn unix_stream_delivers_ancillary_data_with_the_next_read() {
        use alloc::boxed::Box;

        use crate::AncillaryData;

        let (left, right) = StreamTransport::new_pair(1);

        // One message carrying ancillary data, immediately followed by a plain
        // one, so the delivery boundary can be observed.
        let mut with_ancillary = SendOptions::default();
        with_ancillary.ancillary.push(Box::new(42_u32) as AncillaryData);
        assert_eq!(left.send(&b"a"[..], with_ancillary).unwrap(), 1);
        assert_eq!(left.send(&b"b"[..], SendOptions::default()).unwrap(), 1);

        // The first read sees both the byte and its control message.
        let mut buf = [0_u8; 1];
        let mut received: Vec<AncillaryData> = Vec::new();
        assert_eq!(
            right
                .recv(
                    &mut buf[..],
                    RecvOptions {
                        ancillary: Some(&mut received),
                        ..RecvOptions::default()
                    },
                )
                .unwrap(),
            1
        );
        assert_eq!(buf, [b'a']);
        assert_eq!(received.len(), 1);
        assert_eq!(received[0].downcast_ref::<u32>(), Some(&42));

        // The second read must not inherit the first message's control message.
        let mut received_second: Vec<AncillaryData> = Vec::new();
        assert_eq!(
            right
                .recv(
                    &mut buf[..],
                    RecvOptions {
                        ancillary: Some(&mut received_second),
                        ..RecvOptions::default()
                    },
                )
                .unwrap(),
            1
        );
        assert_eq!(buf, [b'b']);
        assert!(received_second.is_empty());
    }
}
"""


def apply(path: str, label: str, old: str, new: str, stats: list) -> int:
    with open(path, "r", encoding="utf-8", newline="") as f:
        content = f.read()

    if new in content:
        print(f"  [skip] {label}: already patched")
        return 0

    count = content.count(old)
    if count != 1:
        print(f"  [FAIL] {label}: expected exactly 1 occurrence, found {count}")
        stats.append(1)
        return 0

    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(content.replace(old, new, 1))
    print(f"  [ok]   {label}: replaced")
    return 1


def apply_channel_imports(path: str, failures: list) -> int:
    """把 channel.rs 的 import 段规范化到 CH_IMPORTS_TARGET（幂等，兼容两种前态）。"""
    with open(path, "r", encoding="utf-8", newline="") as f:
        content = f.read()

    if CH_IMPORTS_TARGET in content:
        print("  [skip] imports: already patched")
        return 0

    for old, note in (
        (CH_IMPORTS_FRESH_OLD, "from unpatched tree"),
        (CH_IMPORTS_V1_OLD, "fixup: add missing alloc::vec::Vec"),
    ):
        if content.count(old) == 1:
            with open(path, "w", encoding="utf-8", newline="") as f:
                f.write(content.replace(old, CH_IMPORTS_TARGET, 1))
            print(f"  [ok]   imports: replaced ({note})")
            return 1

    print("  [FAIL] imports: no known pre-patch form found")
    failures.append(1)
    return 0


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2

    root = sys.argv[1]
    channel = os.path.join(root, CHANNEL_RS)
    stream = os.path.join(root, STREAM_RS)
    for p in (channel, stream):
        if not os.path.isfile(p):
            print(f"[FAIL] not found: {p}")
            return 2

    failures = []
    changed = 0

    print(f"== {CHANNEL_RS} ==")
    changed += apply_channel_imports(channel, failures)
    changed += apply(channel, "Channel + new_duplex_channel (ancillary queues)", CH_DUPLEX_OLD, CH_DUPLEX_NEW, failures)

    print(f"== {STREAM_RS} ==")
    changed += apply(stream, "send() setup: hold ancillary until published", ST_SEND_SETUP_OLD, ST_SEND_SETUP_NEW, failures)
    changed += apply(stream, "send(): queue ancillary before advancing write index", ST_SEND_PUBLISH_OLD, ST_SEND_PUBLISH_NEW, failures)
    changed += apply(stream, "recv() setup: capture ancillary out-param", ST_RECV_SETUP_OLD, ST_RECV_SETUP_NEW, failures)
    changed += apply(stream, "recv(): deliver one ancillary batch per read", ST_RECV_DELIVER_OLD, ST_RECV_DELIVER_NEW, failures)
    changed += apply(stream, "add unit test for ancillary delivery", ST_TEST_ANCHOR_OLD, ST_TEST_ANCHOR_NEW, failures)

    if failures:
        print(f"\n[FAIL] {len(failures)} anchor(s) not matched — nothing else was touched for those.")
        return 1

    print(f"\n[done] {changed} edit(s) applied (idempotent re-run reports skips).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
