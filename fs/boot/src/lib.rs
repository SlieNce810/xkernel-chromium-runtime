// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

//! Filesystem namespace preparation during kernel boot.
//!
//! This crate selects the root block device and builds the initial mount
//! namespace. Configured filesystems register their canonical KVFS type
//! descriptors through kernel initcalls before this crate probes registered
//! block-backed types or mounts the built-in virtual filesystems.

#![cfg_attr(any(not(test), doc), no_std)]

extern crate alloc;

mod input_uevent;

#[macro_use]
extern crate log;

#[cfg(feature = "fs9p")]
use alloc::{boxed::Box, string::String};
use alloc::{format, sync::Arc, vec::Vec};

#[cfg(feature = "fs9p")]
use kclass::{ClassDevice, Virtio9pDevice as _, Virtio9pDeviceImpl, virtio_9p_devices};
#[cfg(feature = "fs9p")]
use ksync::Mutex;
#[cfg(feature = "fs9p")]
use kvfs::{FileSystemType, FsContext, FsContextOperations};
use kvfs::{
    Filename, LookupFlags, LookupIntent, MntNamespace, MountFlags, NodePermission, Path,
    SuperBlock, SuperBlockFlags, path::PathBuf,
};

const PSEUDO_FS_MOUNT_FLAGS: MountFlags = MountFlags::NOSUID
    .union(MountFlags::NODEV)
    .union(MountFlags::NOEXEC)
    .union(MountFlags::RELATIME);
// Linux's safe devtmpfs policy is `nosuid,noexec`; `nodev` would prevent the
// device filesystem from serving its defining purpose.
const DEVFS_MOUNT_FLAGS: MountFlags = MountFlags::NOSUID
    .union(MountFlags::NOEXEC)
    .union(MountFlags::RELATIME);
const TMPFS_MOUNT_FLAGS: MountFlags = MountFlags::NOSUID
    .union(MountFlags::NODEV)
    .union(MountFlags::RELATIME);

#[cfg(feature = "fs9p")]
struct Virtio9pTransport(Mutex<ClassDevice<Virtio9pDeviceImpl>>);

#[cfg(feature = "fs9p")]
impl v9fs::Transport for Virtio9pTransport {
    fn request(&self, req: &[u8], resp: &mut [u8]) -> Result<usize, String> {
        let dev = self.0.lock();
        dev.request(req, resp)
            .map_err(|err| format!("virtio-9p error: {err:?}"))
    }
}

#[cfg(feature = "fs9p")]
fn host_9p_get_tree(
    context: &mut FsContext<'_>,
    _lookup_root: &Path,
    _lookup_pwd: &Path,
) -> kvfs::VfsResult<Arc<SuperBlock>> {
    let mut devices = virtio_9p_devices();
    let handle = match context.source().filter(|mount_tag| !mount_tag.is_empty()) {
        Some(mount_tag) => devices
            .into_iter()
            .find(|device| device.mount_tag() == mount_tag),
        None => devices.pop(),
    }
    .ok_or(kvfs::VfsError::NoSuchDevice)?;
    let mount_tag = handle.mount_tag();

    info!("Mount 9P filesystem...");
    info!("  use virtio-9p device: {:?}", handle.name());
    info!("  mount tag: {:?}", mount_tag);

    let transport = Box::new(Virtio9pTransport(Mutex::new(handle)));
    kvfs::get_tree_nodev(context, move |file_system_type, superblock_flags| {
        v9fs::Fs9pFilesystem::mount(file_system_type, superblock_flags, transport, mount_tag)
    })
}

#[cfg(feature = "fs9p")]
static HOST_9P_CONTEXT_OPERATIONS: FsContextOperations = FsContextOperations::new(host_9p_get_tree);

#[cfg(feature = "fs9p")]
fn init_host_9p_context(context: &mut FsContext<'_>) -> kvfs::VfsResult<()> {
    context.set_operations(&HOST_9P_CONTEXT_OPERATIONS);
    Ok(())
}

#[cfg(feature = "fs9p")]
static HOST_9P_TYPE: FileSystemType = FileSystemType::nodev("9p", init_host_9p_context);

#[cfg(feature = "fs9p")]
#[macros::register_init]
fn init_host_9p_fs() {
    kvfs::register_filesystem(&HOST_9P_TYPE).expect("9P filesystem type must register once");
}

/// Prepares the initial mount namespace from registered filesystem types.
///
/// # Panics
///
/// Panics if filesystem initcalls have not registered the required canonical
/// types, or if bootstrap mounts, root device selection, root filesystem
/// construction, or init `fs_struct` setup fails.
pub fn prepare_namespace() {
    let bootstrap = memfs::ramfs::new_rootfs(SuperBlockFlags::empty());
    BootVfs::install_initial_root(bootstrap);

    let boot = BootVfs::initial();
    boot.ensure_directory_path("/dev")
        .expect("Failed to create bootstrap /dev mountpoint");
    boot.mount_at(
        "/dev",
        &devfs::FILE_SYSTEM_TYPE,
        None,
        SuperBlockFlags::empty(),
        DEVFS_MOUNT_FLAGS,
    )
    .expect("Failed to mount bootstrap devfs");
    mount_root_file_system(&boot);
    let root = boot.namespace.visible_root_path();
    fs_context::init_fs()
        .lock()
        .replace_root_and_pwd(root.clone(), root)
        .expect("real root path must replace bootstrap root");
    anon_inodefs::init_anon_inodefs();
    pipefs::init_pipefs();
}

/// Mounts boot-time virtual filesystems into the initial namespace.
pub fn mount_virtual_filesystems() {
    info!("Initialize VFS...");
    devfs::capture_firmware_dtb_snapshot();
    BootVfs::initial().mount_virtual_filesystems();
}

struct BootVfs {
    namespace: Arc<MntNamespace>,
    root: Path,
}

impl BootVfs {
    fn install_initial_root(root_fs: Arc<SuperBlock>) {
        let namespace = MntNamespace::init_mount_tree(&root_fs);
        let root = namespace.visible_root_path();
        fs_context::init_fs()
            .lock()
            .attach_root(root.clone())
            .expect("root path must initialize init fs");
    }

    fn initial() -> Self {
        let namespace = MntNamespace::initial().expect("mount namespace must be initialized");
        let root = namespace.visible_root_path();
        Self { namespace, root }
    }

    fn mount_virtual_filesystems(&self) {
        self.ensure_directory_path("/dev")
            .expect("Failed to create /dev mountpoint");
        self.mount_at(
            "/dev",
            &devfs::FILE_SYSTEM_TYPE,
            None,
            SuperBlockFlags::empty(),
            DEVFS_MOUNT_FLAGS,
        )
        .expect("Failed to mount devfs");
        self.ensure_directory_path("/dev/shm")
            .expect("Failed to create /dev/shm mountpoint");
        self.mount_at(
            "/dev/shm",
            &memfs::TMPFS_TYPE,
            None,
            SuperBlockFlags::empty(),
            TMPFS_MOUNT_FLAGS,
        )
        .expect("Failed to mount /dev/shm");
        self.ensure_directory_path("/tmp")
            .expect("Failed to create /tmp mountpoint");
        self.mount_at(
            "/tmp",
            &memfs::TMPFS_TYPE,
            None,
            SuperBlockFlags::empty(),
            TMPFS_MOUNT_FLAGS,
        )
        .expect("Failed to mount /tmp");
        self.ensure_directory_path("/proc")
            .expect("Failed to create /proc mountpoint");
        self.mount_at(
            "/proc",
            &procfs::FILE_SYSTEM_TYPE,
            None,
            SuperBlockFlags::empty(),
            PSEUDO_FS_MOUNT_FLAGS,
        )
        .expect("Failed to mount procfs");
        self.ensure_directory_path("/sys")
            .expect("Failed to create /sys mountpoint");
        self.mount_at(
            "/sys",
            &memfs::SYSFS_TYPE,
            None,
            SuperBlockFlags::empty(),
            PSEUDO_FS_MOUNT_FLAGS,
        )
        .expect("Failed to mount sysfs");

        #[cfg(feature = "cgroup2")]
        {
            self.ensure_directory_path("/sys/fs/cgroup")
                .expect("Failed to create /sys/fs/cgroup mountpoint");
            let mountpoint = self
                .lookup("/sys/fs/cgroup")
                .expect("Failed to resolve /sys/fs/cgroup mountpoint");
            let super_block = cgroup2fs::new_initial_cgroup2fs(SuperBlockFlags::empty());
            self.namespace
                .attach_with_flags_and_devname(
                    &mountpoint,
                    &super_block,
                    PSEUDO_FS_MOUNT_FLAGS,
                    None,
                )
                .expect("Failed to mount cgroup2fs");
        }

        #[cfg(feature = "ebpf")]
        {
            self.ensure_directory_path("/sys/fs/bpf")
                .expect("Failed to create /sys/fs/bpf mountpoint");
            self.mount_at(
                "/sys/fs/bpf",
                &bpffs::FILE_SYSTEM_TYPE,
                None,
                SuperBlockFlags::empty(),
                PSEUDO_FS_MOUNT_FLAGS,
            )
            .expect("Failed to mount bpffs");
        }
        self.create_sys_graphics_links()
            .expect("Failed to create sys graphics links");
        self.create_sys_drm_entries()
            .expect("Failed to create sys DRM entries");
        self.create_sys_input_entries()
            .expect("Failed to create sys input entries");
        self.create_sys_cpu_entries()
            .expect("Failed to create sys CPU entries");

        if let Err(err) = devfs::bind_dev_log() {
            if err != kerrno::LinuxError::ENOSYS && err != kerrno::LinuxError::EOPNOTSUPP {
                panic!("Failed to bind dev-log: {err}");
            }
            warn!("/dev/log not available: {err}");
        }
    }

    fn lookup(&self, path: impl AsRef<str>) -> kvfs::VfsResult<Path> {
        let cred = kcred::initial_cred();
        Filename::new(path.as_ref()).lookup_at(
            &self.root,
            &self.root,
            LookupIntent::Open,
            LookupFlags::follow(),
            &cred,
        )
    }

    fn mkdir_path(&self, path: impl AsRef<str>) -> kvfs::VfsResult<()> {
        let cred = kcred::initial_cred();
        Filename::new(path.as_ref())
            .mkdir_at(
                &self.root,
                &self.root,
                NodePermission::from_bits_truncate(0o755),
                NodePermission::empty(),
                &cred,
            )
            .map(|_| ())
    }

    fn ensure_directory_path(&self, path: &str) -> kvfs::VfsResult<()> {
        let mut current = PathBuf::new();
        for_each_lexical_component(path, |component| {
            current.push(component);
            if self.lookup(&current).is_err() {
                self.mkdir_path(&current)?;
            }
            Ok(())
        })
    }

    fn mount_at(
        &self,
        path: &str,
        file_system_type: &'static kvfs::FileSystemType,
        source: Option<&str>,
        superblock_flags: SuperBlockFlags,
        mount_flags: MountFlags,
    ) -> kvfs::VfsResult<()> {
        let mountpoint = self.lookup(path)?;
        if !mountpoint.is_dir() {
            return Err(kvfs::VfsError::NotADirectory);
        }
        let cred = kcred::initial_cred();
        let mut context =
            kvfs::FsContext::new(file_system_type, source, None, superblock_flags, &cred)?;
        self.namespace.mount_new(
            &mountpoint,
            mount_flags,
            &mut context,
            &self.root,
            &self.root,
        )?;
        Ok(())
    }

    fn create_sys_graphics_links(&self) -> kvfs::VfsResult<()> {
        self.ensure_directory_path("/sys/class/graphics/fb0/device")?;
        let cred = kcred::initial_cred();
        let symlink_result = Filename::new("/sys/class/graphics/fb0/device/subsystem")
            .symlink_at(&self.root, &self.root, "whatever", &cred);
        if let Err(err) = symlink_result
            && err != kvfs::VfsError::AlreadyExists
        {
            return Err(err);
        }
        Ok(())
    }

    /// # 内核侧 sysfs 投射：DRM 设备
    ///
    /// 为什么必须在**内核**里做：Weston 14 的 DRM backend 先经 libudev 在
    /// `/sys/class/drm/<name>` 找到设备、拿到 devnode，才去 open 设备节点
    /// （`udev_device_new_from_subsystem_sysname(..., "drm", "card0")`）。
    /// 此前 `/sys/class` 只有 `graphics`，只能靠 LD_PRELOAD 的 libudev shim 伪造，
    /// 而用户态伪造正是验收要拆掉的东西。
    ///
    /// 投射面来自**实证**：guest 镜像里的 `libudev.so.1.6.3`（eudev）二进制里
    /// 引用 `/sys/class/`、`/sys/dev/%s/%u:%u`，解析属性 MAJOR/MINOR/DEVNAME/DEVTYPE。
    /// 设备号取自 devfs 的 `/dev/dri/card0` 注册点（单一真源），本函数不做任何硬编码。
    fn create_sys_drm_entries(&self) -> kvfs::VfsResult<()> {
        if !devfs::drm_available() {
            return Ok(());
        }
        let major = devfs::CARD0_DEV_MAJOR;
        let minor = devfs::CARD0_DEV_MINOR;

        self.ensure_directory_path("/sys/class/drm/card0")?;
        self.ensure_directory_path("/sys/dev/char")?;

        // card0/dev —— libudev 用它解析设备号
        self.create_sys_file(
            "/sys/class/drm/card0/dev",
            &format!("{major}:{minor}\n"),
            0o444,
        )?;
        // card0/uevent —— DEVNAME 决定 udev_device_get_devnode() 的返回值
        self.create_sys_file(
            "/sys/class/drm/card0/uevent",
            &format!("MAJOR={major}\nMINOR={minor}\nDEVNAME=dri/card0\nDEVTYPE=drm_minor\n"),
            0o444,
        )?;
        // /sys/dev/char/<maj>:<min> → 设备目录（udev_device_new_from_devnum 的入口）
        self.create_sys_symlink(
            &format!("/sys/dev/char/{major}:{minor}"),
            "/sys/class/drm/card0",
        )?;
        // libdrm walks /sys/dev/char/<major>:<minor>/device before it accepts
        // a DRM minor. The KMS-only driver has no PCI parent, so provide the
        // simpledrm-style device/subsystem links used by platform displays.
        self.ensure_directory_path("/sys/devices/simpledrm")?;
        self.ensure_directory_path("/sys/devices/simpledrm/drm")?;
        self.ensure_directory_path("/sys/bus/platform")?;
        self.create_sys_symlink("/sys/class/drm/card0/device", "/sys/devices/simpledrm")?;
        self.create_sys_symlink("/sys/devices/simpledrm/subsystem", "/sys/bus/platform")?;
        self.create_sys_symlink("/sys/devices/simpledrm/drm/card0", "/sys/class/drm/card0")?;
        self.create_sys_file(
            "/sys/devices/simpledrm/uevent",
            "DRIVER=simpledrm\nDEVTYPE=drm_minor\nOF_FULLNAME=/simple-framebuffer\\
             nMODALIAS=platform:simpledrm\nOF_COMPATIBLE_N=1\nOF_COMPATIBLE_0=simpledrm\n",
            0o444,
        )?;
        // card0/subsystem -> /sys/class/drm.
        self.create_sys_symlink("/sys/class/drm/card0/subsystem", "/sys/class/drm")?;
        // The virtio/simpledrm device also exposes a render node. Chromium's
        // Ozone Wayland path discovers it by walking /sys/class/drm/renderD*
        // before opening /dev/dri/renderD128; the devfs node alone is not
        // sufficient. Keep the render minor tied to the same simpledrm device
        // model as card0 so libudev/libdrm see one coherent DRM device.
        let render_minor = 128;
        self.ensure_directory_path("/sys/class/drm/renderD128")?;
        self.create_sys_file(
            "/sys/class/drm/renderD128/dev",
            &format!("{major}:{render_minor}\n"),
            0o444,
        )?;
        self.create_sys_file(
            "/sys/class/drm/renderD128/uevent",
            &format!(
                "MAJOR={major}\nMINOR={render_minor}\nDEVNAME=dri/renderD128\nDEVTYPE=drm_minor\n"
            ),
            0o444,
        )?;
        self.create_sys_symlink(
            &format!("/sys/dev/char/{major}:{render_minor}"),
            "/sys/class/drm/renderD128",
        )?;
        self.create_sys_symlink(
            "/sys/class/drm/renderD128/device",
            "/sys/devices/simpledrm",
        )?;
        self.create_sys_symlink(
            "/sys/devices/simpledrm/drm/renderD128",
            "/sys/class/drm/renderD128",
        )?;
        self.create_sys_symlink(
            "/sys/class/drm/renderD128/subsystem",
            "/sys/class/drm",
        )?;
        info!(
            "sysfs: projected /sys/class/drm/card0 ({major}:{minor}) and renderD128 ({major}:{render_minor})"
        );
        Ok(())
    }

    /// Project input devices from the registered kernel device snapshot.
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
            let event_dev_target = format!("../../{event_relative}");
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
            self.ensure_directory_path(&format!(
                "/sys/bus/{}/devices",
                if input.parent_bus_path.ends_with("/pci") {
                    "pci"
                } else {
                    "platform"
                }
            ))?;

            let parent_uevent = format!(
                "SUBSYSTEM={}\n",
                if input.parent_bus_path.ends_with("/pci") {
                    "pci"
                } else {
                    "platform"
                },
            );
            self.create_sys_file(&format!("{parent}/uevent"), &parent_uevent, 0o444)?;
            self.create_sys_file(
                &format!("{input_path}/name"),
                &format!("{}\n", input.name),
                0o444,
            )?;
            self.create_sys_file(
                &format!("{input_path}/phys"),
                &format!("{}\n", input.physical_location),
                0o444,
            )?;
            self.create_sys_file(
                &format!("{input_path}/uniq"),
                &format!("{}\n", input.unique_id),
                0o444,
            )?;
            self.create_sys_file(
                &format!("{input_path}/uevent"),
                &format!(
                    "PRODUCT={:04x}/{:04x}/{:04x}/{:04x}\nNAME=\"{}\"\nPHYS=\"{}\"\nUNIQ=\"{}\"\\
                     nPROP=0\n",
                    input.bus_type,
                    input.vendor,
                    input.product,
                    input.version,
                    input.name,
                    input.physical_location,
                    input.unique_id,
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
                    devfs::INPUT_DEV_MAJOR,
                    input.event_name,
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
                    devfs::INPUT_DEV_MAJOR,
                    input.event_name,
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
                input.event_name,
                input.name,
                devfs::INPUT_DEV_MAJOR,
                input_path,
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
        self.namespace
            .attach_with_flags_and_devname(&mountpoint, &superblock, PSEUDO_FS_MOUNT_FLAGS, None)
            .map(|_| ())
    }

    /// Project the platform's actual CPU map for userspace CPU discovery.
    ///
    /// CPU identities come from the device tree parsed by `kcpu_id_map`.
    /// x-kernel does not support CPU hotplug, so every discovered CPU is
    /// present and online for this fixed QEMU platform.
    fn create_sys_cpu_entries(&self) -> kvfs::VfsResult<()> {
        let cpu_count = kcpu_id_map::nr_cpus().max(1);
        // The literal arm is kept to mirror the formatted arm below.
        #[allow(clippy::useless_format)]
        let cpu_list = if cpu_count == 1 {
            format!("0\n")
        } else {
            format!("0-{}\n", cpu_count - 1)
        };
        let kernel_max = format!("{}\n", cpu_count - 1);
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

        info!(
            "sysfs: projected CPU map from device tree: {}",
            cpu_list.trim()
        );
        Ok(())
    }

    /// 建一个内容固定的 sysfs 属性文件（已存在则截断重写）。
    fn create_sys_file(&self, path: &str, content: &str, mode: u16) -> kvfs::VfsResult<()> {
        let cred = kcred::initial_cred();
        if let Some((parent, _)) = path.rsplit_once('/') {
            self.ensure_directory_path(parent)?;
        }
        let file = Filename::new(path).open_with_flags_at(
            &self.root,
            &self.root,
            (kvfs::OpenFlags::WRITE_ONLY | kvfs::OpenFlags::CREATE | kvfs::OpenFlags::TRUNCATE)
                .bits(),
            NodePermission::from_bits_truncate(mode),
            NodePermission::empty(),
            cred,
        )?;
        let mut pos = 0u64;
        let data = content.as_bytes();
        while (pos as usize) < data.len() {
            let n = file.write_from(&data[pos as usize..], &mut pos)?;
            if n == 0 {
                return Err(kvfs::VfsError::Io);
            }
        }
        Ok(())
    }

    /// 建一个符号链接（已存在则跳过）。
    fn create_sys_symlink(&self, path: &str, target: &str) -> kvfs::VfsResult<()> {
        let cred = kcred::initial_cred();
        match Filename::new(path).symlink_at(&self.root, &self.root, target, &cred) {
            Ok(_) | Err(kvfs::VfsError::AlreadyExists) => Ok(()),
            Err(err) => Err(err),
        }
    }
}

fn mount_root_file_system(boot: &BootVfs) {
    info!("Initialize filesystem subsystem...");

    let mut block_devs = block::block_devices()
        .into_iter()
        .filter(|device| device.num_blocks() != 0)
        .collect();
    let handle = select_root_block(&mut block_devs);
    let source = format!("/dev/{}", handle.name());

    info!(
        "  use block device 0: {:?} ({:?})",
        handle.name(),
        handle.device_number(),
    );

    let file_system_types: Vec<_> = kvfs::registered_filesystems()
        .into_iter()
        .filter(|file_system_type| file_system_type.requires_device())
        .collect();
    let cred = kcred::initial_cred();
    for superblock_flags in [SuperBlockFlags::empty(), SuperBlockFlags::RDONLY] {
        let mut mount_flags = MountFlags::RELATIME;
        if superblock_flags.contains(SuperBlockFlags::RDONLY) {
            mount_flags.insert(MountFlags::RDONLY);
        }

        for file_system_type in &file_system_types {
            let result = kvfs::FsContext::new(
                file_system_type,
                Some(&source),
                None,
                superblock_flags,
                &cred,
            )
            .and_then(|mut context| {
                boot.namespace.mount_new(
                    &boot.root,
                    mount_flags,
                    &mut context,
                    &boot.root,
                    &boot.root,
                )
            });
            match result {
                Ok(mount) => {
                    info!("  filesystem type: {:?}", mount.filesystem_name());
                    return;
                }
                Err(err)
                    if matches!(
                        kerrno::LinuxError::from(err),
                        kerrno::LinuxError::EACCES | kerrno::LinuxError::EINVAL
                    ) =>
                {
                    debug!(
                        "root filesystem probe as {} failed: {err:?}",
                        file_system_type.name()
                    );
                }
                Err(err) => {
                    error!(
                        "Failed to mount root filesystem as {}: {err:?}",
                        file_system_type.name()
                    );
                    panic!("VFS: Unable to mount root fs");
                }
            }
        }
    }
    error!("Failed to mount {source} using any registered block filesystem type");
    panic!("VFS: Unable to mount root fs");
}

/// Chooses the block device used as the root filesystem.
fn select_root_block(devs: &mut Vec<Arc<block::BlockDevice>>) -> Arc<block::BlockDevice> {
    let preferred = kbuild_config::KFEAT_ROOT_BLOCK.trim();
    if !preferred.is_empty() {
        let index = devs
            .iter()
            .position(|device| device.name() == preferred)
            .unwrap_or_else(|| {
                panic!(
                    "root block device '{preferred}' not found among {:?}",
                    devs.iter().map(|device| device.name()).collect::<Vec<_>>()
                )
            });
        return devs.remove(index);
    }

    #[cfg(feature = "rootfs-secondary-block")]
    {
        assert!(devs.len() >= 2, "Less than two block devices found!");
        devs.remove(1)
    }
    #[cfg(not(feature = "rootfs-secondary-block"))]
    {
        assert!(!devs.is_empty(), "No block device found!");
        devs.remove(0)
    }
}

/// Mounts the host-share 9P filesystem into the initial namespace.
#[cfg(feature = "fs9p")]
pub fn mount_host_share(mount_path: &str) {
    let boot = BootVfs::initial();
    boot.ensure_directory_path(mount_path)
        .expect("Failed to create 9P mountpoint path");
    boot.mount_at(
        mount_path,
        &HOST_9P_TYPE,
        None,
        SuperBlockFlags::empty(),
        MountFlags::RELATIME,
    )
    .expect("Failed to mount 9P filesystem");
    info!("  mounted at: {:?}", mount_path);
}

fn for_each_lexical_component<E>(
    path: &str,
    mut f: impl FnMut(&str) -> Result<(), E>,
) -> Result<(), E> {
    let mut rest = path;
    let mut at_start = true;
    while !rest.is_empty() {
        let (component, next) = match rest.find('/') {
            Some(index) => (&rest[..index], &rest[index + 1..]),
            None => (rest, ""),
        };
        rest = next;
        let component = match component {
            "" if at_start => Some("/"),
            "" => None,
            "." if at_start => Some("."),
            "." => None,
            name => Some(name),
        };
        at_start = false;
        if let Some(component) = component {
            f(component)?;
        }
    }
    Ok(())
}
