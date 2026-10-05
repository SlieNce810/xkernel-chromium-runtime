// BUILD: dynamic
/* Compare libudev initialization state by name, syspath, and dev_t. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/sysmacros.h>

struct udev;
struct udev_device;
typedef struct udev *(*fn_udev_new)(void);
typedef struct udev *(*fn_udev_unref)(struct udev *);
typedef struct udev_device *(*fn_dev_name)(struct udev *, const char *, const char *);
typedef struct udev_device *(*fn_dev_num)(struct udev *, char, dev_t);
typedef struct udev_device *(*fn_dev_unref)(struct udev_device *);
typedef const char *(*fn_dev_string)(struct udev_device *);
typedef const char *(*fn_dev_property)(struct udev_device *, const char *);
typedef dev_t (*fn_dev_rdev)(struct udev_device *);
typedef int (*fn_dev_initialized)(struct udev_device *);

#define LOAD(handle, symbol, type) ((type)dlsym((handle), (symbol)))

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    void *lib = dlopen("libudev.so.1", RTLD_NOW | RTLD_GLOBAL);
    if (!lib) {
        printf("[UDEVINIT] dlopen failed: %s\n", dlerror());
        return 2;
    }
    fn_udev_new udev_new = LOAD(lib, "udev_new", fn_udev_new);
    fn_udev_unref udev_unref = LOAD(lib, "udev_unref", fn_udev_unref);
    fn_dev_name dev_by_name = LOAD(lib, "udev_device_new_from_subsystem_sysname", fn_dev_name);
    fn_dev_num dev_by_num = LOAD(lib, "udev_device_new_from_devnum", fn_dev_num);
    fn_dev_unref dev_unref = LOAD(lib, "udev_device_unref", fn_dev_unref);
    fn_dev_string get_sysname = LOAD(lib, "udev_device_get_sysname", fn_dev_string);
    fn_dev_string get_devnode = LOAD(lib, "udev_device_get_devnode", fn_dev_string);
    fn_dev_string get_syspath = LOAD(lib, "udev_device_get_syspath", fn_dev_string);
    fn_dev_property get_property = LOAD(lib, "udev_device_get_property_value", fn_dev_property);
    fn_dev_rdev get_devnum = LOAD(lib, "udev_device_get_devnum", fn_dev_rdev);
    fn_dev_initialized is_initialized = LOAD(lib, "udev_device_get_is_initialized", fn_dev_initialized);
    if (!udev_new || !udev_unref || !dev_by_name || !dev_by_num || !dev_unref ||
        !get_sysname || !get_devnode || !get_syspath || !get_property || !get_devnum || !is_initialized) {
        printf("[UDEVINIT] required libudev symbol missing\n");
        return 3;
    }

    struct udev *udev = udev_new();
    if (!udev) return 4;
    for (int index = 0; index < 2; index++) {
        char name[16];
        char devnode[32];
        snprintf(name, sizeof(name), "event%d", index);
        snprintf(devnode, sizeof(devnode), "/dev/input/event%d", index);
        dev_t expected = makedev(13, 64 + index);
        struct stat st = {0};
        int stat_rc = stat(devnode, &st);
        printf("[UDEVINIT] stat path=%s rc=%d mode=%#o rdev=%u:%u\n",
               devnode, stat_rc, stat_rc == 0 ? (unsigned)st.st_mode : 0,
               stat_rc == 0 ? (unsigned)major(st.st_rdev) : 0,
               stat_rc == 0 ? (unsigned)minor(st.st_rdev) : 0);
        struct udev_device *by_name = dev_by_name(udev, "input", name);
        struct udev_device *by_num = dev_by_num(udev, 'c', expected);
        struct udev_device *items[2] = { by_name, by_num };
        const char *labels[2] = { "by-name", "by-devnum" };
        for (int which = 0; which < 2; which++) {
            struct udev_device *device = items[which];
            if (!device) {
                printf("[UDEVINIT] %s %s = null\n", labels[which], name);
                continue;
            }
            dev_t number = get_devnum(device);
            printf("[UDEVINIT] %s want=%s sysname=%s init=%d devnode=%s devnum=%u:%u syspath=%s ID_INPUT=%s ID_SEAT=%s\n",
                   labels[which], name,
                   get_sysname(device) ? get_sysname(device) : "(null)",
                   is_initialized(device),
                   get_devnode(device) ? get_devnode(device) : "(null)",
                   (unsigned)major(number), (unsigned)minor(number),
                   get_syspath(device) ? get_syspath(device) : "(null)",
                   get_property(device, "ID_INPUT") ? get_property(device, "ID_INPUT") : "(null)",
                   get_property(device, "ID_SEAT") ? get_property(device, "ID_SEAT") : "(null)");
            dev_unref(device);
        }
    }
    udev_unref(udev);
    puts("[UDEVINIT_EXIT] done");
    return 0;
}
