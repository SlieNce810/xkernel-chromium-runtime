#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Make evdev sysfs uevent writes publish real kernel KOBJECT_UEVENT packets."""
from __future__ import annotations

from pathlib import Path

ROOT = Path.home() / "x-kernel"
CARGO = ROOT / "fs/boot/Cargo.toml"
BOOT = ROOT / "fs/boot/src/lib.rs"
MODULE = ROOT / "fs/boot/src/input_uevent.rs"


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text(encoding="utf-8")
    if new in text:
        print(f"[skip] {label} already applied")
        return
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"[FATAL] expected one anchor for {label} in {path}, found {count}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"[ok] {label}")


replace_once(
    CARGO,
    "kcpu_id_map.workspace = true\n",
    "kcpu_id_map.workspace = true\nknet.workspace = true\n",
    "fs_boot netlink dependency for input uevents",
)

replace_once(
    BOOT,
    "extern crate alloc;\n",
    "extern crate alloc;\n\nmod input_uevent;\n",
    "input sysfs command-file module",
)

module_source = r'''// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

//! Writable input sysfs event attributes backed by kernel uevent multicast.

use alloc::{format, string::String, sync::Arc, vec::Vec};

use kvfs::{
    CommandFile, DirMapping, NodePermission, NodeType, SimpleDir, SimpleFile,
    SimpleFileOperation, SimpleFs, SuperBlock, SuperBlockFlags,
};

const SYSFS_MAGIC: u32 = 0x6265_6572;

fn readonly_file(fs: Arc<SimpleFs>, contents: Vec<u8>) -> Arc<SimpleFile> {
    SimpleFile::new_regular_with_permission(
        fs,
        NodePermission::from_bits_truncate(0o444),
        move || Ok(contents.clone()),
    )
}

fn symlink_file(fs: Arc<SimpleFs>, target: String) -> Arc<SimpleFile> {
    SimpleFile::new(fs, NodeType::Symlink, move || Ok(target.clone().into_bytes()))
}

fn input_capability_property(name: &str) -> Option<&'static str> {
    match name {
        "ev" => Some("EV"),
        "key" => Some("KEY"),
        "rel" => Some("REL"),
        "abs" => Some("ABS"),
        "msc" => Some("MSC"),
        "sw" => Some("SW"),
        "led" => Some("LED"),
        "snd" => Some("SND"),
        "ff" => Some("FF"),
        _ => None,
    }
}

fn uevent_contents(input: &devfs::InputSysfsDevice, minor: u32) -> Vec<u8> {
    let mut contents = format!(
        "MAJOR={}\nMINOR={minor}\nDEVNAME=input/{}\nPRODUCT={:04x}/{:04x}/{:04x}/{:04x}\nNAME=\"{}\"\nPHYS=\"{}\"\nUNIQ=\"{}\"\nPROP=0\n",
        devfs::INPUT_DEV_MAJOR,
        input.event_name,
        input.bus_type,
        input.vendor,
        input.product,
        input.version,
        input.name,
        input.physical_location,
        input.unique_id,
    );
    for (name, value) in &input.capabilities {
        let Some(property) = input_capability_property(name) else {
            continue;
        };
        contents.push_str(property);
        contents.push('=');
        contents.push_str(value.trim());
        contents.push('\n');
    }
    contents.into_bytes()
}

fn publish_input_uevent(
    input: &devfs::InputSysfsDevice,
    minor: u32,
    action: &str,
) {
    let device_path = input
        .event_path
        .strip_prefix("/sys")
        .unwrap_or(input.event_path.as_str());
    let mut payload = Vec::new();
    payload.extend_from_slice(
        format!(
            "{action}@{device_path}\0ACTION={action}\0DEVPATH={device_path}\0SUBSYSTEM=input\0MAJOR={}\0MINOR={minor}\0DEVNAME=input/{}\0",
            devfs::INPUT_DEV_MAJOR,
            input.event_name,
        )
        .as_bytes(),
    );
    payload.extend_from_slice(
        format!(
            "PRODUCT={:04x}/{:04x}/{:04x}/{:04x}\0NAME=\"{}\"\0PHYS=\"{}\"\0UNIQ=\"{}\"\0PROP=0\0",
            input.bus_type,
            input.vendor,
            input.product,
            input.version,
            input.name,
            input.physical_location,
            input.unique_id,
        )
        .as_bytes(),
    );
    for (name, value) in &input.capabilities {
        let Some(property) = input_capability_property(name) else {
            continue;
        };
        payload.extend_from_slice(format!("{property}={}\0", value.trim()).as_bytes());
    }
    knet::netlink::publish_kobject_uevent(1, &payload);
}

/// Build one event class directory whose `uevent` writes notify real eudev
/// listeners. The device path, dev_t, IDs, and capability masks come from the
/// same registered kernel input device as the `/dev/input/eventN` node.
pub(crate) fn new_event_sysfs(
    input: devfs::InputSysfsDevice,
    minor: u32,
) -> Arc<SuperBlock> {
    let read_content = uevent_contents(&input, minor);
    let command_input = input.clone();
    let command = CommandFile::new(move |operation| match operation {
        SimpleFileOperation::Read => Ok(Some(read_content.clone())),
        SimpleFileOperation::Write { data, .. } => {
            let action = core::str::from_utf8(data)
                .map_err(|_| kvfs::VfsError::InvalidInput)?
                .trim_matches(|ch: char| ch == '\0' || ch.is_whitespace());
            if !matches!(action, "add" | "change" | "remove") {
                return Err(kvfs::VfsError::InvalidInput);
            }
            log::warn!(
                "input sysfs uevent write: action={} devnode=/dev/input/{} dev=13:{}",
                action,
                command_input.event_name,
                minor,
            );
            publish_input_uevent(&command_input, minor, action);
            Ok(None)
        }
    });

    SimpleFs::new_with_superblock_flags(
        &memfs::SYSFS_TYPE,
        SYSFS_MAGIC,
        SuperBlockFlags::empty(),
        move |fs| {
            let mut entries = DirMapping::new();
            entries.add(
                "dev",
                readonly_file(
                    fs.clone(),
                    format!("{}:{minor}\n", devfs::INPUT_DEV_MAJOR).into_bytes(),
                ),
            );
            entries.add(
                "uevent",
                SimpleFile::new_regular_with_permission(
                    fs.clone(),
                    NodePermission::from_bits_truncate(0o644),
                    command,
                ),
            );
            entries.add(
                "device",
                symlink_file(fs.clone(), input.input_path.clone()),
            );
            entries.add(
                "subsystem",
                symlink_file(fs.clone(), String::from("/sys/class/input")),
            );
            SimpleDir::new_maker(fs.clone(), Arc::new(entries))
        },
    )
}
'''

if MODULE.exists():
    if MODULE.read_text(encoding="utf-8") != module_source:
        if "pub(crate) fn new_event_sysfs(" not in MODULE.read_text(encoding="utf-8"):
            raise SystemExit(f"[FATAL] {MODULE} exists with different contents; inspect before replacing")
        MODULE.write_text(module_source, encoding="utf-8")
        print(f"[ok] updated {MODULE}")
    else:
        print(f"[skip] {MODULE} already present")
else:
    MODULE.write_text(module_source, encoding="utf-8")
    print(f"[ok] created {MODULE}")

text = BOOT.read_text(encoding="utf-8")
start_marker = "    /// Project input devices from the registered kernel device snapshot.\n"
if start_marker not in text:
    start_marker = "    /// Project evdev devices from the input subsystem's registered device snapshot.\n"
end_marker = "    /// Project the platform's actual CPU map for userspace CPU discovery.\n"
if text.count(start_marker) != 1 or text.count(end_marker) != 1:
    raise SystemExit("[FATAL] could not locate the complete create_sys_input_entries method")
start = text.index(start_marker)
end = text.index(end_marker, start)
new_method = r'''    /// Project input devices from the registered kernel device snapshot.
    fn create_sys_input_entries(&self) -> kvfs::VfsResult<()> {
        let devices = devfs::input_sysfs_devices();
        if devices.is_empty() {
            return Ok(());
        }

        self.ensure_directory_path("/sys/class/input")?;
        self.ensure_directory_path("/sys/dev/char")?;
        self.ensure_directory_path("/sys/subsystem")?;
        self.ensure_directory_path("/sys/bus/input/devices")?;
        self.ensure_directory_path("/sys/bus/input/drivers")?;
        self.create_sys_symlink("/sys/subsystem/input", "../bus/input")?;

        for input in devices {
            let event_minor = devfs::INPUT_EVENT_MINOR_BASE + input.index as u32;
            let parent = &input.parent_path;
            let input_path = &input.input_path;
            let event_path = &input.event_path;
            let input_class = format!("/sys/class/input/{}", input.input_name);
            let event_class = format!("/sys/class/input/{}", input.event_name);
            let input_relative = input_path.trim_start_matches("/sys/");
            let event_relative = event_path.trim_start_matches("/sys/");
            let input_class_target = format!("../../{input_relative}");
            let input_bus_target = format!("../../../{input_relative}");
            let event_bus_target = format!("../../../{event_relative}");
            let event_dev_target = format!("../../class/input/{}", input.event_name);
            let parent_bus_target = format!("../../../{}", parent.trim_start_matches("/sys/"));
            let parent_subsystem_target = format!(
                "../../../bus/{}",
                input.parent_bus_path.trim_start_matches("/sys/bus/"),
            );

            self.ensure_directory_path(parent)?;
            self.ensure_directory_path(&format!("{parent}/input"))?;
            self.ensure_directory_path(&format!("{input_path}/id"))?;
            self.ensure_directory_path(&format!("{input_path}/capabilities"))?;
            self.ensure_directory_path(event_path)?;
            self.ensure_directory_path(&event_class)?;
            self.ensure_directory_path(&format!("/sys/bus/{}/devices", if input.parent_bus_path.ends_with("/pci") { "pci" } else { "platform" }))?;

            let parent_uevent = format!(
                "SUBSYSTEM={}\n",
                if input.parent_bus_path.ends_with("/pci") { "pci" } else { "platform" },
            );
            self.create_sys_file(&format!("{parent}/uevent"), &parent_uevent, 0o444)?;
            self.create_sys_file(&format!("{input_path}/name"), &format!("{}\n", input.name), 0o444)?;
            self.create_sys_file(&format!("{input_path}/phys"), &format!("{}\n", input.physical_location), 0o444)?;
            self.create_sys_file(&format!("{input_path}/uniq"), &format!("{}\n", input.unique_id), 0o444)?;
            self.create_sys_file(
                &format!("{input_path}/uevent"),
                &format!(
                    "PRODUCT={:04x}/{:04x}/{:04x}/{:04x}\nNAME=\"{}\"\nPHYS=\"{}\"\nUNIQ=\"{}\"\nPROP=0\n",
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
                    &format!("{value:04x}\n"),
                    0o444,
                )?;
            }
            for (name, value) in &input.capabilities {
                self.create_sys_file(&format!("{input_path}/capabilities/{name}"), value, 0o444)?;
            }
            self.create_sys_file(&format!("{input_path}/properties"), "0\n", 0o444)?;

            self.create_sys_file(
                &format!("{event_path}/dev"),
                &format!("{}:{event_minor}\n", devfs::INPUT_DEV_MAJOR),
                0o444,
            )?;
            self.create_sys_file(
                &format!("{event_path}/uevent"),
                &format!(
                    "MAJOR={}\nMINOR={event_minor}\nDEVNAME=input/{}\n",
                    devfs::INPUT_DEV_MAJOR, input.event_name,
                ),
                0o444,
            )?;
            self.create_sys_file(
                &format!("{event_class}/dev"),
                &format!("{}:{event_minor}\n", devfs::INPUT_DEV_MAJOR),
                0o444,
            )?;
            self.create_sys_file(
                &format!("{event_class}/uevent"),
                &format!(
                    "MAJOR={}\nMINOR={event_minor}\nDEVNAME=input/{}\n",
                    devfs::INPUT_DEV_MAJOR, input.event_name,
                ),
                0o444,
            )?;

            self.create_sys_symlink(&input_class, &input_class_target)?;
            self.create_sys_symlink(&format!("{event_class}/device"), input_path)?;
            self.create_sys_symlink(&format!("{event_class}/subsystem"), "/sys/class/input")?;
            self.create_sys_symlink(&format!("{input_path}/device"), "../..")?;
            self.create_sys_symlink(&format!("{input_path}/subsystem"), "/sys/class/input")?;
            self.create_sys_symlink(&format!("{parent}/subsystem"), &parent_subsystem_target)?;
            self.create_sys_symlink(&input.parent_bus_link, &parent_bus_target)?;
            self.create_sys_symlink(
                &format!("/sys/bus/input/devices/{}", input.input_name),
                &input_bus_target,
            )?;
            self.create_sys_symlink(
                &format!("/sys/bus/input/devices/{}", input.event_name),
                &event_bus_target,
            )?;
            self.create_sys_symlink(
                &format!("/sys/dev/char/{}:{event_minor}", devfs::INPUT_DEV_MAJOR),
                &event_dev_target,
            )?;

            self.mount_sysfs_input_event(&input, event_minor, event_path)?;
            info!(
                "sysfs: projected {} ({},{}:{event_minor}) at {}",
                input.event_name, input.name, devfs::INPUT_DEV_MAJOR, input_path,
            );
        }
        Ok(())
    }

    fn mount_sysfs_input_event(
        &self,
        input: &devfs::InputSysfsDevice,
        event_minor: u32,
        mountpoint: &str,
    ) -> kvfs::VfsResult<()> {
        let mountpoint = self.lookup(mountpoint)?;
        let superblock = input_uevent::new_event_sysfs(input.clone(), event_minor);
        self.namespace.attach_with_flags_and_devname(
            &mountpoint,
            &superblock,
            PSEUDO_FS_MOUNT_FLAGS,
            None,
        )
        .map(|_| ())
    }

'''
if text[start:end] == new_method:
    print("[skip] writable input event mount already applied")
else:
    BOOT.write_text(text[:start] + new_method + text[end:], encoding="utf-8")
    print("[ok] replaced static input uevent attributes with a writable event mount")

print("[done] input sysfs uevent writes now publish KOBJECT_UEVENT packets")
