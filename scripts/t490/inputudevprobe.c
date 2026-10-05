// BUILD: dynamic
/* Query guest libudev's input enumeration and the properties produced by its rules. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/sysmacros.h>
#include <sys/types.h>

struct udev;
struct udev_device;
struct udev_enumerate;
struct udev_list_entry;

typedef struct udev *(*fn_udev_new)(void);
typedef struct udev *(*fn_udev_unref)(struct udev *);
typedef struct udev_enumerate *(*fn_enum_new)(struct udev *);
typedef int (*fn_enum_match)(struct udev_enumerate *, const char *);
typedef int (*fn_enum_scan)(struct udev_enumerate *);
typedef struct udev_list_entry *(*fn_enum_list)(struct udev_enumerate *);
typedef struct udev_enumerate *(*fn_enum_unref)(struct udev_enumerate *);
typedef struct udev_list_entry *(*fn_list_next)(struct udev_list_entry *);
typedef const char *(*fn_list_name)(struct udev_list_entry *);
typedef struct udev_device *(*fn_dev_name)(struct udev *, const char *, const char *);
typedef struct udev_device *(*fn_dev_path)(struct udev *, const char *);
typedef struct udev_device *(*fn_dev_unref)(struct udev_device *);
typedef const char *(*fn_dev_string)(struct udev_device *);
typedef const char *(*fn_dev_property)(struct udev_device *, const char *);
typedef dev_t (*fn_dev_num)(struct udev_device *);

#define LOAD(handle, symbol, type) ((type)dlsym((handle), (symbol)))

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("==== inputudevprobe: guest libudev input coldplug view ====\n");

    void *lib = dlopen("libudev.so.1", RTLD_NOW | RTLD_GLOBAL);
    if (!lib)
        lib = dlopen("/usr/lib/libudev.so.1", RTLD_NOW | RTLD_GLOBAL);
    if (!lib) {
        printf("[INPUT_UDEV] dlopen FAILED: %s\n", dlerror());
        printf("[INPUT_UDEV_EXIT] 5 verdict=LIB_FAIL\n");
        return 5;
    }

    fn_udev_new udev_new = LOAD(lib, "udev_new", fn_udev_new);
    fn_udev_unref udev_unref = LOAD(lib, "udev_unref", fn_udev_unref);
    fn_enum_new enum_new = LOAD(lib, "udev_enumerate_new", fn_enum_new);
    fn_enum_match enum_match = LOAD(lib, "udev_enumerate_add_match_subsystem", fn_enum_match);
    fn_enum_scan enum_scan = LOAD(lib, "udev_enumerate_scan_devices", fn_enum_scan);
    fn_enum_list enum_list = LOAD(lib, "udev_enumerate_get_list_entry", fn_enum_list);
    fn_enum_unref enum_unref = LOAD(lib, "udev_enumerate_unref", fn_enum_unref);
    fn_list_next list_next = LOAD(lib, "udev_list_entry_get_next", fn_list_next);
    fn_list_name list_name = LOAD(lib, "udev_list_entry_get_name", fn_list_name);
    fn_dev_name dev_name = LOAD(lib, "udev_device_new_from_subsystem_sysname", fn_dev_name);
    fn_dev_path dev_path = LOAD(lib, "udev_device_new_from_syspath", fn_dev_path);
    fn_dev_unref dev_unref = LOAD(lib, "udev_device_unref", fn_dev_unref);
    fn_dev_string dev_sysname = LOAD(lib, "udev_device_get_sysname", fn_dev_string);
    fn_dev_string devnode = LOAD(lib, "udev_device_get_devnode", fn_dev_string);
    fn_dev_property property = LOAD(lib, "udev_device_get_property_value", fn_dev_property);
    fn_dev_num devnum = LOAD(lib, "udev_device_get_devnum", fn_dev_num);

    if (!udev_new || !enum_new || !enum_match || !enum_scan || !enum_list ||
        !list_next || !list_name || !dev_name || !dev_path || !dev_sysname || !devnode ||
        !devnum || !property) {
        printf("[INPUT_UDEV] required libudev ABI symbol is missing\n");
        printf("[INPUT_UDEV_EXIT] 5 verdict=ABI_FAIL\n");
        return 5;
    }

    struct udev *udev = udev_new();
    struct udev_enumerate *enumerate = udev ? enum_new(udev) : NULL;
    int match_rc = enumerate ? enum_match(enumerate, "input") : -1;
    int scan_rc = (enumerate && match_rc >= 0) ? enum_scan(enumerate) : -1;
    if (!enumerate || match_rc < 0 || scan_rc < 0) {
        printf("[INPUT_UDEV] enumerate input subsystem FAILED match_rc=%d scan_rc=%d errno=%d\n",
               match_rc, scan_rc, errno);
        if (enumerate && enum_unref) enum_unref(enumerate);
        if (udev && udev_unref) udev_unref(udev);
        printf("[INPUT_UDEV_EXIT] 3 verdict=ENUMERATE_FAIL\n");
        return 3;
    }
    printf("[INPUT_UDEV] enumerate input subsystem match_rc=%d scan_rc=%d\n",
           match_rc, scan_rc);

    int direct_count = 0;
    int bad_device = 0;
    for (int index = 0; index < 2; index++) {
        char sysname[16];
        snprintf(sysname, sizeof(sysname), "event%d", index);
        struct udev_device *device = dev_name(udev, "input", sysname);
        if (!device) {
            printf("[INPUT_UDEV] by-name sysname=%s FAILED\n", sysname);
            bad_device = 1;
            continue;
        }
        const char *node = devnode(device);
        dev_t number = devnum(device);
        const char *is_input = property(device, "ID_INPUT");
        const char *is_seat = property(device, "ID_SEAT");
        const char *is_keyboard = property(device, "ID_INPUT_KEYBOARD");
        const char *is_mouse = property(device, "ID_INPUT_MOUSE");
        printf("[INPUT_UDEV] by-name sysname=%s devnode=%s devnum=%u:%u"
               " ID_INPUT=%s ID_SEAT=%s KEYBOARD=%s MOUSE=%s\n",
               sysname, node ? node : "(null)",
               (unsigned)major(number), (unsigned)minor(number),
               is_input ? is_input : "(null)",
               is_seat ? is_seat : "(null)",
               is_keyboard ? is_keyboard : "(null)",
               is_mouse ? is_mouse : "(null)");
        if (node && major(number) == 13 && minor(number) == 64U + (unsigned)index)
            direct_count++;
        if (!is_input || strcmp(is_input, "1") != 0)
            bad_device = 1;
        if (dev_unref) dev_unref(device);
    }

    int event_count = 0;
    for (struct udev_list_entry *entry = enum_list(enumerate); entry;
         entry = list_next(entry)) {
        const char *syspath = list_name(entry);
        if (!syspath) continue;
        struct udev_device *device = dev_path(udev, syspath);
        if (!device) {
            printf("[INPUT_UDEV] list syspath=%s device=FAILED errno=%d\n", syspath, errno);
            continue;
        }
        const char *sysname = dev_sysname(device);
        printf("[INPUT_UDEV] list syspath=%s sysname=%s\n",
               syspath, sysname ? sysname : "(null)");
        printf("[INPUT_UDEV] list syspath=%s sysname=%s\n",
               syspath, sysname ? sysname : "(null)");
        if (sysname && strncmp(sysname, "event", 5) == 0) {
            const char *node = devnode(device);
            dev_t number = devnum(device);
            const char *is_input = property(device, "ID_INPUT");
            const char *is_keyboard = property(device, "ID_INPUT_KEYBOARD");
            const char *is_mouse = property(device, "ID_INPUT_MOUSE");
            printf("[INPUT_UDEV] sysname=%s syspath=%s devnode=%s devnum=%u:%u"
                   " ID_INPUT=%s KEYBOARD=%s MOUSE=%s\n",
                   sysname, syspath, node ? node : "(null)",
                   (unsigned)major(number), (unsigned)minor(number),
                   is_input ? is_input : "(null)",
                   is_keyboard ? is_keyboard : "(null)",
                   is_mouse ? is_mouse : "(null)");
            event_count++;
            if (!node || major(number) != 13 || minor(number) < 64 ||
                !is_input || strcmp(is_input, "1") != 0)
                bad_device = 1;
        }
        if (dev_unref) dev_unref(device);
    }

    if (enum_unref) enum_unref(enumerate);
    if (udev_unref) udev_unref(udev);
    printf("[INPUT_UDEV] by_name_count=%d event_count=%d\n", direct_count, event_count);
    int rc = direct_count >= 2 && event_count >= 2 && !bad_device ? 0 : 3;
    printf("[INPUT_UDEV_EXIT] %d verdict=%s\n", rc, rc == 0 ? "INPUT_UDEV_OK" : "INPUT_UDEV_FAIL");
    return rc;
}
