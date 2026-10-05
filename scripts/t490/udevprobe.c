// BUILD: dynamic
/* udevprobe.c —— 用 guest **真实** libudev 验证内核 sysfs 投射（阶段 2.3 的判据工具）
 *
 * 为什么必须用真实 libudev
 * ------------------------
 * 阶段 2 的验收条件是"标准 libudev 正常工作，无 shim、无伪 sysfs"。此前三轮能走到
 * "using /dev/dri/card0" 靠的是 LD_PRELOAD 的 libudev shim（用户态伪造）。要把它拆掉，
 * 判据必须是 **guest 自带的 libudev**（本镜像为 libudev.so.1.6.3 = eudev）
 * 走它自己的代码路径去读**内核提供的** /sys —— 而不是我们再手写一套"预期行为"。
 *
 * 为什么手写函数声明而不是 #include <libudev.h>
 * ------------------------------------------
 * guest 镜像只装了运行库（没有 eudev-dev）。libudev 的公开 ABI 极小且稳定
 * （opaque 指针 + 一组函数），手写声明可避免引入与镜像不一致的 -dev 包；
 * 声明逐条对照 eudev 3.2.x 的 libudev.h。
 *
 * 为什么 dlopen 而不是链接期 -ludev
 * -------------------------------
 * 同 drmstdprobe：guest 的 .so 可能含 `.relr.dyn`（DT_RELR），本项目交叉工具链的 ld
 * 不认识该段类型。dlopen 绕过链接期，且 dladdr 能直接报出"实际加载了哪个库"。
 *
 * 检查项（对齐 Weston 14 backend-drm 的真实调用形态）
 * ------------------------------------------------
 *   1. udev_new()
 *   2. udev_device_new_from_subsystem_sysname(udev, "drm", "card0")
 *      ← 这正是 Weston 拿到 `--drm-device=card0` 之后的第一跳
 *      → 打印 syspath / sysname / devnode / devnum / subsystem / devtype / uevent 属性
 *      → **硬判据**：devnode == /dev/dri/card0，devnum == 226:0
 *   3. 枚举路径：udev_enumerate_new + add_match_subsystem("drm") + scan_devices + 列表
 *      ← Weston 不指定设备名时走这条
 *   4. udev_device_new_from_devnum('c', makedev(226,0))：与 node 路径互相印证
 *   5. udev_monitor_new_from_netlink("udev")：热插拔通道（失败只告警，不判失败）
 *
 * 输出机器行：[UDEV] ... / [UDEV_EXIT] <code> verdict=<UDEV_OK|...>
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <dlfcn.h>
#include <sys/types.h>
#include <sys/sysmacros.h>

/* ---- libudev 的公开 ABI（手写声明，opaque 指针）---- */
struct udev;
struct udev_list_entry;
struct udev_device;
struct udev_enumerate;
struct udev_monitor;

typedef struct udev *(*fn_udev_new)(void);
typedef struct udev *(*fn_udev_unref)(struct udev *);
typedef struct udev_device *(*fn_dev_new_subsys_sysname)(struct udev *, const char *, const char *);
typedef struct udev_device *(*fn_dev_new_from_syspath)(struct udev *, const char *);
typedef struct udev_device *(*fn_dev_new_from_devnum)(struct udev *, char, dev_t);
typedef const char *(*fn_dev_get_str1)(struct udev_device *);
typedef dev_t (*fn_dev_get_devnum)(struct udev_device *);
typedef const char *(*fn_dev_get_attr)(struct udev_device *, const char *);
typedef const char *(*fn_dev_get_prop)(struct udev_device *, const char *);
typedef struct udev_device *(*fn_dev_unref)(struct udev_device *);
typedef struct udev_enumerate *(*fn_enum_new)(struct udev *);
typedef int (*fn_enum_add_match_subsystem)(struct udev_enumerate *, const char *);
typedef int (*fn_enum_scan_devices)(struct udev_enumerate *);
typedef struct udev_list_entry *(*fn_enum_get_list_entry)(struct udev_enumerate *);
typedef struct udev_enumerate *(*fn_enum_unref)(struct udev_enumerate *);
typedef struct udev_list_entry *(*fn_list_get_next)(struct udev_list_entry *);
typedef const char *(*fn_list_get_name)(struct udev_list_entry *);
typedef struct udev_monitor *(*fn_mon_new_from_netlink)(struct udev *, const char *);
typedef int (*fn_mon_enable_receiving)(struct udev_monitor *);
typedef int (*fn_mon_get_fd)(struct udev_monitor *);
typedef struct udev_monitor *(*fn_mon_unref)(struct udev_monitor *);

#define SYM(h, name) dlsym(h, name)

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);

    printf("==== udevprobe: 真实 libudev 对内核 sysfs 的可用性（阶段2.3）====\n");

    void *h = dlopen("libudev.so.1", RTLD_NOW | RTLD_GLOBAL);
    if (!h)
        h = dlopen("/usr/lib/libudev.so.1", RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        printf("[UDEV] dlopen(libudev.so.1) FAILED: %s\n", dlerror());
        printf("[UDEV_EXIT] 5 verdict=LIB_FAIL\n");
        return 5;
    }
    {
        Dl_info dli;
        if (dladdr((void *)h, &dli) && dli.dli_fname)
            printf("[UDEV] libudev 实际加载: %s\n", dli.dli_fname);
    }

    fn_udev_new                 p_new        = (fn_udev_new)                SYM(h, "udev_new");
    fn_udev_unref               p_unref      = (fn_udev_unref)              SYM(h, "udev_unref");
    fn_dev_new_subsys_sysname   p_by_name    = (fn_dev_new_subsys_sysname)  SYM(h, "udev_device_new_from_subsystem_sysname");
    fn_dev_new_from_syspath     p_by_path    = (fn_dev_new_from_syspath)    SYM(h, "udev_device_new_from_syspath");
    fn_dev_new_from_devnum      p_by_devnum  = (fn_dev_new_from_devnum)     SYM(h, "udev_device_new_from_devnum");
    fn_dev_get_str1             p_get_syspath= (fn_dev_get_str1)            SYM(h, "udev_device_get_syspath");
    fn_dev_get_str1             p_get_sysname= (fn_dev_get_str1)            SYM(h, "udev_device_get_sysname");
    fn_dev_get_str1             p_get_devnode= (fn_dev_get_str1)            SYM(h, "udev_device_get_devnode");
    fn_dev_get_str1             p_get_subsys = (fn_dev_get_str1)            SYM(h, "udev_device_get_subsystem");
    fn_dev_get_str1             p_get_devtype= (fn_dev_get_str1)            SYM(h, "udev_device_get_devtype");
    fn_dev_get_devnum           p_get_devnum = (fn_dev_get_devnum)          SYM(h, "udev_device_get_devnum");
    fn_dev_get_attr             p_get_attr   = (fn_dev_get_attr)            SYM(h, "udev_device_get_sysattr_value");
    fn_dev_get_prop             p_get_prop   = (fn_dev_get_prop)            SYM(h, "udev_device_get_property_value");
    fn_dev_unref                p_dev_unref  = (fn_dev_unref)               SYM(h, "udev_device_unref");
    fn_enum_new                 p_enum_new   = (fn_enum_new)                SYM(h, "udev_enumerate_new");
    fn_enum_add_match_subsystem p_enum_match = (fn_enum_add_match_subsystem) SYM(h, "udev_enumerate_add_match_subsystem");
    fn_enum_scan_devices        p_enum_scan  = (fn_enum_scan_devices)       SYM(h, "udev_enumerate_scan_devices");
    fn_enum_get_list_entry      p_enum_list  = (fn_enum_get_list_entry)     SYM(h, "udev_enumerate_get_list_entry");
    fn_enum_unref               p_enum_unref = (fn_enum_unref)              SYM(h, "udev_enumerate_unref");
    fn_list_get_next            p_list_next  = (fn_list_get_next)           SYM(h, "udev_list_entry_get_next");
    fn_list_get_name            p_list_name  = (fn_list_get_name)           SYM(h, "udev_list_entry_get_name");
    fn_mon_new_from_netlink     p_mon_new    = (fn_mon_new_from_netlink)    SYM(h, "udev_monitor_new_from_netlink");
    fn_mon_unref                p_mon_unref  = (fn_mon_unref)               SYM(h, "udev_monitor_unref");

    if (!p_new || !p_by_name || !p_get_devnode || !p_get_devnum || !p_enum_new) {
        printf("[UDEV] 关键符号缺失（new=%p by_name=%p devnode=%p devnum=%p enum=%p）\n",
               (void *)p_new, (void *)p_by_name, (void *)p_get_devnode,
               (void *)p_get_devnum, (void *)p_enum_new);
        printf("[UDEV_EXIT] 5 verdict=LIB_FAIL\n");
        return 5;
    }

    struct udev *u = p_new();
    if (!u) {
        printf("[UDEV] udev_new() FAILED\n");
        printf("[UDEV_EXIT] 5 verdict=UDEV_NEW_FAIL\n");
        return 5;
    }
    printf("[UDEV] udev_new() OK\n");

    int exit_code = 0;

    /* ---- 2) Weston 的第一跳：按子系统 + sysname 取设备 ---- */
    struct udev_device *d = p_by_name(u, "drm", "card0");
    if (!d) {
        printf("[UDEV] udev_device_new_from_subsystem_sysname(\"drm\",\"card0\") FAILED"
               "  ← ★ 内核 sysfs 投射不足（需要 /sys/class/drm/card0/uevent 等）\n");
        exit_code = 3;
    } else {
        const char *sp  = p_get_syspath ? p_get_syspath(d) : NULL;
        const char *sn  = p_get_sysname ? p_get_sysname(d) : NULL;
        const char *dn  = p_get_devnode ? p_get_devnode(d) : NULL;
        const char *ss  = p_get_subsys  ? p_get_subsys(d)  : NULL;
        const char *dt  = p_get_devtype ? p_get_devtype(d) : NULL;
        dev_t dv = p_get_devnum ? p_get_devnum(d) : 0;
        printf("[UDEV] by-name OK: syspath=%s sysname=%s\n",
               sp ? sp : "(null)", sn ? sn : "(null)");
        printf("[UDEV]   subsystem=%s devtype=%s\n",
               ss ? ss : "(null)", dt ? dt : "(null)");
        printf("[UDEV]   devnode=%s  devnum=%u:%u\n",
               dn ? dn : "(null)", (unsigned)major(dv), (unsigned)minor(dv));
        if (p_get_attr) {
            const char *ue = p_get_attr(d, "uevent");
            printf("[UDEV]   sysattr uevent=%s\n", ue ? "(present)" : "(missing)");
        }
        if (p_get_prop) {
            const char *devname = p_get_prop(d, "DEVNAME");
            const char *devtype = p_get_prop(d, "DEVTYPE");
            printf("[UDEV]   prop DEVNAME=%s DEVTYPE=%s\n",
                   devname ? devname : "(null)", devtype ? devtype : "(null)");
        }
        /* 硬判据：Weston 接下来就是拿 devnode 去 open */
        if (!dn || strcmp(dn, "/dev/dri/card0") != 0) {
            printf("[UDEV] !! devnode 不是 /dev/dri/card0\n");
            exit_code = 3;
        }
        if (dv != makedev(226, 0)) {
            printf("[UDEV] !! devnum 不是 226:0\n");
            exit_code = 3;
        }
        if (p_dev_unref) p_dev_unref(d);
    }

    /* ---- 2b) 另一条等价入口：按 syspath 直接取设备 ----
     * Weston 的枚举路径拿到 list entry 的 name（就是 syspath）后走这里；
     * 用同一条路径交叉验证 by-name 的结果。 */
    if (p_by_path) {
        struct udev_device *dp = p_by_path(u, "/sys/class/drm/card0");
        if (!dp) {
            printf("[UDEV] udev_device_new_from_syspath(\"/sys/class/drm/card0\") FAILED\n");
        } else {
            const char *dn2 = p_get_devnode ? p_get_devnode(dp) : NULL;
            printf("[UDEV] by-syspath OK: devnode=%s\n", dn2 ? dn2 : "(null)");
            if (p_dev_unref) p_dev_unref(dp);
        }
    }

    /* ---- 3) 枚举路径（Weston 未指定 --drm-device 时走这条）---- */
    struct udev_enumerate *e = p_enum_new(u);
    if (e) {
        if (p_enum_match) p_enum_match(e, "drm");
        int scanned = p_enum_scan ? p_enum_scan(e) : -1;
        printf("[UDEV] enumerate: scan_devices rc=%d\n", scanned);
        int n = 0;
        struct udev_list_entry *le = p_enum_list ? p_enum_list(e) : NULL;
        while (le && p_list_next && p_list_name) {
            const char *nm = p_list_name(le);
            printf("[UDEV]   entry[%d]=%s\n", n++, nm ? nm : "(null)");
            le = p_list_next(le);
            if (n > 12) break;
        }
        if (n == 0) {
            printf("[UDEV] !! drm 子系统枚举为空（Weston 找不到设备时会退化为无输出）\n");
        }
        if (p_enum_unref) p_enum_unref(e);
    } else {
        printf("[UDEV] udev_enumerate_new FAILED（不影响 by-name 路径）\n");
    }

    /* ---- 4) 按设备号反查（与 /dev/dri/card0 互相印证）---- */
    if (p_by_devnum) {
        struct udev_device *d2 = p_by_devnum(u, 'c', makedev(226, 0));
        if (!d2) {
            printf("[UDEV] udev_device_new_from_devnum('c',226:0) FAILED"
                   "  （需要 /sys/dev/char/226:0 链接）\n");
        } else {
            const char *sp2 = p_get_syspath ? p_get_syspath(d2) : NULL;
            printf("[UDEV] by-devnum OK: syspath=%s\n", sp2 ? sp2 : "(null)");
            if (p_dev_unref) p_dev_unref(d2);
        }
    }

    /* ---- 5) 热插拔通道（信息项）---- */
    if (p_mon_new) {
        struct udev_monitor *m = p_mon_new(u, "udev");
        if (m) {
            printf("[UDEV] monitor_new_from_netlink OK\n");
            if (p_mon_unref) p_mon_unref(m);
        } else {
            printf("[UDEV] monitor_new_from_netlink FAILED（热插拔不可用，本轮不判失败）\n");
        }
    }

    if (p_unref) p_unref(u);
    printf("[UDEV_EXIT] %d verdict=%s\n", exit_code, exit_code == 0 ? "UDEV_OK" : "UDEV_FAIL");
    printf("==== udevprobe done ====\n");
    return exit_code;
}
