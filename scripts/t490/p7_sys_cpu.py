#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Project the runtime CPU map into read-only sysfs files used by ARM64 cpuinfo.

Run this from the x-kernel checkout. CPU IDs come from the kernel's parsed
device tree map; guest scripts do not synthesize /sys/devices/system/cpu.
"""
from __future__ import annotations

from pathlib import Path


ROOT = Path.home() / "x-kernel"
CARGO = ROOT / "fs/boot/Cargo.toml"
BOOT = ROOT / "fs/boot/src/lib.rs"


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count == 0:
        if new in text:
            print(f"[skip] {label} already applied")
            return
        raise SystemExit(f"[FATAL] anchor not found for {label}: {path}")
    if count != 1:
        raise SystemExit(f"[FATAL] {label} anchor matched {count} times: {path}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")
    print(f"[ok] {label}")


replace_once(
    CARGO,
    "kbuild_config.workspace = true\n",
    "kbuild_config.workspace = true\nkcpu_id_map.workspace = true\n",
    "fs_boot runtime CPU map dependency",
)

replace_once(
    BOOT,
    "        self.create_sys_drm_entries()\n"
    "            .expect(\"Failed to create sys DRM entries\");\n",
    "        self.create_sys_drm_entries()\n"
    "            .expect(\"Failed to create sys DRM entries\");\n"
    "        self.create_sys_cpu_entries()\n"
    "            .expect(\"Failed to create sys CPU entries\");\n",
    "boot-time CPU sysfs projection call",
)

method = '''    /// Project the platform's actual CPU map for userspace CPU discovery.
    ///
    /// CPU identities come from the device tree parsed by `kcpu_id_map`.
    /// x-kernel does not support CPU hotplug, so every discovered CPU is
    /// present and online for this fixed QEMU platform.
    fn create_sys_cpu_entries(&self) -> kvfs::VfsResult<()> {
        let cpu_count = kcpu_id_map::nr_cpus().max(1);
        let cpu_list = if cpu_count == 1 {
            format!("0\\n")
        } else {
            format!("0-{}\\n", cpu_count - 1)
        };
        let kernel_max = format!("{}\\n", cpu_count - 1);
        let base = "/sys/devices/system/cpu";
        self.ensure_directory_path(base)?;

        for (name, value) in [
            ("possible", cpu_list.as_str()),
            ("present", cpu_list.as_str()),
            ("online", cpu_list.as_str()),
            ("kernel_max", kernel_max.as_str()),
        ] {
            self.create_sys_file(&format!("{base}/{name}"), value, 0o444)?;
        }

        info!("sysfs: projected CPU map from device tree: {}", cpu_list.trim());
        Ok(())
    }

'''
anchor = "    /// 建一个内容固定的 sysfs 属性文件（已存在则截断重写）。\n"
replace_once(BOOT, anchor, method + anchor, "runtime CPU sysfs projection")

print("[done] CPU sysfs projection is ready; verify with make build before running QEMU")
