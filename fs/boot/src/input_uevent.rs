// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

//! Writable input sysfs event attributes backed by kernel uevent multicast.

use alloc::{format, string::String, sync::Arc, vec::Vec};

use kvfs::{
    CommandFile, DirMapping, NodePermission, NodeType, SimpleDir, SimpleFile, SimpleFileOperation,
    SimpleFs, SuperBlock, SuperBlockFlags,
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
    SimpleFile::new(fs, NodeType::Symlink, move || {
        Ok(target.clone().into_bytes())
    })
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
        "MAJOR={}\nMINOR={minor}\nDEVNAME=input/{}\nPRODUCT={:04x}/{:04x}/{:04x}/{:04x}\nNAME=\"\
         {}\"\nPHYS=\"{}\"\nUNIQ=\"{}\"\nPROP=0\n",
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

fn publish_input_uevent(input: &devfs::InputSysfsDevice, minor: u32, action: &str) {
    let device_path = input
        .event_path
        .strip_prefix("/sys")
        .unwrap_or(input.event_path.as_str());
    let mut payload = Vec::new();
    payload.extend_from_slice(
        format!(
            "{action}@{device_path}\0ACTION={action}\0DEVPATH={device_path}\0SUBSYSTEM=input\\
             0MAJOR={}\0MINOR={minor}\0DEVNAME=input/{}\0",
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
pub(crate) fn new_event_sysfs(input: devfs::InputSysfsDevice, minor: u32) -> Arc<SuperBlock> {
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
            entries.add("device", symlink_file(fs.clone(), input.input_path.clone()));
            entries.add(
                "subsystem",
                symlink_file(fs.clone(), String::from("/sys/class/input")),
            );
            SimpleDir::new_maker(fs.clone(), Arc::new(entries))
        },
    )
}
