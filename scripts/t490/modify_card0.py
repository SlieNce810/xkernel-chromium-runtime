#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""P0 补丁：修复 card0.rs 中 DrmVersion/DrmUnique 对 NULL 指针的处理。
用法：python3 modify_card0.py <card0.rs 路径>
行为：精确匹配旧函数体并替换；若旧文本未找到则报错退出（不盲改）。
"""

import sys

OLD_VERSION = '''    fn handle(_dev: &Card0, version: &mut Self) -> VfsResult<usize> {
        version.version_major = DRIVER_VERSION_MAJOR;
        version.version_minor = DRIVER_VERSION_MINOR;
        version.version_patchlevel = DRIVER_VERSION_PATCHLEVEL;
        version.name_len = DRIVER_NAME.len();
        version
            .name
            .write_vm_slice(DRIVER_NAME.as_bytes())
            .map_err(|_| VfsError::BadAddress)?;
        version.date_len = DRIVER_DATE.len();
        version
            .date
            .write_vm_slice(DRIVER_DATE.as_bytes())
            .map_err(|_| VfsError::BadAddress)?;
        version.desc_len = DRIVER_DESC.len();
        version
            .desc
            .write_vm_slice(DRIVER_DESC.as_bytes())
            .map_err(|_| VfsError::BadAddress)?;
        Ok(0)
    }'''

NEW_VERSION = '''    fn handle(_dev: &Card0, version: &mut Self) -> VfsResult<usize> {
        version.version_major = DRIVER_VERSION_MAJOR;
        version.version_minor = DRIVER_VERSION_MINOR;
        version.version_patchlevel = DRIVER_VERSION_PATCHLEVEL;
        version.name_len = DRIVER_NAME.len();
        version.date_len = DRIVER_DATE.len();
        version.desc_len = DRIVER_DESC.len();
        // Fill the strings only when the caller provided a buffer.
        // libdrm's first drmGetVersion() call passes NULL pointers / zero
        // lengths to query the sizes; copying to a NULL pointer must not
        // fault (mirrors Linux drm_version handling).
        if !version.name.is_null() && version.name_len > 0 {
            let n = core::cmp::min(DRIVER_NAME.len(), version.name_len);
            version
                .name
                .write_vm_slice(&DRIVER_NAME.as_bytes()[..n])
                .map_err(|_| VfsError::BadAddress)?;
        }
        if !version.date.is_null() && version.date_len > 0 {
            let n = core::cmp::min(DRIVER_DATE.len(), version.date_len);
            version
                .date
                .write_vm_slice(&DRIVER_DATE.as_bytes()[..n])
                .map_err(|_| VfsError::BadAddress)?;
        }
        if !version.desc.is_null() && version.desc_len > 0 {
            let n = core::cmp::min(DRIVER_DESC.len(), version.desc_len);
            version
                .desc
                .write_vm_slice(&DRIVER_DESC.as_bytes()[..n])
                .map_err(|_| VfsError::BadAddress)?;
        }
        Ok(0)
    }'''

OLD_UNIQUE = '''    fn handle(_dev: &Card0, unique: &mut Self) -> VfsResult<usize> {
        let unique_str: String = format!("{}:0", DRIVER_NAME);
        unique.unique_len = unique_str.len();
        unique
            .unique
            .write_vm_slice(unique_str.as_bytes())
            .map_err(|_| VfsError::BadAddress)?;
        Ok(0)
    }'''

NEW_UNIQUE = '''    fn handle(_dev: &Card0, unique: &mut Self) -> VfsResult<usize> {
        let unique_str: String = format!("{}:0", DRIVER_NAME);
        unique.unique_len = unique_str.len();
        if !unique.unique.is_null() && unique.unique_len > 0 {
            let n = core::cmp::min(unique_str.len(), unique.unique_len);
            unique
                .unique
                .write_vm_slice(&unique_str.as_bytes()[..n])
                .map_err(|_| VfsError::BadAddress)?;
        }
        Ok(0)
    }'''


def main() -> int:
    path = sys.argv[1]
    with open(path, "r", encoding="utf-8", newline="") as f:
        content = f.read()

    changed = 0
    for label, old, new in (
        ("DrmVersion::handle", OLD_VERSION, NEW_VERSION),
        ("DrmUnique::handle", OLD_UNIQUE, NEW_UNIQUE),
    ):
        if new in content:
            print(f"[skip] {label}: already patched")
            continue
        count = content.count(old)
        if count != 1:
            print(f"[FAIL] {label}: expected exactly 1 occurrence, found {count}")
            return 1
        content = content.replace(old, new, 1)
        changed += 1
        print(f"[ok] {label}: replaced")

    if changed:
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(content)
        print(f"[done] wrote {path} ({changed} function(s) patched)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
