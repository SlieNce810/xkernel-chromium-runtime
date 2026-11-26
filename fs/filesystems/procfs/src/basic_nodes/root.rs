// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

use alloc::{format, string::String, sync::Arc};
use core::fmt::Write;

use kbuild_config::ARCH;
use kcpu_id_map::for_each_present_logical_cpu;
use khal::time::monotonic_time;
use kvfs::{DirMapping, SimpleDir, SimpleFile, SimpleFs};

pub(crate) fn add_root_entries(root: &mut DirMapping, fs: Arc<SimpleFs>) {
    root.add(
        "cmdline",
        SimpleFile::new_regular(fs.clone(), || {
            Ok(match khal::cmdline() {
                Some(cmdline) if !cmdline.is_empty() => format!("{cmdline}\n"),
                _ => String::from("\n"),
            })
        }),
    );
    root.add(
        "stat",
        SimpleFile::new_regular(fs.clone(), || {
            Ok(String::from(
                "cpu  0 0 0 0 0 0 0 0 0 0\nintr 0\nctxt 0\nbtime 0\nprocesses 1\nprocs_running \
                 1\nprocs_blocked 0\n",
            ))
        }),
    );
    root.add(
        "uptime",
        SimpleFile::new_regular(fs.clone(), || {
            let uptime = monotonic_time().span_since_origin();
            let seconds = uptime.as_secs();
            let millis = uptime.subsec_nanos() / 1_000_000;
            Ok(format!("{seconds}.{millis:03} {seconds}.{millis:03}\n"))
        }),
    );
    root.add(
        "loadavg",
        SimpleFile::new_regular(fs.clone(), || Ok(String::from("0.00 0.00 0.00 1/1 1\n"))),
    );
    root.add(
        "meminfo",
        SimpleFile::new_regular(fs.clone(), || {
            Ok(
                String::from(
                    "MemTotal:        2097152 kB\nMemFree:         1048576 kB\nMemAvailable:    \
                     1048576 kB\nBuffers:               0 kB\nCached:                0 \
                     kB\nSwapTotal:            0 kB\nSwapFree:             0 kB\n",
                ),
            )
        }),
    );
    root.add(
        "instret",
        SimpleFile::new_regular(fs.clone(), || {
            #[cfg(any(target_arch = "riscv32", target_arch = "riscv64"))]
            {
                Ok(format!("{}\n", riscv::register::instret::read64()))
            }
            #[cfg(not(any(target_arch = "riscv32", target_arch = "riscv64")))]
            {
                Ok(String::from("0\n"))
            }
        }),
    );
    root.add(
        "cpuinfo",
        SimpleFile::new_regular(fs.clone(), || {
            let mut info = String::new();
            for_each_present_logical_cpu(|present_index, cpu_id, cpu_count| {
                writeln!(
                    info,
                    "processor\t: {}\nBogoMIPS\t: 0.00\nFeatures\t: fp asimd evtstrm aes pmull \
                     sha1 sha2 crc32\nCPU implementer\t: 0x41\nCPU architecture\t: 8\nCPU \
                     variant\t: 0x0\nCPU part\t: 0xd0b\nCPU revision\t: 0\ncpu cores\t: \
                     {}\narchitecture\t: {}",
                    cpu_id.as_usize(),
                    cpu_count,
                    ARCH,
                )
                .unwrap();
                if present_index + 1 < cpu_count {
                    info.push('\n');
                }
            });
            Ok(info)
        }),
    );
    root.add(
        "filesystems",
        SimpleFile::new_regular(fs.clone(), || {
            let mut info = String::new();
            for file_system_type in kvfs::registered_filesystems() {
                writeln!(
                    info,
                    "{}\t{}",
                    if file_system_type.requires_device() {
                        ""
                    } else {
                        "nodev"
                    },
                    file_system_type.name(),
                )
                .unwrap();
            }
            Ok(info)
        }),
    );
    root.add("sys", {
        let mut sys = DirMapping::new();

        sys.add("kernel", {
            let mut kernel = DirMapping::new();
            kernel.add(
                "pid_max",
                SimpleFile::new_regular(fs.clone(), || Ok("32768\n")),
            );
            SimpleDir::new_maker(fs.clone(), Arc::new(kernel))
        });

        sys.add("fs", {
            let mut sys_fs = DirMapping::new();

            sys_fs.add("inotify", {
                let mut inotify = DirMapping::new();
                // Chromium 的 file_path_watcher_inotify.cc 读 max_user_watches
                // 决定 watch 配额；缺失时报 "Failed to read
                // /proc/sys/fs/inotify/max_user_watches"，watch 功能整体降级。
                // 取值照 Linux 默认（fs/inotify 的初始值），仅只读暴露。
                inotify.add(
                    "max_queued_events",
                    SimpleFile::new_regular(fs.clone(), || Ok("16384\n")),
                );
                inotify.add(
                    "max_user_instances",
                    SimpleFile::new_regular(fs.clone(), || Ok("128\n")),
                );
                inotify.add(
                    "max_user_watches",
                    SimpleFile::new_regular(fs.clone(), || Ok("65536\n")),
                );
                SimpleDir::new_maker(fs.clone(), Arc::new(inotify))
            });

            SimpleDir::new_maker(fs.clone(), Arc::new(sys_fs))
        });

        SimpleDir::new_maker(fs.clone(), Arc::new(sys))
    });
}
