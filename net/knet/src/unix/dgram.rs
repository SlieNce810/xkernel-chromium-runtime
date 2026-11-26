// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

//! Unix datagram socket transport.
use alloc::{boxed::Box, sync::Arc, vec::Vec};
use core::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use async_channel::TryRecvError;
use async_trait::async_trait;
use kerrno::{KError, KResult};
use kio::{IoBufMut, Read, Write};
use kpoll::{IoEvents, PollContext, PollRegisterError, PollSet, Pollable};
use ksync::{Mutex, RwLock};

use crate::{
    AncillaryData, ConnectOptions, KernelAncillaryData, RecvFlags, RecvOptions, SendOptions,
    Shutdown, SocketAddrEx,
    general::GeneralOptions,
    options::{Configurable, GetSocketOption, OptionHandled, SetSocketOption, UnixCredentials},
    unix::{UnixAddr, UnixTransport, UnixTransportOps, lookup_bind_entry},
};

static CHROMIUM_DGRAM_TRACE_COUNT: AtomicUsize = AtomicUsize::new(0);

fn chromium_dgram_trace() -> Option<usize> {
    let argv = kprocess::try_current_user_process()?.cmdline().ok()?;
    if !argv.iter().any(|arg| arg.contains("/chromium")) {
        return None;
    }
    let seq = CHROMIUM_DGRAM_TRACE_COUNT.fetch_add(1, Ordering::Relaxed);
    (seq < 512).then_some(seq)
}

struct Datagram {
    data: Vec<u8>,
    ancillary: Vec<AncillaryData>,
    sender: UnixAddr,
    sender_credentials: UnixCredentials,
}

struct Channel {
    tx: async_channel::Sender<Datagram>,
    poll: Arc<PollSet>,
    peer_write_shutdown: Arc<AtomicBool>,
}

pub struct Bind {
    tx: async_channel::Sender<Datagram>,
    poll: Arc<PollSet>,
    write_shutdown: Arc<AtomicBool>,
}
impl Bind {
    fn connect(&self) -> Channel {
        let tx = self.tx.clone();
        Channel {
            tx,
            poll: self.poll.clone(),
            peer_write_shutdown: self.write_shutdown.clone(),
        }
    }
}

pub struct DgramTransport {
    rx: Mutex<Option<(async_channel::Receiver<Datagram>, Arc<PollSet>)>>,
    // Preserve a packet tail when the VM I/O adapter exposes only a partial
    // user-buffer window. This matters for SOCK_SEQPACKET messages larger than
    // one page: a subsequent read must not silently lose the remainder.
    pending: Mutex<Option<Datagram>>,
    // Hold a packet observed with MSG_PEEK until a non-peek receive consumes it.
    peeked: Mutex<Option<Datagram>>,
    peer: RwLock<Option<Channel>>,
    local_addr: RwLock<UnixAddr>,
    bind_slot: Mutex<Option<Arc<Mutex<Option<Bind>>>>>,
    poll_state: Arc<PollSet>,
    options: GeneralOptions,
    pass_credentials: AtomicBool,
    read_shutdown: AtomicBool,
    write_shutdown: Arc<AtomicBool>,
    pid: u32,
}
impl DgramTransport {
    pub fn new(pid: u32) -> Self {
        DgramTransport {
            rx: Mutex::new(None),
            pending: Mutex::new(None),
            peeked: Mutex::new(None),
            peer: RwLock::new(None),
            local_addr: RwLock::new(UnixAddr::Unbound),
            bind_slot: Mutex::new(None),
            poll_state: Arc::default(),
            options: GeneralOptions::default(),
            pass_credentials: AtomicBool::new(false),
            read_shutdown: AtomicBool::new(false),
            write_shutdown: Arc::new(AtomicBool::new(false)),
            pid,
        }
    }

    fn new_connected(
        rx: (async_channel::Receiver<Datagram>, Arc<PollSet>),
        peer: Channel,
        pid: u32,
        write_shutdown: Arc<AtomicBool>,
    ) -> Self {
        DgramTransport {
            rx: Mutex::new(Some(rx)),
            pending: Mutex::new(None),
            peeked: Mutex::new(None),
            peer: RwLock::new(Some(peer)),
            local_addr: RwLock::new(UnixAddr::Unbound),
            bind_slot: Mutex::new(None),
            poll_state: Arc::default(),
            options: GeneralOptions::default(),
            pass_credentials: AtomicBool::new(false),
            read_shutdown: AtomicBool::new(false),
            write_shutdown,
            pid,
        }
    }

    pub fn new_pair(pid: u32) -> (Self, Self) {
        let (tx1, rx1) = async_channel::unbounded();
        let (tx2, rx2) = async_channel::unbounded();
        let poll1 = Arc::new(PollSet::new());
        let poll2 = Arc::new(PollSet::new());
        let write1 = Arc::new(AtomicBool::new(false));
        let write2 = Arc::new(AtomicBool::new(false));
        let transport1 = DgramTransport::new_connected(
            (rx1, poll1.clone()),
            Channel {
                tx: tx2,
                poll: poll2.clone(),
                peer_write_shutdown: write2.clone(),
            },
            pid,
            write1.clone(),
        );
        let transport2 = DgramTransport::new_connected(
            (rx2, poll2.clone()),
            Channel {
                tx: tx1,
                poll: poll1.clone(),
                peer_write_shutdown: write1.clone(),
            },
            pid,
            write2.clone(),
        );
        (transport1, transport2)
    }
}

impl Configurable for DgramTransport {
    fn get_option_inner(&self, opt: &mut GetSocketOption) -> KResult<OptionHandled> {
        use GetSocketOption as O;

        if self.options.get_option_inner(opt)?.is_yes() {
            return Ok(OptionHandled::Yes);
        }

        match opt {
            O::PassCredentials(enabled) => {
                **enabled = self.pass_credentials.load(Ordering::Acquire);
            }
            O::PeerCredentials(cred) => {
                // Datagram sockets are stateless and do not have a peer, so we
                // return the credentials of the process that created the
                // socket.
                **cred = UnixCredentials::new(self.pid);
            }
            _ => return Ok(OptionHandled::No),
        }
        Ok(OptionHandled::Yes)
    }

    fn set_option_inner(&self, opt: SetSocketOption) -> KResult<OptionHandled> {
        use SetSocketOption as O;

        if self.options.set_option_inner(opt)?.is_yes() {
            return Ok(OptionHandled::Yes);
        }

        match opt {
            O::PassCredentials(enabled) => {
                self.pass_credentials.store(*enabled, Ordering::Release);
            }
            _ => return Ok(OptionHandled::No),
        }
        Ok(OptionHandled::Yes)
    }
}
#[async_trait]
impl UnixTransportOps for DgramTransport {
    fn bind(&self, slot: &super::BindEntry, local_addr: &UnixAddr) -> KResult {
        let bind_slot_handle = slot.dgram.clone();
        let mut slot = slot.dgram.lock();
        if slot.is_some() {
            return Err(KError::AddrInUse);
        }
        let mut guard = self.rx.lock();
        if guard.is_some() {
            return Err(KError::InvalidInput);
        }
        let (tx, rx) = async_channel::unbounded();
        let poll = Arc::new(PollSet::new());
        *slot = Some(Bind {
            tx,
            poll: poll.clone(),
            write_shutdown: self.write_shutdown.clone(),
        });
        drop(slot);
        *guard = Some((rx, poll));
        self.local_addr.write().clone_from(local_addr);
        *self.bind_slot.lock() = Some(bind_slot_handle);
        self.poll_state.wake();
        Ok(())
    }

    fn connect(
        &self,
        slot: &super::BindEntry,
        _local_addr: &UnixAddr,
        _options: ConnectOptions,
    ) -> KResult {
        let mut guard = self.peer.write();
        if guard.is_some() {
            return Err(KError::AlreadyConnected);
        }
        *guard = Some(
            slot.dgram
                .lock()
                .as_ref()
                .ok_or(KError::NotConnected)?
                .connect(),
        );
        self.poll_state.wake();
        Ok(())
    }

    async fn accept(&self, _nonblocking: bool) -> KResult<(UnixTransport, UnixAddr)> {
        Err(KError::InvalidInput)
    }

    fn send(&self, mut src: impl Read, options: SendOptions) -> KResult<usize> {
        if self.write_shutdown.load(Ordering::Acquire) {
            return Err(KError::BrokenPipe);
        }
        let mut message = Vec::new();
        src.read_to_end(&mut message)?;
        let len = message.len();
        let trace_seq = chromium_dgram_trace();
        if let Some(seq) = trace_seq {
            if len > 4096 || !options.ancillary.is_empty() {
                warn!("CHROMIUM_DGRAM_SEND seq={} pid={} len={} ancillary={}",
                    seq,
                    kprocess::current_user_thread().pid(),
                    len,
                    options.ancillary.len());
            }
        }
        let caller_cred = kprocess::current_cred();
        let sender_credentials = UnixCredentials {
            pid: kprocess::current_user_thread().pid(),
            uid: caller_cred.euid(),
            gid: caller_cred.egid(),
        };
        let packet = Datagram {
            data: message,
            ancillary: options.ancillary,
            sender: self.local_addr.read().clone(),
            sender_credentials,
        };

        let connected = self.peer.read();
        if let Some(addr) = options.to {
            if self.write_shutdown.load(Ordering::Acquire) {
                return Err(KError::BrokenPipe);
            }
            let addr = addr.into_unix()?;
            let cred = caller_cred;
            lookup_bind_entry(&addr, &cred, |slot| {
                if let Some(bind) = slot.dgram.lock().as_ref() {
                    bind.tx.try_send(packet).map_err(|_| KError::BrokenPipe)?;
                    bind.poll.wake();
                    Ok(())
                } else {
                    Err(KError::NotConnected)
                }
            })?;
        } else if let Some(chan) = connected.as_ref() {
            if self.write_shutdown.load(Ordering::Acquire) {
                return Err(KError::BrokenPipe);
            }
            chan.tx.try_send(packet).map_err(|_| KError::BrokenPipe)?;
            chan.poll.wake();
        } else {
            return Err(KError::NotConnected);
        }
        Ok(len)
    }

    fn recv(&self, mut dst: impl Write + IoBufMut, mut options: RecvOptions) -> KResult<usize> {
        let peek = options.flags.contains(RecvFlags::PEEK);
        self.options.recv_poller(self, move || {
            let peer_write_shutdown = self
                .peer
                .read()
                .as_ref()
                .is_some_and(|peer| peer.peer_write_shutdown.load(Ordering::Acquire));
            if self.read_shutdown.load(Ordering::Acquire) {
                return Ok(0);
            }
            let packet = if let Some(packet) = self.pending.lock().take() {
                packet
            } else if let Some(packet) = self.peeked.lock().take() {
                packet
            } else {
                let mut guard = self.rx.lock();
                let Some((rx, _)) = guard.as_mut() else {
                    return Err(KError::NotConnected);
                };
                match rx.try_recv() {
                    Ok(packet) => packet,
                    Err(TryRecvError::Empty) => {
                        if peer_write_shutdown {
                            return Ok(0);
                        }
                        return Err(KError::WouldBlock);
                    }
                    Err(TryRecvError::Closed) => return Ok(0),
                }
            };

            let Datagram {
                data,
                ancillary,
                sender,
                sender_credentials,
            } = packet;
            let packet_len = data.len();
            let mut count = 0;
            while count < data.len() {
                let written = dst.write(&data[count..])?;
                if written == 0 {
                    break;
                }
                count += written;
            }
            if let Some(seq) = chromium_dgram_trace() {
                if packet_len > 4096 || !ancillary.is_empty() {
                    warn!("CHROMIUM_DGRAM_RECV seq={} pid={} packet_len={} copied={} ancillary={} peek={}",
                        seq,
                        kprocess::current_user_thread().pid(),
                        packet_len,
                        count,
                        ancillary.len(),
                        peek);
                }
            }
            if peek {
                let sender_for_from = sender.clone();
                self.peeked.lock().replace(Datagram {
                    data,
                    ancillary,
                    sender,
                    sender_credentials,
                });
                if let Some(from) = options.from.as_mut() {
                    **from = SocketAddrEx::Unix(sender_for_from);
                }
                return Ok(if options.flags.contains(RecvFlags::TRUNCATE) {
                    packet_len
                } else {
                    count
                });
            }
            if count < data.len() && !options.flags.contains(RecvFlags::TRUNCATE) {
                self.pending.lock().replace(Datagram {
                    data: data[count..].to_vec(),
                    ancillary: Vec::new(),
                    sender: sender.clone(),
                    sender_credentials: sender_credentials.clone(),
                });
            }
            if count < packet_len {
                warn!("UDP message truncated: {} -> {} bytes", packet_len, count);
            }

            if let Some(from) = options.from.as_mut() {
                **from = SocketAddrEx::Unix(sender);
            }
            if let Some(dst) = options.ancillary.as_mut() {
                if self.pass_credentials.load(Ordering::Acquire) {
                    dst.push(Box::new(KernelAncillaryData::Credentials(
                        sender_credentials,
                    )));
                }
                dst.extend(ancillary);
            }

            Ok(if options.flags.contains(RecvFlags::TRUNCATE) {
                packet_len
            } else {
                count
            })
        })
    }

    fn shutdown(&self, how: Shutdown) -> KResult<()> {
        let read_changed = how.has_read() && !self.read_shutdown.swap(true, Ordering::AcqRel);
        let write_changed = how.has_write() && !self.write_shutdown.swap(true, Ordering::AcqRel);
        if read_changed || write_changed {
            self.poll_state.wake();
            if let Some(peer) = self.peer.read().as_ref() {
                peer.poll.wake();
            }
        }
        Ok(())
    }
}

impl Pollable for DgramTransport {
    fn poll(&self) -> IoEvents {
        let mut events = IoEvents::OUT;
        let peer_write_shutdown = self
            .peer
            .read()
            .as_ref()
            .is_some_and(|peer| peer.peer_write_shutdown.load(Ordering::Acquire));
        if self.read_shutdown.load(Ordering::Acquire) || peer_write_shutdown {
            events.insert(IoEvents::IN);
        } else if let Some((rx, _)) = self.rx.lock().as_ref() {
            events.set(IoEvents::IN, !rx.is_empty());
        }
        events
    }

    fn register(
        &self,
        context: &mut PollContext<'_>,
        events: IoEvents,
    ) -> Result<(), PollRegisterError> {
        if let Some((_, poll)) = self.rx.lock().as_ref()
            && events.contains(IoEvents::IN)
        {
            context.register(poll)?;
        }
        Ok(())
    }
}

impl Drop for DgramTransport {
    fn drop(&mut self) {
        if let Some(slot) = self.bind_slot.lock().take() {
            *slot.lock() = None;
        }
        if let Some(chan) = self.peer.write().take() {
            chan.poll.wake();
        }
    }
}
