// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

use alloc::{
    format,
    string::{String, ToString},
    sync::Arc,
    vec,
    vec::Vec,
};

use bitmaps::Bitmap;
use kclass::ClassDevice;
#[allow(unused_imports)]
use kclass::prelude::{DriverError, Event, EventType, InputDevice, InputDeviceId, InputDeviceImpl};
use kdevice::{DeviceLocation, subscribe_device_removed};
use kerrno::{KError, KResult};
use kpoll::{IoEvents, PollContext, PollRegisterError, PollSet, Pollable};
use kprocess::current_user_thread;
use ksync::Mutex;
use kvfs::{
    DeviceFileOps, DeviceId, DirMapping, NodeFlags, SimpleDir, SimpleFs, VfsFile, VfsFileBuilder,
    VfsInode, VfsResult,
};
use linux_raw_sys::{
    general::{__kernel_old_time_t, __kernel_suseconds_t},
    ioctl::{EVIOCGID, EVIOCGRAB, EVIOCGVERSION},
};
use posix_types::{InputId, UserPtr};
use zerocopy::{FromBytes, Immutable, IntoBytes};

use crate::{DeviceFile, add_device_entry};

const KEY_CNT: usize = EventType::Key.bits_count();

struct Inner {
    device: Option<ClassDevice<InputDeviceImpl>>,
    /// 事件时间戳，单位是 CLOCK_MONOTONIC 纳秒。
    ///
    /// 为什么不能用 `ktime::realtime()`：evdev 协议规定 `struct input_event.time`
    /// 是单调时钟，libinput 会把它和自己的 `libinput_now()`（同样是单调毫秒）相减。
    /// 用墙钟（2026 年 ≈1.79e9 秒）去相减，得到的是约 -1.6e9 毫秒的负值：
    /// Weston 日志里实测 `libinput bug: timer event1 debounce: offset more than 5s,
    /// now 77592 expire -1617858649`。时间戳一错，libinput 的 debounce/tap 状态机
    /// 全部失真，按键与点击都可能被判成重复或过期事件。
    read_ahead: Option<(u64, Event)>,
    key_state: Bitmap<KEY_CNT>,
}
impl Inner {
    fn has_event(&mut self) -> bool {
        let Some(device) = self.device.as_mut() else {
            self.read_ahead = None;
            return false;
        };
        if self.read_ahead.is_none() {
            match device.read_event() {
                Ok(event) => {
                    warn!(
                        "evdev event type={} code={} value={}",
                        event.event_type, event.code, event.value
                    );
                    if event.event_type == EventType::Key as u16 {
                        if event.value == 0 {
                            self.key_state.set(event.code as usize, false);
                        } else if event.value == 1 {
                            self.key_state.set(event.code as usize, true);
                        }
                    }
                    self.read_ahead = Some((khal::time::monotonic_time_nanos(), event));
                }
                Err(DriverError::WouldBlock) => {}
                Err(err) => {
                    warn!("Failed to read event: {err:?}");
                }
            }
        }
        self.read_ahead.is_some()
    }
}

pub struct EventDev {
    inner: Mutex<Inner>,
    ev_bits: Bitmap<{ EventType::COUNT as usize }>,
    poll_set: PollSet,
}

impl EventDev {
    pub fn new(device: ClassDevice<InputDeviceImpl>) -> Arc<Self> {
        let mut ev_bits = Bitmap::new();
        for i in 0..EventType::COUNT {
            let Some(ty) = EventType::from_repr(i) else {
                continue;
            };
            if device
                .get_event_bits(ty, &mut [])
                .is_ok_and(|success| success)
            {
                ev_bits.set(i as usize, true);
            }
        }

        let event_dev = Arc::new(Self {
            inner: Mutex::new(Inner {
                device: Some(device),
                read_ahead: None,
                key_state: Bitmap::new(),
            }),
            ev_bits,
            poll_set: PollSet::new(),
        });
        // Compatibility bridge until virtio-input exposes queue-transition
        // notifications: poll the existing pull-style driver and wake epoll
        // waiters whenever an event becomes readable.
        //
        // 两个必须的收敛，1 kHz 版本会把渲染拖垮（实测 guest 启动到导航
        // 240 s → 420 s，页面在 1200 s 内都没画出来）：
        //   1. 没有等待者时完全不碰 virtqueue —— 每次 has_event() 都要走一遍
        //      virtio 队列，TCG 下很贵，而启动早期根本没人等输入；
        //   2. 有等待者时用 8 ms（125 Hz）而不是 1 ms；`read_ahead` 已有事件就
        //      直接唤醒，不再重复查队列。输入 8 ms 的抖动对桌面无感。
        // 持有 Weak 而不是 Arc：设备热拔出后任务下一轮就 upgrade 失败并退出，
        // 不会把 EventDev 永久钉在内存里。
        //
        // 周期是自适应退避：有事件时 8 ms（打字/拖动手感），连续空转后 16→32→64 ms。
        // 为什么不能固定 8 ms：TCG 下一次定时器 IRQ + 任务唤醒的模拟成本很高，
        // 固定 8 ms（每设备 125 Hz）会把 guest 拖到墙钟的 40%，Chromium 首帧从
        // ~520 s 掉到 1400 s 都出不来（实测 chromium-input 轮 ready 超时）。
        // 空闲时 64 ms 只有 ~16 次/秒，几乎不影响启动；
        // 一旦有事件立刻回到 8 ms，输入延迟仍在 10 ms 量级。
        let worker = Arc::downgrade(&event_dev);
        ktask::spawn_with_name(
            move || {
                loop {
                    let Some(dev) = worker.upgrade() else {
                        break;
                    };
                    if dev.poll_set.has_waiters() {
                        let ready = {
                            let mut inner = dev.inner.lock();
                            inner.read_ahead.is_some() || inner.has_event()
                        };
                        if ready {
                            dev.poll_set.wake();
                        }
                    }
                    // 先放掉强引用再睡，否则睡眠期间设备也释放不掉。
                    drop(dev);
                    ktask::sleep(ktime_types::TimeSpan::from_millis(8));
                }
            },
            String::from("evdev-poll-wake"),
        );
        event_dev
    }

    fn subscribe_removed(self: &Arc<Self>) {
        let weak = Arc::downgrade(self);
        subscribe_device_removed(Arc::new(move |id| {
            let Some(device) = weak.upgrade() else {
                return;
            };
            if device.detach_removed(id) {
                info!("evdev: detached removed input device {:?}", id);
            }
        }));
    }

    fn detach_removed(&self, id: kdevice::DeviceId) -> bool {
        let mut inner = self.inner.lock();
        if inner.device.as_ref().is_none_or(|device| device.id() != id) {
            return false;
        }
        inner.device = None;
        inner.read_ahead = None;
        inner.key_state = Bitmap::new();
        drop(inner);
        self.poll_set.wake();
        true
    }

    fn get_event_bits(&self, arg: usize, size: usize, ty: u8) -> KResult<usize> {
        let user_bits = UserPtr::<u8>::from(arg);
        if ty == 0 {
            let len = self.ev_bits.as_bytes().len().min(size);
            user_bits.write_vm_slice(&self.ev_bits.as_bytes()[..len])?;
            Ok(len)
        } else {
            let ty = EventType::from_repr(ty).ok_or(KError::InvalidInput)?;
            let mut bits = vec![0u8; size];
            let mut inner = self.inner.lock();
            let device = inner.device.as_mut().ok_or(KError::NoSuchDevice)?;
            match device.get_event_bits(ty, &mut bits) {
                Ok(true) => {}
                Ok(false) => {
                    debug!("No events for {ty:?}");
                }
                Err(err) => {
                    warn!("Failed to get event bits: {err:?}");
                }
            }
            let len = bits.len().min(ty.bits_count().div_ceil(8));
            user_bits.write_vm_slice(&bits[..len])?;
            Ok(len)
        }
    }
}

fn return_str(arg: usize, size: usize, s: &str) -> KResult<usize> {
    let len = s.len().min(size);
    UserPtr::<u8>::from(arg).write_vm_slice(&s.as_bytes()[..len])?;
    Ok(len)
}
fn return_zero_bits(arg: usize, size: usize, bits: usize) -> KResult<usize> {
    let len = bits.div_ceil(8).min(size);
    let zeros = vec![0u8; len];
    UserPtr::<u8>::from(arg).write_vm_slice(&zeros)?;
    Ok(len)
}

#[repr(C)]
#[derive(FromBytes, IntoBytes, Immutable)]
pub struct KernelTimeval {
    pub tv_sec: __kernel_old_time_t,
    pub tv_usec: __kernel_suseconds_t,
}

#[repr(C)]
#[derive(FromBytes, IntoBytes, Immutable)]
struct InputEvent {
    time: KernelTimeval,
    event_type: u16,
    code: u16,
    value: i32,
}

#[unsafe(no_mangle)]
#[inline(never)]
pub extern "C" fn ongkey() {
    core::hint::black_box(());
}

impl DeviceFileOps for EventDev {
    fn open(&self, _inode: &VfsInode, file: &mut VfsFileBuilder) -> VfsResult<()> {
        warn!("evdev open event node");
        file.stream_open();
        Ok(())
    }

    fn supports_read(&self) -> bool {
        true
    }

    fn read(&self, _file: &VfsFile, buf: &mut [u8], _offset: u64) -> VfsResult<usize> {
        let reader_pid = current_user_thread().pid();
        warn!(
            "EVDEV_READ pid={} requested_bytes={} offset={}",
            reader_pid,
            buf.len(),
            _offset,
        );
        if buf.is_empty() {
            return Ok(0);
        }
        if buf.len() < size_of::<InputEvent>() {
            return Err(KError::InvalidInput);
        }
        let mut read = 0;
        let mut inner = self.inner.lock();
        for out in buf.chunks_exact_mut(size_of::<InputEvent>()) {
            if !inner.has_event() {
                break;
            }
            let Some((time_ns, event)) = inner.read_ahead.take() else {
                break;
            };
            let input_event = InputEvent {
                time: KernelTimeval {
                    tv_sec: (time_ns / 1_000_000_000) as _,
                    tv_usec: ((time_ns % 1_000_000_000) / 1_000) as _,
                },
                event_type: event.event_type,
                code: event.code,
                value: event.value as _,
            };
            out.copy_from_slice(input_event.as_bytes());
            read += out.len();
        }
        if read == 0 {
            Err(KError::WouldBlock)
        } else {
            Ok(read)
        }
    }

    fn flags(&self) -> NodeFlags {
        NodeFlags::NON_CACHEABLE
    }

    fn ioctl(&self, _file: &VfsFile, cmd: u32, arg: usize) -> VfsResult<usize> {
        warn!("evdev ioctl cmd={cmd:#010x} arg={arg:#x}");
        match cmd {
            EVIOCGVERSION => {
                UserPtr::<u32>::from(arg).write_vm(0x10001)?;
                Ok(0)
            }
            EVIOCGID => {
                let inner = self.inner.lock();
                let device = inner.device.as_ref().ok_or(KError::NoSuchDevice)?;
                let device_id = device.device_id();
                UserPtr::<InputId>::from(arg).write_vm(InputId {
                    bus_type: device_id.bus_type,
                    vendor: device_id.vendor,
                    product: device_id.product,
                    version: device_id.version,
                })?;
                Ok(0)
            }
            EVIOCGRAB => Ok(0),
            other => {
                // variable-length command
                let mut tmp = other;
                let nr = (tmp & 0xff) as u8;
                tmp >>= 8;
                let ty = (tmp & 0xff) as u8;
                tmp >>= 8;
                let size = (tmp & 0x3fff) as usize;
                tmp >>= 14;
                let dir = tmp & 0x3;

                if ty != b'E' {
                    warn!("unknown ioctl for evdev: {cmd} {arg}");
                    return Err(KError::InvalidInput);
                }

                match dir {
                    // IOC_WRITE
                    1 => return Err(KError::InvalidInput),
                    // IOC_READ
                    2 => {
                        #[allow(clippy::single_match)]
                        match nr {
                            // EVIOCGNAME
                            0x06 => {
                                let inner = self.inner.lock();
                                let device = inner.device.as_ref().ok_or(KError::NoSuchDevice)?;
                                return return_str(arg, size, device.name());
                            }
                            // EVIOCGPHYS
                            0x07 => {
                                let inner = self.inner.lock();
                                let device = inner.device.as_ref().ok_or(KError::NoSuchDevice)?;
                                let value = device.physical_location().to_string();
                                return return_str(arg, size, &value);
                            }
                            // EVIOCGUNIQ
                            0x08 => {
                                let inner = self.inner.lock();
                                let device = inner.device.as_ref().ok_or(KError::NoSuchDevice)?;
                                let value = device.unique_id().to_string();
                                return return_str(arg, size, &value);
                            }
                            // EVIOCGPROP
                            0x09 => {
                                // For some reasons virtio does not provide prop
                                // bits for now
                                return Ok(0);
                            }
                            // EVIOCGKEY
                            0x18 => {
                                let key_bits = self.inner.lock().key_state.as_bytes().to_vec();
                                let len = key_bits.len().min(size);
                                UserPtr::<u8>::from(arg).write_vm_slice(&key_bits[..len])?;
                                return Ok(len);
                            }
                            // EVIOCGLED
                            0x19 => {
                                return return_zero_bits(arg, size, EventType::Led.bits_count());
                            }
                            // EVIOCGSND
                            0x1a => {
                                return return_zero_bits(arg, size, EventType::Sound.bits_count());
                            }
                            // EVIOCGSW
                            0x1b => {
                                return return_zero_bits(arg, size, EventType::Switch.bits_count());
                            }
                            _ => {}
                        }
                        if nr & !EventType::MAX == EventType::COUNT {
                            return self.get_event_bits(arg, size, nr & EventType::MAX);
                        }
                        const ABS_CNT: u8 = 0x40;
                        if nr & !(ABS_CNT - 1) == ABS_CNT {
                            // EVIOCGABS(axis)：回 struct input_absinfo，
                            // 6 × s32 = value, minimum, maximum, fuzz, flat, resolution。
                            //
                            // 旧实现直接 `Ok(0)` 且不写用户缓冲区，libinput 拿到
                            // 未初始化的 absinfo 只能自己猜量程：实测把
                            // ABS_X=6937（应映射 271 px）映射成 99 px，点击全部脱靶。
                            let axis = u16::from(nr - ABS_CNT);
                            let info = {
                                let inner = self.inner.lock();
                                let device = inner.device.as_ref().ok_or(KError::NoSuchDevice)?;
                                device.abs_info(axis).ok().flatten()
                            }
                            .unwrap_or_default();
                            warn!(
                                "EVIOCGABS axis={} min={} max={} fuzz={} flat={} res={}",
                                axis, info.min, info.max, info.fuzz, info.flat, info.res
                            );
                            let mut out = [0i32; 6];
                            out[1] = info.min as i32;
                            out[2] = info.max as i32;
                            out[3] = info.fuzz as i32;
                            out[4] = info.flat as i32;
                            out[5] = info.res as i32;
                            let len = 24usize.min(size);
                            UserPtr::<u8>::from(arg).write_vm_slice(&out.as_bytes()[..len])?;
                            return Ok(len);
                        }
                        return Err(KError::InvalidInput);
                    }
                    _ => {}
                }

                Err(KError::InvalidInput)
            }
        }
    }

    fn poll(&self, _file: &VfsFile) -> IoEvents {
        Pollable::poll(self)
    }

    fn register_poll(
        &self,
        _file: &VfsFile,
        context: &mut PollContext<'_>,
        events: IoEvents,
    ) -> Result<(), PollRegisterError> {
        Pollable::register(self, context, events)
    }
}

impl Pollable for EventDev {
    fn poll(&self) -> IoEvents {
        let mut events = IoEvents::empty();
        events.set(IoEvents::IN, self.inner.lock().has_event());
        events
    }

    fn register(
        &self,
        context: &mut PollContext<'_>,
        events: IoEvents,
    ) -> Result<(), PollRegisterError> {
        if events.contains(IoEvents::IN) {
            context.register(&self.poll_set)?;
            // Input devices do not expose a callback-based wake source yet,
            // so retain the existing prompt-repoll behavior for this waiter only.
            context.wake_by_ref();
        }
        Ok(())
    }
}

pub const INPUT_DEV_MAJOR: u32 = 13;
pub const INPUT_EVENT_MINOR_BASE: u32 = 64;

/// Real input-device metadata used to project the matching evdev sysfs node.
#[derive(Clone, Debug)]
pub struct InputSysfsDevice {
    pub index: usize,
    pub input_name: String,
    pub event_name: String,
    pub input_path: String,
    pub event_path: String,
    pub parent_path: String,
    pub parent_bus_path: String,
    pub parent_bus_link: String,
    pub name: String,
    pub physical_location: String,
    pub unique_id: String,
    pub bus_type: u16,
    pub vendor: u16,
    pub product: u16,
    pub version: u16,
    pub capabilities: Vec<(String, String)>,
}

fn bitset_sysfs_value(bytes: &[u8]) -> String {
    use core::fmt::Write as _;

    // Linux input sysfs prints unsigned-long words from high to low, separated
    // by spaces; AArch64 unsigned long is 64 bits.
    let word_count = bytes.len().div_ceil(size_of::<u64>());
    let word_at = |index: usize| {
        let start = index * size_of::<u64>();
        let end = (start + size_of::<u64>()).min(bytes.len());
        let mut raw = [0u8; size_of::<u64>()];
        if start < end {
            raw[..end - start].copy_from_slice(&bytes[start..end]);
        }
        u64::from_le_bytes(raw)
    };
    let Some(last) = (0..word_count).rev().find(|index| word_at(*index) != 0) else {
        return String::from("0\n");
    };

    let mut value = String::new();
    for index in (0..=last).rev() {
        if index == last {
            let _ = write!(&mut value, "{:x}", word_at(index));
        } else {
            let _ = write!(&mut value, " {:016x}", word_at(index));
        }
    }
    value.push('\n');
    value
}

fn input_capability_name(ty: EventType) -> Option<&'static str> {
    match ty {
        EventType::Key => Some("key"),
        EventType::Relative => Some("rel"),
        EventType::Absolute => Some("abs"),
        EventType::Misc => Some("msc"),
        EventType::Switch => Some("sw"),
        EventType::Led => Some("led"),
        EventType::Sound => Some("snd"),
        EventType::ForceFeedback => Some("ff"),
        EventType::Synchronization => None,
    }
}

fn input_sysfs_paths(
    location: DeviceLocation,
    index: usize,
) -> (String, String, String, String, String) {
    match location {
        DeviceLocation::Pci {
            segment,
            bus,
            device,
            function,
        } => {
            let bus_name = alloc::format!("pci{segment:04x}:{bus:02x}");
            let bdf = alloc::format!("{segment:04x}:{bus:02x}:{device:02x}.{function}");
            let parent = alloc::format!("/sys/devices/{bus_name}/{bdf}");
            let input = alloc::format!("{parent}/input/input{index}");
            let event = alloc::format!("{input}/event{index}");
            let bus_path = String::from("/sys/bus/pci");
            let bus_link = alloc::format!("/sys/bus/pci/devices/{bdf}");
            (parent, input, event, bus_path, bus_link)
        }
        DeviceLocation::Mmio { base, .. } => {
            let parent = alloc::format!("/sys/devices/platform/virtio-mmio@{base:x}");
            let input = alloc::format!("{parent}/input/input{index}");
            let event = alloc::format!("{input}/event{index}");
            let bus_path = String::from("/sys/bus/platform");
            let bus_link = alloc::format!("/sys/bus/platform/devices/virtio-mmio@{base:x}");
            (parent, input, event, bus_path, bus_link)
        }
        DeviceLocation::FirmwareNode { id } => {
            let parent = alloc::format!("/sys/devices/platform/firmware:{id}");
            let input = alloc::format!("{parent}/input/input{index}");
            let event = alloc::format!("{input}/event{index}");
            let bus_path = String::from("/sys/bus/platform");
            let bus_link = alloc::format!("/sys/bus/platform/devices/firmware:{id}");
            (parent, input, event, bus_path, bus_link)
        }
        DeviceLocation::PlatformStatic { id } => {
            let parent = alloc::format!("/sys/devices/platform/static:{id}");
            let input = alloc::format!("{parent}/input/input{index}");
            let event = alloc::format!("{input}/event{index}");
            let bus_path = String::from("/sys/bus/platform");
            let bus_link = alloc::format!("/sys/bus/platform/devices/static:{id}");
            (parent, input, event, bus_path, bus_link)
        }
        DeviceLocation::Bridge { domain } => {
            let parent = alloc::format!("/sys/devices/platform/pci-bridge:{domain}");
            let input = alloc::format!("{parent}/input/input{index}");
            let event = alloc::format!("{input}/event{index}");
            let bus_path = String::from("/sys/bus/platform");
            let bus_link = alloc::format!("/sys/bus/platform/devices/pci-bridge:{domain}");
            (parent, input, event, bus_path, bus_link)
        }
    }
}

/// Return an event-numbered snapshot of the registered devices and their
/// actual bus locations/capabilities for the kernel's sysfs projection.
pub fn input_sysfs_devices() -> Vec<InputSysfsDevice> {
    inputdev::input_devices()
        .into_iter()
        .enumerate()
        .map(|(index, device)| {
            let (parent_path, input_path, event_path, parent_bus_path, parent_bus_link) =
                input_sysfs_paths(device.location(), index);
            let mut event_bits = Bitmap::<{ EventType::COUNT as usize }>::new();
            event_bits.set(EventType::Synchronization as usize, true);
            let mut capabilities = Vec::new();

            for slot in 0..EventType::COUNT {
                let Some(ty) = EventType::from_repr(slot) else {
                    continue;
                };
                let mut bits = vec![0u8; ty.bits_count().div_ceil(8)];
                if device.get_event_bits(ty, &mut bits).unwrap_or(false) {
                    event_bits.set(slot as usize, true);
                    if let Some(file_name) = input_capability_name(ty) {
                        capabilities.push((file_name.into(), bitset_sysfs_value(&bits)));
                    }
                }
            }
            capabilities.push(("ev".into(), bitset_sysfs_value(event_bits.as_bytes())));
            let id = device.device_id();
            InputSysfsDevice {
                index,
                input_name: format!("input{index}"),
                event_name: format!("event{index}"),
                input_path,
                event_path,
                parent_path,
                parent_bus_path,
                parent_bus_link,
                name: device.name().into(),
                physical_location: device.physical_location().into(),
                unique_id: device.unique_id().into(),
                bus_type: id.bus_type,
                vendor: id.vendor,
                product: id.product,
                version: id.version,
                capabilities,
            }
        })
        .collect()
}

pub fn input_devices(fs: Arc<SimpleFs>) -> DirMapping {
    let mut inputs = DirMapping::new();
    let devices = inputdev::input_devices();
    for (input_id, device) in devices.into_iter().enumerate() {
        let event_dev = EventDev::new(device);
        event_dev.subscribe_removed();

        let minor = INPUT_EVENT_MINOR_BASE + input_id as u32;
        let dev =
            DeviceFile::new_character(fs.clone(), DeviceId::new(INPUT_DEV_MAJOR, minor), event_dev);
        add_device_entry(&mut inputs, format!("event{input_id}"), dev);
    }
    inputs
}

pub(crate) fn add_root_entries(root: &mut DirMapping, fs: Arc<SimpleFs>) {
    root.add(
        "input",
        SimpleDir::new_maker(fs.clone(), Arc::new(input_devices(fs.clone()))),
    );
}
