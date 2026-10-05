/* libudev_shim.c — LD_PRELOAD shim：让 libudev 在无 sysfs 设备模型的环境里可用
 *
 * 为什么需要它（weston5 轮的结论，本轮最关键的发现）
 * --------------------------------------------------
 * Weston 14 的 DRM backend **不直接 open() 设备**，而是先通过 libudev 查 sysfs：
 *
 *     // libweston/backend-drm/drm.c:3697
 *     static struct udev_device *
 *     open_specific_drm_device(struct drm_backend *b, struct drm_device *device,
 *                              const char *name)
 *     {
 *             udev_device = udev_device_new_from_subsystem_sysname(b->udev, "drm", name);
 *             if (!udev_device) {
 *                     weston_log("ERROR: could not open DRM device '%s'\n", name);
 *                     return NULL;
 *             }
 *             ...
 *     }
 *
 * `udev_device_new_from_subsystem_sysname()` 需要 `/sys/class/drm/<name>/`（及其 uevent、
 * dev 等属性文件）。x-kernel guest 的 `/sys/class` 只有 `graphics`，**没有 `drm`**
 * ⇒ 这一步返回 NULL ⇒ 直接打印 "could not open DRM device" 并 return
 * ⇒ **libseat_open_device / open() 从头到尾不会被调用**。
 *
 * 这解释了此前几轮的全部现象（无论 `--drm-device=card0` 还是 `/dev/dri/card0` 都失败、
 * seatd 侧收不到任何 device 请求、libseat shim 只看到 open_seat/close_seat）。
 *
 * 内核侧的正解是在 sysfs 里暴露 DRM 设备（已记为缺口），但那是独立的、更大的工作；
 * 本 shim 是**用户态过渡方案**：用假 udev 对象喂给 weston，让它走到
 * `drm_device_is_kms()` → `udev_device_get_devnode()` → `weston_launcher_open()`
 * → （libseat shim）→ `open("/dev/dri/card0")` → 内核 DRM（已修复的属性面）。
 *
 * 覆盖范围：drm.c / libinput 会用到的 udev API 全集。三条原则：
 *   1. **句柄用静态变量的地址**（有效但非真实结构）—— weston 只把这些指针传回给本 shim
 *      的其它函数，不会解引用，因此安全；
 *   2. **枚举一律返回空列表** —— find_primary_gpu / libinput 拿不到设备即优雅跳过
 *      （Weston 走 `--drm-device` 指定路径，不需要枚举）；
 *   3. **每个关键调用都打日志** —— 让"卡在哪一步"从日志可判，不靠猜。
 *
 * 编译：aarch64-linux-musl-gcc -shared -fPIC -O2 -o libudev-shim.so libudev_shim.c
 * 用法：LD_PRELOAD="/shim/libseat-shim.so /shim/libudev-shim.so" weston ...
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/sysmacros.h>

/* 本 guest 的 DRM 设备节点与设备号（weston2 轮实测：crw-rw-rw- 226, 0） */
#define DRM_DEVNODE   "/dev/dri/card0"
#define DRM_SYSNAME   "card0"
#define DRM_SYSNUM    "0"
#define DRM_MAJOR     226
#define DRM_MINOR     0

/* 假句柄：用静态变量地址，保证非 NULL 且唯一 */
static int g_ctx, g_dev, g_dev_extra, g_enum, g_mon, g_entry;

static int g_devnull_fd = -1;
static int g_devnull(void)
{
    if (g_devnull_fd < 0)
        g_devnull_fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
    return g_devnull_fd;
}

/* ============================ udev context ============================ */
void *udev_new(void)
{
    fprintf(stderr, "[udev-shim] udev_new -> fake ctx\n");
    return &g_ctx;
}

void *udev_unref(void *ctx)
{
    fprintf(stderr, "[udev-shim] udev_unref(%p) -> NULL\n", ctx);
    return NULL;
}

/* ============================ udev_device ============================ */

/* ★ 核心：weston 用它按 subsystem+sysname 找设备。
 *   我们把任何 "drm" 子系统的查询都当作命中，返回假 device。 */
void *udev_device_new_from_subsystem_sysname(void *ctx, const char *subsystem, const char *sysname)
{
    fprintf(stderr, "[udev-shim] device_new_from_subsystem_sysname(subsystem='%s', sysname='%s') -> fake dev\n",
            subsystem ? subsystem : "(null)", sysname ? sysname : "(null)");
    /* 只对 drm 命中；输入设备返回 NULL（配合 --continue-without-input，weston 会跳过输入） */
    if (subsystem && strcmp(subsystem, "drm") == 0)
        return &g_dev;
    return NULL;
}

void *udev_device_new_from_syspath(void *ctx, const char *syspath)
{
    fprintf(stderr, "[udev-shim] device_new_from_syspath('%s') -> fake dev\n",
            syspath ? syspath : "(null)");
    return &g_dev_extra;
}

/* ★ 三个关键属性：drm_device_is_kms() 依次要它们 */
const char *udev_device_get_devnode(void *dev)
{
    if (dev == &g_dev || dev == &g_dev_extra) {
        fprintf(stderr, "[udev-shim]   get_devnode -> %s\n", DRM_DEVNODE);
        return DRM_DEVNODE;
    }
    return NULL;
}

const char *udev_device_get_sysnum(void *dev)
{
    if (dev == &g_dev || dev == &g_dev_extra) {
        fprintf(stderr, "[udev-shim]   get_sysnum -> %s\n", DRM_SYSNUM);
        return DRM_SYSNUM;
    }
    return NULL;
}

unsigned long long udev_device_get_devnum(void *dev)
{
    if (dev == &g_dev || dev == &g_dev_extra)
        return (unsigned long long)makedev(DRM_MAJOR, DRM_MINOR);
    return 0;
}

const char *udev_device_get_sysname(void *dev)
{
    return (dev == &g_dev || dev == &g_dev_extra) ? DRM_SYSNAME : NULL;
}

const char *udev_device_get_syspath(void *dev)
{
    if (dev == &g_dev || dev == &g_dev_extra) {
        fprintf(stderr, "[udev-shim]   get_syspath -> /sys/devices/fake/drm/%s\n", DRM_SYSNAME);
        return "/sys/devices/fake/drm/" DRM_SYSNAME;
    }
    return NULL;
}

/* 属性查询：返回 NULL 表示"没有该属性"。weston 对 NULL 是有容忍的
 * （例如 boot_vga 检测、PCI 父设备查找失败都不致命）。 */
const char *udev_device_get_sysattr_value(void *dev, const char *sysattr)
{
    fprintf(stderr, "[udev-shim]   get_sysattr_value('%s') -> NULL\n",
            sysattr ? sysattr : "(null)");
    return NULL;
}

const char *udev_device_get_property_value(void *dev, const char *property)
{
    fprintf(stderr, "[udev-shim]   get_property_value('%s') -> NULL\n",
            property ? property : "(null)");
    return NULL;
}

void *udev_device_get_parent_with_subsystem_devtype(void *dev, const char *subsystem, const char *devtype)
{
    (void)dev;
    fprintf(stderr, "[udev-shim]   get_parent_with_subsystem_devtype('%s') -> NULL\n",
            subsystem ? subsystem : "(null)");
    return NULL;
}

const char *udev_device_get_devtype(void *dev) { (void)dev; return NULL; }
const char *udev_device_get_subsystem(void *dev) { (void)dev; return "drm"; }
const char *udev_device_get_action(void *dev) { (void)dev; return NULL; }

void *udev_device_unref(void *dev)
{
    fprintf(stderr, "[udev-shim] device_unref(%p) -> NULL\n", dev);
    return NULL;
}

void *udev_device_ref(void *dev) { return dev; }

/* ============================ enumerate（一律空列表）============================ */
void *udev_enumerate_new(void *ctx)
{
    fprintf(stderr, "[udev-shim] enumerate_new -> fake enum（空列表）\n");
    return &g_enum;
}
int udev_enumerate_add_match_subsystem(void *e, const char *subsystem)
{
    fprintf(stderr, "[udev-shim]   enumerate_add_match_subsystem('%s')\n",
            subsystem ? subsystem : "(null)");
    return 0;
}
int udev_enumerate_add_match_sysname(void *e, const char *sysname) { (void)e; (void)sysname; return 0; }
int udev_enumerate_add_match_property(void *e, const char *p, const char *v) { (void)e; (void)p; (void)v; return 0; }
int udev_enumerate_scan_devices(void *e)
{
    fprintf(stderr, "[udev-shim]   enumerate_scan_devices -> 0（无设备）\n");
    return 0;
}
int udev_enumerate_scan_subsystems(void *e) { (void)e; return 0; }

/* 返回 NULL = 空列表 ⇒ udev_list_entry_foreach 循环体一次都不执行 */
void *udev_enumerate_get_list_entry(void *e)
{
    fprintf(stderr, "[udev-shim]   enumerate_get_list_entry -> NULL（空）\n");
    return NULL;
}
void *udev_enumerate_unref(void *e)
{
    fprintf(stderr, "[udev-shim] enumerate_unref(%p)\n", e);
    return NULL;
}

/* list_entry：只有 get_next / get_name 会被宏 udev_list_entry_foreach 用到 */
void *udev_list_entry_get_next(void *entry) { (void)entry; return NULL; }
const char *udev_list_entry_get_name(void *entry) { (void)entry; return NULL; }
const char *udev_list_entry_get_value(void *entry) { (void)entry; return NULL; }

/* ============================ monitor（热插拔：给一个永不 ready 的 fd）============================ */
void *udev_monitor_new_from_netlink(void *ctx, const char *name)
{
    fprintf(stderr, "[udev-shim] monitor_new_from_netlink('%s') -> fake monitor\n",
            name ? name : "(null)");
    return &g_mon;
}
int udev_monitor_enable_receiving(void *m) { (void)m; return 0; }
int udev_monitor_filter_add_match_subsystem_devtype(void *m, const char *s, const char *d)
{
    (void)m; (void)s; (void)d; return 0;
}
int udev_monitor_filter_add_match_tag(void *m, const char *t) { (void)m; (void)t; return 0; }
int udev_monitor_filter_update(void *m) { (void)m; return 0; }

/* fd 指向 /dev/null：epoll 里永不 ready ⇒ 不会有假的热插拔事件 */
int udev_monitor_get_fd(void *m) { (void)m; return g_devnull(); }

void *udev_monitor_receive_device(void *m)
{
    (void)m;
    return NULL;                      /* 永远没有事件 */
}
void *udev_monitor_unref(void *m) { (void)m; return NULL; }
int udev_monitor_set_receive_buffer_size(void *m, int size) { (void)m; (void)size; return 0; }

/* ==========================================================================
 * 补全：version script（libudev_shim.map）里声明为 global 的全部符号都必须有实现。
 * 原因：map 里声明了却未实现的符号会成为 undefined ⇒ 动态链接器继续去找真 libudev
 * ⇒ 又回到"真库拿到假句柄"的老路。宁可用保守 stub，也不留给真库任何入口。
 * 这些函数在当前路径（DRM backend 启动 + libinput 空枚举）中通常不会被调用；
 * 一旦被调用，返回值也是"安全退化"（NULL / 0）而不是崩溃。
 * ========================================================================== */

void *udev_ref(void *ctx) { return ctx; }

void *udev_device_new_from_devnum(void *ctx, char type, unsigned long long devnum)
{
    (void)type; (void)devnum;
    fprintf(stderr, "[udev-shim] device_new_from_devnum -> fake dev\n");
    return &g_dev_extra;
}

void *udev_device_get_parent(void *dev) { (void)dev; return NULL; }
int udev_device_get_is_initialized(void *dev) { (void)dev; return 1; }
int udev_device_has_tag(void *dev, const char *tag) { (void)dev; (void)tag; return 0; }

int udev_enumerate_add_match_tag(void *e, const char *tag) { (void)e; (void)tag; return 0; }
int udev_enumerate_add_syspath(void *e, const char *syspath) { (void)e; (void)syspath; return 0; }
void *udev_enumerate_get_udev(void *e) { (void)e; return &g_ctx; }
void *udev_enumerate_ref(void *e) { return e; }

void *udev_list_entry_get_by_name(void *entry, const char *name) { (void)entry; (void)name; return NULL; }

int udev_monitor_filter_remove(void *m) { (void)m; return 0; }
void *udev_monitor_get_udev(void *m) { (void)m; return &g_ctx; }
void *udev_monitor_ref(void *m) { return m; }

/* udev_util_encode_string(src, dst, len)：把字符串做 udev 编码。
 * 这里退化为原样拷贝（本环境不依赖该编码做任何匹配）。 */
int udev_util_encode_string(const char *src, char *dst, size_t len)
{
    if (!src || !dst || len == 0)
        return -1;
    snprintf(dst, len, "%s", src);
    return 0;
}
