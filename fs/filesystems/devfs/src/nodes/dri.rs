// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

//! `/dev/dri/` — DRM device directory registration.

use alloc::sync::Arc;

use kvfs::{DirMapping, SimpleDir, SimpleFs};

use crate::{DeviceFile, add_device_entry};

/// `/dev/dri/card0` 的设备号（major, minor）—— **单一真源**。
///
/// 内核 sysfs 投射（`fs/boot` 生成 `/sys/class/drm/card0/{dev,uevent}`）与这里的
/// 设备节点注册必须给出**同一个**设备号；两处各写一份常量必然漂移，
/// 所以由本文件定义、两处引用。
pub const CARD0_DEV_MAJOR: u32 = 226;
pub const CARD0_DEV_MINOR: u32 = 0;

/// 显示设备是否可用（即 `/dev/dri/card0` 已注册）。
///
/// 供 sysfs 投射判断"要不要生成 `/sys/class/drm/**`"——绝不为不存在的设备造节点。
pub fn drm_available() -> bool {
    drmdevice::available()
}

/// Register `/dev/dri/card0` if a display device is available.
pub(crate) fn add_root_entries(root: &mut DirMapping, fs: Arc<SimpleFs>) {
    if !drmdevice::available() {
        return;
    }
    let mut dri_dir = DirMapping::new();
    add_device_entry(
        &mut dri_dir,
        "card0",
        DeviceFile::new_character(
            fs.clone(),
            kvfs::DeviceId::new(CARD0_DEV_MAJOR, CARD0_DEV_MINOR),
            drmdevice::Card0::new(),
        ),
    );
    add_device_entry(
        &mut dri_dir,
        "renderD128",
        DeviceFile::new_character(
            fs.clone(),
            kvfs::DeviceId::new(CARD0_DEV_MAJOR, 128),
            drmdevice::Card0::new(),
        ),
    );
    root.add("dri", SimpleDir::new_maker(fs, Arc::new(dri_dir)));
}
