// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

//! Inotify fd state used by POSIX filesystem syscalls.

use alloc::{
    collections::VecDeque,
    sync::{Arc, Weak},
    vec::Vec,
};
use core::sync::atomic::{AtomicI32, Ordering};

use anon_inodefs::AnonInodeFs;
use kcred::Cred;
use kerrno::{KError, KResult, LinuxError};
use kpoll::{IoEvents, PollContext, PollRegisterError, PollSet, Pollable};
use ksync::{Mutex, static_lock};
use ktask::future::{block_on, poll_io};
use kvfs::{FMode, FileOperations, OpenFlags, VfsFile, VfsInode};

pub const IN_ACCESS: u32 = 0x0000_0001;
pub const IN_MODIFY: u32 = 0x0000_0002;
pub const IN_ATTRIB: u32 = 0x0000_0004;
pub const IN_CLOSE_WRITE: u32 = 0x0000_0008;
pub const IN_CLOSE_NOWRITE: u32 = 0x0000_0010;
pub const IN_OPEN: u32 = 0x0000_0020;
pub const IN_MOVED_FROM: u32 = 0x0000_0040;
pub const IN_MOVED_TO: u32 = 0x0000_0080;
pub const IN_CREATE: u32 = 0x0000_0100;
pub const IN_DELETE: u32 = 0x0000_0200;
pub const IN_DELETE_SELF: u32 = 0x0000_0400;
pub const IN_MOVE_SELF: u32 = 0x0000_0800;
pub const IN_UNMOUNT: u32 = 0x0000_2000;
pub const IN_Q_OVERFLOW: u32 = 0x0000_4000;
pub const IN_IGNORED: u32 = 0x0000_8000;
pub const IN_ONLYDIR: u32 = 0x0100_0000;
pub const IN_DONT_FOLLOW: u32 = 0x0200_0000;
pub const IN_EXCL_UNLINK: u32 = 0x0400_0000;
pub const IN_MASK_CREATE: u32 = 0x1000_0000;
pub const IN_MASK_ADD: u32 = 0x2000_0000;
pub const IN_ISDIR: u32 = 0x4000_0000;
pub const IN_ONESHOT: u32 = 0x8000_0000;

pub const IN_ALL_EVENTS: u32 = IN_ACCESS
    | IN_MODIFY
    | IN_ATTRIB
    | IN_CLOSE_WRITE
    | IN_CLOSE_NOWRITE
    | IN_OPEN
    | IN_MOVED_FROM
    | IN_MOVED_TO
    | IN_CREATE
    | IN_DELETE
    | IN_DELETE_SELF
    | IN_MOVE_SELF;

const INOTIFY_EVENT_SIZE: usize = 16;
const INOTIFY_QUEUE_LIMIT: usize = 16_384;

static_lock! {
    static INOTIFY_INSTANCES: Mutex<Vec<Weak<InotifyFd>>> = Mutex::new(Vec::new());
}

struct Watch {
    wd: i32,
    inode: Arc<VfsInode>,
    mask: u32,
    oneshot: bool,
}

/// One `inotify_init1` instance and its installed inode watches.
pub struct InotifyFd {
    watches: Mutex<Vec<Watch>>,
    queue: Mutex<VecDeque<[u8; INOTIFY_EVENT_SIZE]>>,
    poll_rx: PollSet,
    next_wd: AtomicI32,
}

impl InotifyFd {
    fn new() -> Arc<Self> {
        let instance = Arc::new(Self {
            watches: Mutex::new(Vec::new()),
            queue: Mutex::new(VecDeque::new()),
            poll_rx: PollSet::new(),
            next_wd: AtomicI32::new(1),
        });
        INOTIFY_INSTANCES
            .lock()
            .push(Arc::downgrade(&instance));
        instance
    }

    /// Creates the anonymous-inode file backing one inotify instance.
    pub fn new_file(open_flags: u32, cred: Arc<Cred>) -> KResult<Arc<VfsFile>> {
        let open_flags = OpenFlags::from_bits(open_flags).ok_or(KError::InvalidInput)?;
        AnonInodeFs::global().get_file(
            "[inotify]",
            Arc::new(InotifyFops),
            Self::new(),
            FMode::READ | FMode::STREAM,
            open_flags,
            cred,
        )
    }

    /// Retrieves inotify state attached to an open file.
    pub fn from_file(file: &VfsFile) -> KResult<Arc<Self>> {
        file.private_data_get::<Self>()
            .ok_or(KError::BadFileDescriptor)
    }

    /// Adds a watch for an inode or updates the existing watch on that inode.
    pub fn add_watch(&self, inode: Arc<VfsInode>, mask: u32) -> KResult<i32> {
        let event_mask = mask & IN_ALL_EVENTS;
        let mask_add = mask & IN_MASK_ADD != 0;
        let mask_create = mask & IN_MASK_CREATE != 0;
        if mask_add && mask_create {
            return Err(KError::InvalidInput);
        }

        let mut watches = self.watches.lock();
        if let Some(watch) = watches
            .iter_mut()
            .find(|watch| Arc::ptr_eq(&watch.inode, &inode))
        {
            if mask_create {
                return Err(LinuxError::EEXIST.into());
            }
            if mask_add {
                watch.mask |= event_mask;
            } else {
                watch.mask = event_mask;
            }
            watch.oneshot = mask & IN_ONESHOT != 0;
            return Ok(watch.wd);
        }

        let wd = self.next_wd.fetch_add(1, Ordering::Relaxed);
        watches.push(Watch {
            wd,
            inode,
            mask: event_mask,
            oneshot: mask & IN_ONESHOT != 0,
        });
        Ok(wd)
    }

    /// Removes a watch and queues Linux's `IN_IGNORED` completion event.
    pub fn remove_watch(&self, wd: i32) -> KResult<()> {
        let mut watches = self.watches.lock();
        let Some(index) = watches.iter().position(|watch| watch.wd == wd) else {
            return Err(LinuxError::EINVAL.into());
        };
        watches.swap_remove(index);
        drop(watches);
        self.push_event(wd, IN_IGNORED);
        Ok(())
    }

    fn notify_inode(&self, inode: &Arc<VfsInode>, event_mask: u32) {
        let mut matched = Vec::new();
        {
            let mut watches = self.watches.lock();
            watches.retain(|watch| {
                if !Arc::ptr_eq(&watch.inode, inode) {
                    return true;
                }
                let mask = watch.mask & event_mask;
                if mask != 0 {
                    let directory = inode.node_type() == kvfs::NodeType::Directory;
                    matched.push((watch.wd, mask | if directory { IN_ISDIR } else { 0 }));
                    if watch.oneshot {
                        matched.push((watch.wd, IN_IGNORED));
                        return false;
                    }
                }
                true
            });
        }
        if matched.is_empty() {
            return;
        }

        let mut queue = self.queue.lock();
        let mut appended = false;
        for (wd, mask) in matched {
            if queue.len() >= INOTIFY_QUEUE_LIMIT {
                if !queue
                    .iter()
                    .any(|event| i32::from_ne_bytes(event[0..4].try_into().unwrap()) == -1)
                {
                    queue.push_back(inotify_event(-1, IN_Q_OVERFLOW));
                }
                break;
            }
            queue.push_back(inotify_event(wd, mask));
            appended = true;
        }
        drop(queue);
        if appended {
            self.poll_rx.wake();
        }
    }

    fn push_event(&self, wd: i32, mask: u32) {
        let mut queue = self.queue.lock();
        if queue.len() < INOTIFY_QUEUE_LIMIT {
            queue.push_back(inotify_event(wd, mask));
            drop(queue);
            self.poll_rx.wake();
        }
    }

    fn read_events(&self, buf: &mut [u8]) -> KResult<usize> {
        if buf.len() < INOTIFY_EVENT_SIZE {
            return Err(KError::InvalidInput);
        }
        let mut queue = self.queue.lock();
        if queue.is_empty() {
            return Err(KError::WouldBlock);
        }
        let mut written = 0;
        while let Some(event) = queue.front() {
            if written + INOTIFY_EVENT_SIZE > buf.len() {
                break;
            }
            buf[written..written + INOTIFY_EVENT_SIZE].copy_from_slice(event);
            written += INOTIFY_EVENT_SIZE;
            queue.pop_front();
        }
        self.poll_rx.wake();
        Ok(written)
    }
}

/// Queues an event for inotify instances watching this inode.
pub fn notify_inode_event(inode: &Arc<VfsInode>, event_mask: u32) {
    let mut instances = INOTIFY_INSTANCES.lock();
    instances.retain(|weak| {
        let Some(instance) = weak.upgrade() else {
            return false;
        };
        instance.notify_inode(inode, event_mask);
        true
    });
}

fn inotify_event(wd: i32, mask: u32) -> [u8; INOTIFY_EVENT_SIZE] {
    let mut event = [0; INOTIFY_EVENT_SIZE];
    event[0..4].copy_from_slice(&wd.to_ne_bytes());
    event[4..8].copy_from_slice(&mask.to_ne_bytes());
    // cookie = 0 and len = 0 because these inode events have no child name.
    event
}

struct InotifyFops;

impl InotifyFops {
    fn state(file: &VfsFile) -> kio::Result<Arc<InotifyFd>> {
        InotifyFd::from_file(file)
    }
}

impl FileOperations for InotifyFops {
    fn supports_read(&self) -> bool {
        true
    }

    fn read(&self, file: &VfsFile, buf: &mut [u8], _offset: u64) -> kio::Result<usize> {
        let state = Self::state(file)?;
        block_on(poll_io(
            state.as_ref(),
            IoEvents::IN,
            file.is_nonblocking(),
            || state.read_events(buf),
        ))
    }

    fn poll(&self, file: &VfsFile) -> IoEvents {
        Self::state(file)
            .map(|state| state.poll())
            .unwrap_or_else(|_| IoEvents::empty())
    }

    fn register_poll(
        &self,
        file: &VfsFile,
        context: &mut PollContext<'_>,
        events: IoEvents,
    ) -> Result<(), PollRegisterError> {
        if let Ok(state) = Self::state(file) {
            state.register(context, events)?;
        }
        Ok(())
    }
}

impl Pollable for InotifyFd {
    fn poll(&self) -> IoEvents {
        if self.queue.lock().is_empty() {
            IoEvents::empty()
        } else {
            IoEvents::IN
        }
    }

    fn register(
        &self,
        context: &mut PollContext<'_>,
        events: IoEvents,
    ) -> Result<(), PollRegisterError> {
        if events.contains(IoEvents::IN) {
            context.register(&self.poll_rx)?;
        }
        Ok(())
    }
}
