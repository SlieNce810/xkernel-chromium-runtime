/* drmprobe.c v2 — x-kernel DRM 通路探针（含 libdrm 能力测试）
 *
 * v1：验证 open / DRM ioctl 通路（已证明 FULL_OK）
 * v2 新增：dlopen guest 内的 libdrm.so.2，测试 weston 真正依赖的枚举/查询能力：
 *   - drmGetDevices2()   ← weston 用它发现 DRM 设备（依赖 sysfs，x-kernel 可能不支持）
 *   - drmGetVersion()    ← 版本查询
 *   - drmGetDeviceFromDevId / drmGetPrimaryDeviceNameFromFd2
 *
 * 编译：aarch64-linux-musl-gcc -static -Os -o drmprobe drmprobe.c
 */
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <stdlib.h>
#include <dirent.h>
#include <dlfcn.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>

#define DEV0 "/dev/dri/card0"

/* ---- 手工 DRM ioctl 定义 ---- */
struct drm_version {
    int version_major, version_minor, version_patchlevel;
    size_t name_len; char *name;
    size_t date_len; char *date;
    size_t desc_len; char *desc;
};
#define DRM_IOCTL_BASE 'd'
#define DRM_IOWR(nr, type) _IOWR(DRM_IOCTL_BASE, nr, type)
#define DRM_IOCTL_VERSION  DRM_IOWR(0x00, struct drm_version)

static void probe_dev(const char *path)
{
    struct stat st;
    printf("\n---- %s ----\n", path);
    if (stat(path, &st) != 0) {
        printf("stat() FAIL errno=%d (%s)\n", errno, strerror(errno));
        return;
    }
    printf("stat OK rdev=%u:%u\n", major(st.st_rdev), minor(st.st_rdev));

    errno = 0;
    int fd = open(path, O_RDWR | O_CLOEXEC);
    printf("open(RDWR|CLOEXEC) -> %d errno=%d (%s)\n", fd, errno, strerror(errno));
    if (fd < 0) return;

    char name[64] = {0}, date[64] = {0}, desc[128] = {0};
    struct drm_version v = {0};
    v.name = name; v.name_len = sizeof name;
    v.date = date; v.date_len = sizeof date;
    v.desc = desc; v.desc_len = sizeof desc;
    errno = 0;
    int r = ioctl(fd, DRM_IOCTL_VERSION, &v);
    printf("ioctl(VERSION) -> %d errno=%d (%s)", r, errno, strerror(errno));
    if (r == 0) printf(" driver='%s' %d.%d.%d", name, v.version_major, v.version_minor, v.version_patchlevel);
    printf("\n");
    close(fd);
}

/* ---- libdrm 能力测试（weston 的设备发现路径）---- */
static void probe_libdrm(void)
{
    printf("\n---- libdrm 能力测试 ----\n");
    void *h = dlopen("libdrm.so.2", RTLD_NOW);
    if (!h) h = dlopen("libdrm.so", RTLD_NOW);
    if (!h) { printf("dlopen(libdrm.so.2) FAILED: %s\n", dlerror()); return; }
    printf("dlopen(libdrm.so.2) OK\n");

    /* 1) drmGetVersion(fd) —— weston 用它校验设备 */
    void *(*fn_getver)(int) = dlsym(h, "drmGetVersion");
    void (*fn_freever)(void *) = dlsym(h, "drmFreeVersion");
    printf("dlsym drmGetVersion=%p drmFreeVersion=%p\n",
           (void *)fn_getver, (void *)fn_freever);
    if (fn_getver) {
        int fd = open(DEV0, O_RDWR | O_CLOEXEC);
        if (fd < 0) {
            printf("  (open %s FAILED errno=%d)\n", DEV0, errno);
        } else {
            errno = 0;
            void *ver = fn_getver(fd);
            printf("  drmGetVersion(fd=%d) -> %p errno=%d (%s)\n", fd, ver, errno, strerror(errno));
            if (ver) {
                /* struct drmVersion { int major, minor, patchlevel; ... char *name; ... } */
                int major = ((int *)ver)[0], minor = ((int *)ver)[1];
                printf("  version: %d.%d\n", major, minor);
                if (fn_freever) fn_freever(ver);
            }
            close(fd);
        }
    }

    /* 2) drmGetDevices2 —— weston 的设备枚举（依赖 sysfs） */
    int (*fn_getdevices2)(int, void **, int) = dlsym(h, "drmGetDevices2");
    void (*fn_freedevices)(int, void **) = dlsym(h, "drmFreeDevices");
    printf("dlsym drmGetDevices2=%p drmFreeDevices=%p\n",
           (void *)fn_getdevices2, (void *)fn_freedevices);
    if (fn_getdevices2) {
        void *devs[8];
        memset(devs, 0, sizeof devs);
        errno = 0;
        int n = fn_getdevices2(0, devs, 8);
        printf("  drmGetDevices2(0, buf, 8) -> %d errno=%d (%s)\n", n, errno, strerror(errno));
        if (n > 0 && fn_freedevices) fn_freedevices(n, devs);
    }

    /* 3) drmGetDeviceNameFromFd2 / drmGetPrimaryDeviceNameFromFd2 */
    char *(*fn_namefromfd)(int) = dlsym(h, "drmGetDeviceNameFromFd2");
    if (fn_namefromfd) {
        int fd = open(DEV0, O_RDWR | O_CLOEXEC);
        if (fd >= 0) {
            errno = 0;
            char *nm = fn_namefromfd(fd);
            printf("  drmGetDeviceNameFromFd2(fd=%d) -> %s errno=%d\n", fd, nm ? nm : "(null)", errno);
            close(fd);
        }
    } else {
        printf("  dlsym drmGetDeviceNameFromFd2 NOT FOUND\n");
    }

    /* 4) libdrm 是否依赖 sysfs —— 直接测 sysfs 可读性 */
    printf("  access(/sys/class/drm) -> %d errno=%d\n",
           access("/sys/class/drm", F_OK), errno);
    printf("  access(/dev/dri) -> %d errno=%d\n",
           access("/dev/dri", F_OK), errno);
}

/* ---- process_device 检查链模拟 + libudev 探针 ---- */
static void probe_chain(void)
{
    struct stat sbuf;
    printf("\n---- process_device 检查链模拟 ----\n");

    int r = stat(DEV0, &sbuf);
    printf("1. stat(%s) -> %d ischr=%d mode=%o rdev=%u:%u\n", DEV0, r,
           r == 0 ? (int)S_ISCHR(sbuf.st_mode) : -1,
           r == 0 ? (unsigned)sbuf.st_mode : 0u,
           r == 0 ? (unsigned)major(sbuf.st_rdev) : 0u,
           r == 0 ? (unsigned)minor(sbuf.st_rdev) : 0u);

    char link[256] = {0};
    errno = 0;
    int rl = readlink("/sys/dev/char/226:0/device/subsystem", link, sizeof link - 1);
    printf("2. readlink(subsystem) -> %d errno=%d [%s]\n", rl, errno, rl > 0 ? link : "?");
    const char *seg = rl > 0 ? strrchr(link, '/') : NULL;
    printf("   last seg: %s (faux match: %d)\n", seg ? seg : "(none)",
           seg ? (int)(strncmp(seg, "/faux", 5) == 0) : -1);

    errno = 0;
    char *rp = realpath("/sys/dev/char/226:0/device", NULL);
    printf("3. realpath(device) -> %s errno=%d\n", rp ? rp : "NULL", errno);
    free(rp);

    errno = 0;
    DIR *d = opendir("/dev/dri");
    printf("4. opendir(/dev/dri) -> %p errno=%d\n", (void *)d, errno);
    if (d) {
        struct dirent *ent;
        while ((ent = readdir(d)) != NULL)
            printf("   entry: %s d_type=%d\n", ent->d_name, (int)ent->d_type);
        closedir(d);
    } else {
        printf("   opendir FAILED: %s\n", strerror(errno));
    }
}

static void probe_libudev(void)
{
    printf("\n---- libudev 探针（weston 的设备查询路径）----\n");
    void *h = dlopen("libudev.so.1", RTLD_NOW);
    if (!h) { printf("dlopen(libudev.so.1) FAILED: %s\n", dlerror()); return; }
    printf("dlopen(libudev.so.1) OK\n");

    void *(*udev_new)(void) = dlsym(h, "udev_new");
    void *(*new_from_subsys)(void *, const char *, const char *) =
        dlsym(h, "udev_device_new_from_subsystem_sysname");
    const char *(*get_devnode)(void *) = dlsym(h, "udev_device_get_devnode");
    const char *(*get_sysnum)(void *) = dlsym(h, "udev_device_get_sysnum");
    unsigned long long (*get_devnum)(void *) = dlsym(h, "udev_device_get_devnum");
    const char *(*get_syspath)(void *) = dlsym(h, "udev_device_get_syspath");
    void (*dev_unref)(void *) = dlsym(h, "udev_device_unref");
    void (*udev_unref)(void *) = dlsym(h, "udev_unref");

    if (!udev_new || !new_from_subsys) {
        printf("dlsym udev_new/new_from_subsystem_sysname FAILED\n");
        return;
    }

    void *udev = udev_new();
    printf("udev_new -> %p\n", udev);
    if (!udev) return;

    errno = 0;
    void *dev = new_from_subsys(udev, "drm", "card0");
    printf("new_from_subsystem_sysname(drm, card0) -> %p errno=%d (%s)\n",
           dev, errno, strerror(errno));
    if (dev) {
        if (get_devnode) printf("  devnode: %s\n", get_devnode(dev));
        if (get_sysnum)  printf("  sysnum:  %s\n", get_sysnum(dev));
        if (get_devnum)  printf("  devnum:  %llu\n", get_devnum(dev));
        if (get_syspath) printf("  syspath: %s\n", get_syspath(dev));
        if (dev_unref) dev_unref(dev);
    } else {
        printf("VERDICT: libudev 查询失败 -> weston 在此阻塞\n");
    }
    if (udev_unref) udev_unref(udev);
}

int main(void)
{
    printf("==== drmprobe v3: DRM 通路 + libdrm 能力 + libudev 探针 ====\n");
    probe_dev(DEV0);
    probe_dev("/dev/fb0");
    probe_libdrm();
    probe_chain();
    probe_libudev();
    printf("\n==== drmprobe done ====\n");
    return 0;
}
