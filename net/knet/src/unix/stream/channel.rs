// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

//! Connected Unix stream channel state.

use alloc::{collections::VecDeque, sync::Arc, vec::Vec};
use core::sync::atomic::{AtomicBool, AtomicI32, Ordering};

use kerrno::LinuxError;
use kpoll::{IoEvents, PollContext, PollRegisterError, PollSet};
use kspin::SpinNoPreempt;
use ksync::Mutex;
use ringbuf::{
    HeapCons, HeapProd, HeapRb,
    traits::{Observer, Split},
};

use crate::AncillaryData;

pub(super) const STREAM_BUF_BYTES: usize = 64 * 1024;
pub(super) const STREAM_WRITABLE_MAX_OCCUPIED_BYTES: usize = STREAM_BUF_BYTES / 4;

pub(super) fn is_stream_writable(occupied_bytes: usize) -> bool {
    occupied_bytes <= STREAM_WRITABLE_MAX_OCCUPIED_BYTES
}

fn new_ring_pair() -> (HeapProd<u8>, HeapCons<u8>) {
    let rb = HeapRb::new(STREAM_BUF_BYTES);
    rb.split()
}

#[derive(Default)]
pub(super) struct StreamPollSets {
    pub(super) readable: PollSet,
    pub(super) writable: PollSet,
    state: PollSet,
}

impl StreamPollSets {
    pub(super) fn register(
        &self,
        context: &mut PollContext<'_>,
        events: IoEvents,
    ) -> Result<(), PollRegisterError> {
        let has_read_events =
            events.intersects(IoEvents::IN | IoEvents::RDNORM | IoEvents::RDBAND | IoEvents::RDHUP);
        let has_write_events =
            events.intersects(IoEvents::OUT | IoEvents::WRNORM | IoEvents::WRBAND);
        if has_read_events {
            context.register(&self.readable)?;
        }
        if has_write_events {
            context.register(&self.writable)?;
        }
        if !has_read_events && !has_write_events && events.intersects(IoEvents::ERR | IoEvents::HUP)
        {
            context.register(&self.state)?;
        }
        Ok(())
    }

    pub(super) fn wake_state_change(&self) {
        self.readable.wake();
        self.writable.wake();
        self.state.wake();
    }
}

#[derive(Default)]
pub(super) struct StreamEndpoint {
    pub(super) polls: StreamPollSets,
    pub(super) pass_credentials: AtomicBool,
    /// Orders data publication, shutdown, and EOF observation for this
    /// endpoint's transmit direction.
    pub(super) tx_order: SpinNoPreempt<()>,
    pub(super) rx_closed: AtomicBool,
    pub(super) tx_closed: AtomicBool,
    pub(super) socket_error: AtomicI32,
}

/// One stream write boundary and the control messages attached to it.
///
/// Linux stream sockets preserve the boundary of a `sendmsg` which carries
/// ancillary data: a large `recvmsg` stops at that boundary so the receiver can
/// associate the `SCM_RIGHTS` list with exactly one message. Keeping the byte
/// count here prevents a ring-buffer read from coalescing two Mojo messages and
/// returning only the first message's handles.
pub(super) struct AncillaryBatch {
    pub(super) bytes_remaining: usize,
    pub(super) data: Vec<AncillaryData>,
}

/// Stream write boundaries travelling in one direction.
pub(super) type AncillaryQueue = Arc<Mutex<VecDeque<AncillaryBatch>>>;

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

impl Drop for Channel {
    fn drop(&mut self) {
        let (is_rx_changed, has_unread_input) = {
            let _tx_order = self.peer_endpoint.tx_order.lock();
            (
                !self.endpoint.rx_closed.swap(true, Ordering::AcqRel),
                self.rx.occupied_len() > 0,
            )
        };
        let is_tx_changed = {
            let _tx_order = self.endpoint.tx_order.lock();
            !self.endpoint.tx_closed.swap(true, Ordering::AcqRel)
        };
        if has_unread_input {
            self.peer_endpoint
                .socket_error
                .store(LinuxError::ECONNRESET.into_raw(), Ordering::Release);
        }
        if is_rx_changed || is_tx_changed || has_unread_input {
            self.endpoint.polls.wake_state_change();
            self.peer_endpoint.polls.wake_state_change();
        }
    }
}
