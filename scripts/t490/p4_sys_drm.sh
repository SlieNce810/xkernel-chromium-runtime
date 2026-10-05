#!/usr/bin/env bash
# p4_sys_drm.sh — 阶段 2.2：内核侧 sysfs 投射（/sys/class/drm/**），为"移除 libudev shim"铺路
#
# 为什么必须在内核里做（而不是用户态造节点）
# ------------------------------------------
# Weston 14 的 DRM backend 第一跳是 libudev：
#     udev_device_new_from_subsystem_sysname(udev, "drm", "card0")
# 它要求 `/sys/class/drm/card0/uevent` 等真实属性文件存在。此前 `/sys/class` 只有
# `graphics`，所以只能靠 LD_PRELOAD 的 libudev shim 伪造 —— **用户态伪造**是验收
# 明确要拆掉的东西（"无 shim、无伪 sysfs、无伪输入数据库"）。
#
# 投射面怎么定的（实证而非猜）
# --------------------------
# 从 guest 镜像里的真实运行库 `libudev.so.1.6.3`（eudev）**二进制 strings** 提取：
#     /sys/class/        ← 子系统 + sysname 解析
#     /sys/dev/%s/%u:%u  ← 设备号反查（/sys/dev/char/226:0）
#     /sys/bus/ /sys/subsystem/ /sys/module/ /run/udev/**
# 属性名：DEVNAME / DEVTYPE / DRIVER / MAJOR / MINOR
# ⇒ 最小充分集：
#     /sys/class/drm/card0/dev      = "226:0\n"
#     /sys/class/drm/card0/uevent   = MAJOR/MINOR/DEVNAME=dri/card0/DEVTYPE=drm_minor
#     /sys/class/drm/card0/subsystem -> /sys/class/drm
#     /sys/dev/char/226:0           -> /sys/class/drm/card0
#
# 单一真源纪律
# ------------
# 设备号 **不重复写两份**：常量定义在 devfs 的 `/dev/dri/card0` 注册点旁边
# （`fs/filesystems/devfs/src/nodes/dri.rs`），sysfs 投射引用同一常量；
# 且投射本身以 `devfs::drm_available()` 为开关 —— 设备不存在就不造节点。
#
# 幂等 + 形态断言；可反复执行。
set -euo pipefail

XK="$HOME/x-kernel"
DRI="$XK/fs/filesystems/devfs/src/nodes/dri.rs"
DEVFS_LIB="$XK/fs/filesystems/devfs/src/lib.rs"
BOOT="$XK/fs/boot/src/lib.rs"

cd "$XK"
for f in "$DRI" "$DEVFS_LIB" "$BOOT"; do
    [ -f "$f" ] || { echo "FATAL: 找不到 $f"; exit 1; }
done

echo "=== 0. 改动前状态 ==="
grep -n "DeviceId::new" "$DRI" || true
grep -n "create_sys_graphics_links" "$BOOT" | head -3

python3 - "$DRI" "$DEVFS_LIB" "$BOOT" <<'PYEOF'
import sys

dri_path, devfs_lib_path, boot_path = sys.argv[1], sys.argv[2], sys.argv[3]

# ============================================================ 1) devfs/nodes/dri.rs
K_CONSTS = '''
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

/// Register `/dev/dri/card0` if a display device is available.'''

with open(dri_path, encoding="utf-8") as f:
    s = f.read()

if "pub const CARD0_DEV_MAJOR" in s:
    print("dri.rs    : 已是修补形态（常量已存在）")
else:
    anchor = "/// Register `/dev/dri/card0` if a display device is available."
    if anchor not in s:
        print("FATAL: dri.rs 里找不到锚点注释")
        sys.exit(1)
    s = s.replace(anchor, K_CONSTS.strip("\n"), 1)
    s = s.replace("kvfs::DeviceId::new(226, 0)",
                  "kvfs::DeviceId::new(CARD0_DEV_MAJOR, CARD0_DEV_MINOR)", 1)
    with open(dri_path, "w", encoding="utf-8") as f:
        f.write(s)
    print("dri.rs    : 已加入设备号常量 + drm_available()，并把 DeviceId::new 改为引用常量")

# ============================================================ 2) devfs/src/lib.rs
with open(devfs_lib_path, encoding="utf-8") as f:
    l = f.read()

REEXPORT = "pub use nodes::dri::{CARD0_DEV_MAJOR, CARD0_DEV_MINOR, drm_available};"
if REEXPORT in l:
    print("devfs/lib : 已是修补形态（重导出已存在）")
else:
    anchor = "pub use nodes::log::bind_dev_log;"
    if anchor not in l:
        print("FATAL: devfs/src/lib.rs 里找不到 bind_dev_log 重导出锚点")
        sys.exit(1)
    l = l.replace(anchor, anchor + "\n" + REEXPORT, 1)
    with open(devfs_lib_path, "w", encoding="utf-8") as f:
        f.write(l)
    print("devfs/lib : 已重导出 CARD0_DEV_MAJOR / CARD0_DEV_MINOR / drm_available")

# ============================================================ 3) fs/boot/src/lib.rs
with open(boot_path, encoding="utf-8") as f:
    b = f.read()

if "create_sys_drm_entries" in b:
    print("boot/lib  : 已是修补形态（sysfs DRM 投射已存在）")
else:
    # 3a) 在 mount_virtual_filesystems 里加调用
    call_anchor = """        self.create_sys_graphics_links()
            .expect("Failed to create sys graphics links");"""
    new_call = call_anchor + """
        self.create_sys_drm_entries()
            .expect("Failed to create sys DRM entries");"""
    if call_anchor not in b:
        print("FATAL: fs/boot/src/lib.rs 里找不到 create_sys_graphics_links 调用锚点")
        sys.exit(1)
    b = b.replace(call_anchor, new_call, 1)

    # 3b) 在 impl BootVfs 末尾插入新方法（以 create_sys_graphics_links 的结尾为锚点）
    impl_tail = """        if let Err(err) = symlink_result
            && err != kvfs::VfsError::AlreadyExists
        {
            return Err(err);
        }
        Ok(())
    }
}"""
    new_methods = """        if let Err(err) = symlink_result
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
            &format!("{major}:{minor}\\n"),
            0o444,
        )?;
        // card0/uevent —— DEVNAME 决定 udev_device_get_devnode() 的返回值
        self.create_sys_file(
            "/sys/class/drm/card0/uevent",
            &format!("MAJOR={major}\\nMINOR={minor}\\nDEVNAME=dri/card0\\nDEVTYPE=drm_minor\\n"),
            0o444,
        )?;
        // /sys/dev/char/<maj>:<min> → 设备目录（udev_device_new_from_devnum 的入口）
        self.create_sys_symlink(
            &format!("/sys/dev/char/{major}:{minor}"),
            "/sys/class/drm/card0",
        )?;
        // card0/subsystem → /sys/class/drm（真 sysfs 同样提供）
        self.create_sys_symlink("/sys/class/drm/card0/subsystem", "/sys/class/drm")?;
        info!("sysfs: projected /sys/class/drm/card0 ({major}:{minor}) for libudev");
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
        // 注意 `symlink_at` 的 Ok 分支携带 Path（不是 ()）——按 `Ok(_)` 匹配。
        match Filename::new(path).symlink_at(&self.root, &self.root, target, &cred) {
            Ok(_) | Err(kvfs::VfsError::AlreadyExists) => Ok(()),
            Err(err) => Err(err),
        }
    }
}"""
    if impl_tail not in b:
        print("FATAL: fs/boot/src/lib.rs 里找不到 impl BootVfs 结尾锚点")
        sys.exit(1)
    b = b.replace(impl_tail, new_methods, 1)

    with open(boot_path, "w", encoding="utf-8") as f:
        f.write(b)
    print("boot/lib  : 已加入 create_sys_drm_entries + create_sys_file + create_sys_symlink")
PYEOF

echo
echo "=== 断言：关键行都在 ==="
grep -n "pub const CARD0_DEV_MAJOR" "$DRI"
grep -n "CARD0_DEV_MINOR)" "$DRI"
grep -n "drm_available" "$DEVFS_LIB"
grep -n "create_sys_drm_entries" "$BOOT" | head -3

echo
echo "=== cargo check（fs/boot 与 devfs）==="
PATH="$HOME/.cargo/bin:$PATH" cargo check -p fs_boot -p devfs 2>&1 | tail -12 || true

echo
echo "P4_DONE"
