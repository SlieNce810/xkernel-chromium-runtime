#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Expose registered VirtIO input devices through repeatable evdev/sysfs views.

Run from the T490 x-kernel checkout. Event node names, minors, sysfs identity,
and capabilities are all derived from the registered input-device snapshot.
"""
from __future__ import annotations

from pathlib import Path

ROOT = Path.home() / "x-kernel"


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text(encoding="utf-8")
    if new in text:
        print(f"[skip] {label} already applied")
        return
    count = text.count(old)
    if count == 0:
        raise SystemExit(f"[FATAL] anchor not found for {label}: {path}")
    if count != 1:
        raise SystemExit(f"[FATAL] {label} anchor matched {count} times: {path}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"[ok] {label}")


def edit(path: Path, old: str, new: str, label: str) -> None:
    replace_once(path, old, new, label)


def insert_once(path: Path, anchor: str, insertion: str, marker: str, label: str) -> None:
    text = path.read_text(encoding="utf-8")
    if marker in text:
        print(f"[skip] {label} already applied")
        return
    replace_once(path, anchor, insertion + anchor, label)


def collapse_once(path: Path, repeated: str, single: str, label: str) -> None:
    text = path.read_text(encoding="utf-8")
    if single in text and repeated not in text:
        print(f"[skip] {label} already clean")
        return
    count = text.count(repeated)
    if count != 1:
        raise SystemExit(f"[FATAL] expected one repeated block for {label}, found {count}")
    path.write_text(text.replace(repeated, single, 1), encoding="utf-8")
    print(f"[ok] {label}")


# ---------------------------------------------------------------------------
# kclass: derive physical input paths from the driver's actual bus location and
# expose Arc identity so repeated class notifications can be deduplicated
# without collapsing distinct devices that happen to share a numeric ID.
generic = ROOT / "drivers/contracts/kclass/src/generic.rs"
edit(
    generic,
    """impl ClassDeviceMetadata {
    pub(crate) const fn empty() -> Self {
        Self {
            input_identity: None,
        }
    }

    pub(crate) fn input(physical_location: String, unique_id: String) -> Self {
        Self {
            input_identity: Some(InputIdentity {
                physical_location,
                unique_id,
            }),
        }
    }
}
""",
    """impl ClassDeviceMetadata {
    pub(crate) const fn empty() -> Self {
        Self {
            input_identity: None,
        }
    }

    pub(crate) fn input(physical_location: String, unique_id: String) -> Self {
        Self {
            input_identity: Some(InputIdentity {
                physical_location,
                unique_id,
            }),
        }
    }

    fn set_parent_location(&mut self, location: DeviceLocation) {
        let Some(identity) = self.input_identity.as_mut() else {
            return;
        };
        identity.physical_location = match location {
            DeviceLocation::Pci {
                segment,
                bus,
                device,
                function,
            } => alloc::format!(
                "pci{segment:04x}:{bus:02x}:{device:02x}.{function}/input0"
            ),
            DeviceLocation::Mmio { base, .. } => alloc::format!("virtio-mmio@{base:x}/input0"),
            DeviceLocation::FirmwareNode { id } => alloc::format!("firmware:{id}/input0"),
            DeviceLocation::PlatformStatic { id } => alloc::format!("platform:{id}/input0"),
            DeviceLocation::Bridge { domain } => alloc::format!("pci-bridge:{domain}/input0"),
        };
        // VirtIO does not report a per-device serial number. Do not publish the
        // driver's old generic "virtio" marker as if it were unique hardware.
        if identity.unique_id == "virtio" {
            identity.unique_id.clear();
        }
    }
}
""",
    "input physical identity from parent bus location",
)
edit(
    generic,
    """        parent.driver_id().ok_or(DriverError::BadState)?;
        Ok(Self {
            inner: Arc::new(ClassDeviceInner {
                parent,
                runtime: inner,
                name,
                device_kind,
                irq,
                metadata,
            }),
        })
""",
    """        parent.driver_id().ok_or(DriverError::BadState)?;
        let mut metadata = metadata;
        metadata.set_parent_location(parent.location());
        Ok(Self {
            inner: Arc::new(ClassDeviceInner {
                parent,
                runtime: inner,
                name,
                device_kind,
                irq,
                metadata,
            }),
        })
""",
    "populate input metadata from DeviceLocation",
)
edit(
    generic,
    """    pub fn id(&self) -> DeviceId {
        self.inner.parent.id()
    }

    /// Stable runtime device name.
""",
    """    pub fn id(&self) -> DeviceId {
        self.inner.parent.id()
    }

    /// Return whether two handles reference the same published class object.
    pub fn is_same_device(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.inner, &other.inner)
    }

    /// Stable runtime device name.
""",
    "ClassDevice object identity helper",
)


# ---------------------------------------------------------------------------
# inputdev: snapshot devices without consuming the registry and deduplicate
# repeated availability notifications by object identity.
inputdev = ROOT / "io/inputdev/src/lib.rs"
edit(
    inputdev,
    """    if devices.iter().any(|device| device.id() == handle.id()) {
        return;
    }
""",
    """    if devices.iter().any(|device| device.is_same_device(&handle)) {
        return;
    }
""",
    "deduplicate repeated notification for the same input object",
)
edit(
    inputdev,
    """/// Drain all registered input device handles out of the input subsystem.
pub fn input_drain_devices() -> Vec<ClassDevice<InputDeviceImpl>> {
    INPUT_DEVICES.lock().drain(..).collect()
}
""",
    """/// Return a repeatable snapshot of all currently registered input devices.
pub fn input_devices() -> Vec<ClassDevice<InputDeviceImpl>> {
    INPUT_DEVICES.lock().clone()
}

/// Compatibility wrapper retained for older callers. Input enumeration is a
/// snapshot now; reading `/dev/input` must not consume the registration list.
#[deprecated(note = "use input_devices(); input enumeration is non-consuming")]
pub fn input_drain_devices() -> Vec<ClassDevice<InputDeviceImpl>> {
    input_devices()
}
""",
    "non-consuming input-device snapshot",
)


# ---------------------------------------------------------------------------
# devfs: expose every registered device as /dev/input/eventN with Linux evdev
# numbering, and return the same registration snapshot as sysfs metadata.
event = ROOT / "fs/filesystems/devfs/src/nodes/event.rs"
edit(
    event,
    """use alloc::{format, string::ToString, sync::Arc, vec};
""",
    """use alloc::{
    format,
    string::{String, ToString},
    sync::Arc,
    vec,
    vec::Vec,
};
""",
    "input sysfs metadata imports",
)
edit(
    event,
    """use kdevice::subscribe_device_removed;
""",
    """use kdevice::{DeviceLocation, subscribe_device_removed};
""",
    "bus location metadata import",
)
insert_sysfs = """pub const INPUT_DEV_MAJOR: u32 = 13;
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
        return String::from("0\\n");
    };

    let mut value = String::new();
    for index in (0..=last).rev() {
        if index == last {
            let _ = write!(&mut value, "{:x}", word_at(index));
        } else {
            let _ = write!(&mut value, " {:016x}", word_at(index));
        }
    }
    value.push('\\n');
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

fn input_sysfs_paths(location: DeviceLocation, index: usize) -> (String, String, String, String, String) {
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
                        capabilities.push((
                            file_name.into(),
                            bitset_sysfs_value(&bits),
                        ));
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

"""
insert_once(
    event,
    "pub fn input_devices(fs: Arc<SimpleFs>) -> DirMapping {\n",
    insert_sysfs,
    "pub struct InputSysfsDevice",
    "input sysfs metadata snapshot",
)
edit(
    event,
    """pub fn input_devices(fs: Arc<SimpleFs>) -> DirMapping {
    let mut inputs = DirMapping::new();
    let mut input_id = 0;
    let input_devices = inputdev::input_drain_devices();
    let mut keys = [0; 0x300usize.div_ceil(8)];
    for (i, device) in input_devices.into_iter().enumerate() {
        assert!(device.get_event_bits(EventType::Key, &mut keys).unwrap());

        let event_dev = Arc::new(EventDev::new(device));
        event_dev.subscribe_removed();

        let dev = DeviceFile::new_character(fs.clone(), DeviceId::new(13, (i + 1) as _), event_dev);

        const BTN_MOUSE: usize = 0x110;
        if keys[BTN_MOUSE / 8] & (1 << (BTN_MOUSE % 8)) != 0 {
            // Mouse
            add_device_entry(&mut inputs, "mice", dev);
        } else {
            add_device_entry(&mut inputs, format!("event{input_id}"), dev);
            input_id += 1;
        }
    }
    inputs
}
""",
    """pub fn input_devices(fs: Arc<SimpleFs>) -> DirMapping {
    let mut inputs = DirMapping::new();
    for (input_id, device) in inputdev::input_devices().into_iter().enumerate() {
        let event_dev = Arc::new(EventDev::new(device));
        event_dev.subscribe_removed();

        let minor = INPUT_EVENT_MINOR_BASE + input_id as u32;
        let dev = DeviceFile::new_character(
            fs.clone(),
            DeviceId::new(INPUT_DEV_MAJOR, minor),
            event_dev,
        );
        add_device_entry(&mut inputs, format!("event{input_id}"), dev);
    }
    inputs
}
""",
    "standard eventN device names and Linux evdev device numbers",
)

devfs_lib = ROOT / "fs/filesystems/devfs/src/lib.rs"
edit(
    devfs_lib,
    """pub use nodes::dri::{CARD0_DEV_MAJOR, CARD0_DEV_MINOR, drm_available};
""",
    """pub use nodes::dri::{CARD0_DEV_MAJOR, CARD0_DEV_MINOR, drm_available};
pub use nodes::event::{
    INPUT_DEV_MAJOR, INPUT_EVENT_MINOR_BASE, InputSysfsDevice, input_sysfs_devices,
};
""",
    "devfs input sysfs metadata exports",
)


# ---------------------------------------------------------------------------
# fs_boot: project the same real input-device snapshot into /sys, including
# class links, dev numbers, IDs, event capabilities, and their bus locations.
boot = ROOT / "fs/boot/src/lib.rs"
edit(
    boot,
    """        self.create_sys_drm_entries()
            .expect("Failed to create sys DRM entries");
""",
    """        self.create_sys_drm_entries()
            .expect("Failed to create sys DRM entries");
        self.create_sys_input_entries()
            .expect("Failed to create sys input entries");
""",
    "boot-time input sysfs projection call",
)
input_method = '''    /// Project evdev devices from the input subsystem's registered device snapshot.
    fn create_sys_input_entries(&self) -> kvfs::VfsResult<()> {
        let devices = devfs::input_sysfs_devices();
        if devices.is_empty() {
            return Ok(());
        }

        self.ensure_directory_path("/sys/class/input")?;
        self.ensure_directory_path("/sys/dev/char")?;

        for input in devices {
            let event_minor = devfs::INPUT_EVENT_MINOR_BASE + input.index as u32;
            let parent = &input.parent_path;
            let input_path = &input.input_path;
            let event_path = &input.event_path;
            let input_class = format!("/sys/class/input/{}", input.input_name);
            let event_class = format!("/sys/class/input/{}", input.event_name);
            let parent_uevent = format!(
                "SUBSYSTEM={}\\n",
                if input.parent_bus_path.ends_with("/pci") { "pci" } else { "platform" },
            );

            self.ensure_directory_path(parent)?;
            self.ensure_directory_path(&format!("{parent}/input"))?;
            self.ensure_directory_path(&format!("{input_path}/id"))?;
            self.ensure_directory_path(&format!("{input_path}/capabilities"))?;
            self.ensure_directory_path(event_path)?;
            self.ensure_directory_path(&format!("/sys/bus/{}/devices", if input.parent_bus_path.ends_with("/pci") { "pci" } else { "platform" }))?;

            self.create_sys_file(&format!("{parent}/uevent"), &parent_uevent, 0o444)?;
            self.create_sys_file(&format!("{input_path}/name"), &format!("{}\\n", input.name), 0o444)?;
            self.create_sys_file(&format!("{input_path}/phys"), &format!("{}\\n", input.physical_location), 0o444)?;
            self.create_sys_file(&format!("{input_path}/uniq"), &format!("{}\\n", input.unique_id), 0o444)?;
            self.create_sys_file(
                &format!("{input_path}/uevent"),
                &format!(
                    "PRODUCT={:04x}/{:04x}/{:04x}/{:04x}\\nNAME=\\\"{}\\\"\\nPHYS=\\\"{}\\\"\\nUNIQ=\\\"{}\\\"\\nSUBSYSTEM=input\\n",
                    input.bus_type, input.vendor, input.product, input.version,
                    input.name, input.physical_location, input.unique_id,
                ),
                0o444,
            )?;
            for (field, value) in [
                ("bustype", input.bus_type),
                ("vendor", input.vendor),
                ("product", input.product),
                ("version", input.version),
            ] {
                self.create_sys_file(
                    &format!("{input_path}/id/{field}"),
                    &format!("{value:04x}\\n"),
                    0o444,
                )?;
            }
            for (name, value) in &input.capabilities {
                self.create_sys_file(
                    &format!("{input_path}/capabilities/{name}"),
                    value,
                    0o444,
                )?;
            }
            self.create_sys_file(&format!("{input_path}/properties"), "0\\n", 0o444)?;
            self.create_sys_file(
                &format!("{event_path}/dev"),
                &format!("{}:{event_minor}\\n", devfs::INPUT_DEV_MAJOR),
                0o444,
            )?;
            self.create_sys_file(
                &format!("{event_path}/uevent"),
                &format!(
                    "MAJOR={}\\nMINOR={event_minor}\\nDEVNAME=input/{}\\nSUBSYSTEM=input\\n",
                    devfs::INPUT_DEV_MAJOR, input.event_name,
                ),
                0o444,
            )?;

            self.create_sys_symlink(&input_class, input_path)?;
            self.create_sys_symlink(&event_class, event_path)?;
            self.create_sys_symlink(&format!("{input_path}/subsystem"), "/sys/class/input")?;
            self.create_sys_symlink(&format!("{event_path}/subsystem"), "/sys/class/input")?;
            self.create_sys_symlink(&format!("{event_path}/device"), input_path)?;
            self.create_sys_symlink(&format!("{parent}/subsystem"), &input.parent_bus_path)?;
            self.create_sys_symlink(&input.parent_bus_link, parent)?;
            self.create_sys_symlink(
                &format!("/sys/dev/char/{}:{event_minor}", devfs::INPUT_DEV_MAJOR),
                event_path,
            )?;
            info!(
                "sysfs: projected {} ({},{}:{event_minor}) at {}",
                input.event_name, input.name, devfs::INPUT_DEV_MAJOR, input_path,
            );
        }
        Ok(())
    }

'''
insert_once(
    boot,
    "    /// Project the platform's actual CPU map for userspace CPU discovery.\n",
    input_method,
    "fn create_sys_input_entries(&self)",
    "kernel-side input sysfs projection",
)

# Upgrade an already-applied draft in place, and keep this script safe to rerun.
edit(
    event,
    """fn bitset_sysfs_value(bytes: &[u8]) -> String {
    use core::fmt::Write as _;

    let Some(last) = bytes.iter().rposition(|byte| *byte != 0) else {
        return String::from("0\\n");
    };
    let mut value = String::new();
    for byte in bytes[..=last].iter().rev() {
        let _ = write!(&mut value, "{byte:02x}");
    }
    value.push('\\n');
    value
}
""",
    """fn bitset_sysfs_value(bytes: &[u8]) -> String {
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
        return String::from("0\\n");
    };

    let mut value = String::new();
    for index in (0..=last).rev() {
        if index == last {
            let _ = write!(&mut value, "{:x}", word_at(index));
        } else {
            let _ = write!(&mut value, " {:016x}", word_at(index));
        }
    }
    value.push('\\n');
    value
}
""",
    "Linux input bitmap word formatting",
)

edit(
    boot,
    """            self.create_sys_file(
                &format!("{input_path}/uevent"),
                &format!(
                    "PRODUCT={:04x}/{:04x}/{:04x}/{:04x}\\nNAME=\\\"{}\\\"\\nPHYS=\\\"{}\\\"\\nUNIQ=\\\"{}\\\"\\nSUBSYSTEM=input\\n",
                    input.bus_type, input.vendor, input.product, input.version,
                    input.name, input.physical_location, input.unique_id,
                ),
                0o444,
            )?;
""",
    """            let mut input_uevent = format!(
                "PRODUCT={:04x}/{:04x}/{:04x}/{:04x}\\nNAME=\\\"{}\\\"\\nPHYS=\\\"{}\\\"\\nUNIQ=\\\"{}\\\"\\nPROP=0\\n",
                input.bus_type, input.vendor, input.product, input.version,
                input.name, input.physical_location, input.unique_id,
            );
            for (name, value) in &input.capabilities {
                let property = match name.as_str() {
                    "ev" => "EV",
                    "key" => "KEY",
                    "rel" => "REL",
                    "abs" => "ABS",
                    "msc" => "MSC",
                    "sw" => "SW",
                    "led" => "LED",
                    "snd" => "SND",
                    "ff" => "FF",
                    _ => continue,
                };
                input_uevent.push_str(property);
                input_uevent.push('=');
                input_uevent.push_str(value);
            }
            self.create_sys_file(&format!("{input_path}/uevent"), &input_uevent, 0o444)?;
""",
    "input uevent exports the real capability masks",
)

edit(
    boot,
    """                    "MAJOR={}\\nMINOR={event_minor}\\nDEVNAME=input/{}\\nSUBSYSTEM=input\\n",
""",
    """                    "MAJOR={}\\nMINOR={event_minor}\\nDEVNAME=input/{}\\n",
""",
    "event uevent matches evdev sysfs form",
)

edit(
    boot,
    """        self.ensure_directory_path("/sys/class/input")?;
        self.ensure_directory_path("/sys/dev/char")?;
""",
    """        self.ensure_directory_path("/sys/class/input")?;
        self.ensure_directory_path("/sys/dev/char")?;
        self.ensure_directory_path("/sys/subsystem")?;
        self.ensure_directory_path("/sys/bus/input/devices")?;
        self.ensure_directory_path("/sys/bus/input/drivers")?;
        self.create_sys_symlink("/sys/subsystem/input", "/sys/bus/input")?;
""",
    "kernel input bus and subsystem roots",
)

edit(
    boot,
    """            self.create_sys_symlink(&format!("{event_path}/device"), input_path)?;
            self.create_sys_symlink(&format!("{parent}/subsystem"), &input.parent_bus_path)?;
""",
    """            self.create_sys_symlink(&format!("{event_path}/device"), input_path)?;
            self.create_sys_symlink(&format!("{input_path}/device"), parent)?;
            self.create_sys_symlink(
                &format!("/sys/bus/input/devices/{}", input.input_name),
                input_path,
            )?;
            self.create_sys_symlink(&format!("{parent}/subsystem"), &input.parent_bus_path)?;
""",
    "input parent and bus device links",
)

edit(
    boot,
    """            self.create_sys_symlink(&input_class, input_path)?;
            self.ensure_directory_path(&event_class)?;
            self.create_sys_file(
                &format!("{event_class}/dev"),
                &format!("{}:{event_minor}\\n", devfs::INPUT_DEV_MAJOR),
                0o444,
            )?;
            self.create_sys_file(
                &format!("{event_class}/uevent"),
                &format!(
                    "MAJOR={}\\nMINOR={event_minor}\\nDEVNAME=input/{}\\n",
                    devfs::INPUT_DEV_MAJOR, input.event_name,
                ),
                0o444,
            )?;
            self.create_sys_symlink(&format!("{event_class}/device"), input_path)?;
            self.create_sys_symlink(&format!("{event_class}/subsystem"), "/sys/class/input")?;
            self.create_sys_symlink(&format!("{input_path}/subsystem"), "/sys/class/input")?;
""",
    """            self.create_sys_symlink(&input_class, input_path)?;
            self.create_sys_symlink(&event_class, event_path)?;
            self.create_sys_symlink(&format!("{input_path}/subsystem"), "/sys/class/input")?;
""",
    "restore the kernel input class event symlink",
)

edit(
    boot,
    """            self.create_sys_symlink(&input.parent_bus_link, parent)?;
            self.create_sys_symlink(
                &format!("/sys/dev/char/{}:{event_minor}", devfs::INPUT_DEV_MAJOR),
""",
    """            self.create_sys_symlink(&input.parent_bus_link, parent)?;
            // Let libudev's input-subsystem bus walk see the event node as well
            // as the parent input device, matching the class entry above.
            self.create_sys_symlink(
                &format!("/sys/bus/input/devices/{}", input.event_name),
                event_path,
            )?;
            self.create_sys_symlink(
                &format!("/sys/dev/char/{}:{event_minor}", devfs::INPUT_DEV_MAJOR),
""",
    "input event nodes visible to the input subsystem bus walk",
)

edit(
    boot,
    """            let input_class = format!("/sys/class/input/{}", input.input_name);
            let event_class = format!("/sys/class/input/{}", input.event_name);
""",
    """            let input_class = format!("/sys/class/input/{}", input.input_name);
            let event_class = format!("/sys/class/input/{}", input.event_name);
            let input_relative = input_path.trim_start_matches("/sys/");
            let event_relative = event_path.trim_start_matches("/sys/");
            let input_class_target = format!("../../{input_relative}");
            let event_class_target = format!("../../{event_relative}");
            let input_bus_target = format!("../../../{input_relative}");
            let event_bus_target = format!("../../../{event_relative}");
            let event_dev_target = format!("../../{event_relative}");
            let parent_bus_target = format!(
                "../../../{}",
                parent.trim_start_matches("/sys/"),
            );
            let parent_subsystem_target = format!(
                "../../../bus/{}",
                input.parent_bus_path.trim_start_matches("/sys/bus/"),
            );
""",
    "relative sysfs target paths from actual device locations",
)

edit(
    boot,
    """            self.create_sys_symlink(&input_class, input_path)?;
            self.create_sys_symlink(&event_class, event_path)?;
""",
    """            self.create_sys_symlink(&input_class, &input_class_target)?;
            self.create_sys_symlink(&event_class, &event_class_target)?;
""",
    "class symlinks use Linux relative target form",
)

edit(
    boot,
    """            self.create_sys_symlink(&format!("{event_path}/device"), input_path)?;
            self.create_sys_symlink(&format!("{input_path}/device"), parent)?;
""",
    """            self.create_sys_symlink(&format!("{event_path}/device"), "..")?;
            self.create_sys_symlink(&format!("{input_path}/device"), "../..")?;
""",
    "input device parent links use relative targets",
)

edit(
    boot,
    """            self.create_sys_symlink(&format!("{parent}/subsystem"), &input.parent_bus_path)?;
            self.create_sys_symlink(&input.parent_bus_link, parent)?;
""",
    """            self.create_sys_symlink(&format!("{parent}/subsystem"), &parent_subsystem_target)?;
            self.create_sys_symlink(&input.parent_bus_link, &parent_bus_target)?;
""",
    "bus links use Linux relative target form",
)

edit(
    boot,
    """            self.create_sys_symlink(
                &format!("/sys/bus/input/devices/{}", input.event_name),
                event_path,
            )?;
            self.create_sys_symlink(
                &format!("/sys/dev/char/{}:{event_minor}", devfs::INPUT_DEV_MAJOR),
                event_path,
            )?;
""",
    """            self.create_sys_symlink(
                &format!("/sys/bus/input/devices/{}", input.event_name),
                &event_bus_target,
            )?;
            self.create_sys_symlink(
                &format!("/sys/dev/char/{}:{event_minor}", devfs::INPUT_DEV_MAJOR),
                &event_dev_target,
            )?;
""",
    "input event bus/devchar links use relative targets",
)

edit(
    boot,
    """        self.create_sys_symlink("/sys/subsystem/input", "/sys/bus/input")?;
""",
    """        self.create_sys_symlink("/sys/subsystem/input", "../bus/input")?;
""",
    "subsystem input link uses relative target",
)

edit(
    boot,
    """            self.create_sys_symlink(
                &format!("/sys/bus/input/devices/{}", input.input_name),
                input_path,
            )?;
""",
    """            self.create_sys_symlink(
                &format!("/sys/bus/input/devices/{}", input.input_name),
                &input_bus_target,
            )?;
""",
    "input bus parent link uses relative target",
)

collapse_once(
    boot,
    """        self.create_sys_drm_entries()
            .expect("Failed to create sys DRM entries");
        self.create_sys_input_entries()
            .expect("Failed to create sys input entries");
        self.create_sys_input_entries()
            .expect("Failed to create sys input entries");
""",
    """        self.create_sys_drm_entries()
            .expect("Failed to create sys DRM entries");
        self.create_sys_input_entries()
            .expect("Failed to create sys input entries");
""",
    "duplicate boot-time input projection call",
)

collapse_once(
    devfs_lib,
    """pub use nodes::event::{
    INPUT_DEV_MAJOR, INPUT_EVENT_MINOR_BASE, InputSysfsDevice, input_sysfs_devices,
};
pub use nodes::event::{
    INPUT_DEV_MAJOR, INPUT_EVENT_MINOR_BASE, InputSysfsDevice, input_sysfs_devices,
};
""",
    """pub use nodes::event::{
    INPUT_DEV_MAJOR, INPUT_EVENT_MINOR_BASE, InputSysfsDevice, input_sysfs_devices,
};
""",
    "duplicate devfs input sysfs re-export",
)

print("[done] G6 input snapshot, evdev eventN/dev_t, and kernel sysfs projection are patched")
print("Next: inspect diff, make build, then run the evdev/libudev/Weston input validation round")
