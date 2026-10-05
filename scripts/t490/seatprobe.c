/* Exercise libseat's real seatd open-device path and report the returned fd. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define IOC_NRBITS 8
#define IOC_TYPEBITS 8
#define IOC_SIZEBITS 14
#define IOC_DIRBITS 2
#define IOC_NRSHIFT 0
#define IOC_TYPESHIFT (IOC_NRSHIFT + IOC_NRBITS)
#define IOC_SIZESHIFT (IOC_TYPESHIFT + IOC_TYPEBITS)
#define IOC_DIRSHIFT (IOC_SIZESHIFT + IOC_SIZEBITS)
#define IOC_READ 2U
#define IOC(dir, type, nr, size) \
    ((unsigned long)(((dir) << IOC_DIRSHIFT) | ((type) << IOC_TYPESHIFT) | \
                     ((nr) << IOC_NRSHIFT) | ((size) << IOC_SIZESHIFT)))
#ifndef _IOR
#define _IOR(type, nr, size) IOC(IOC_READ, (type), (nr), sizeof(size))
#endif
#define EVIOCGID _IOR('E', 0x02, struct input_id)
#define EVIOCGNAME(len) IOC(IOC_READ, 'E', 0x06, (len))

struct input_id {
    unsigned short bustype;
    unsigned short vendor;
    unsigned short product;
    unsigned short version;
};

struct libseat;
struct libseat_seat_listener {
    void (*enable_seat)(struct libseat *seat, void *userdata);
    void (*disable_seat)(struct libseat *seat, void *userdata);
};

typedef struct libseat *(*libseat_open_seat_fn)(const struct libseat_seat_listener *, void *);
typedef int (*libseat_open_device_fn)(struct libseat *, const char *, int *);
typedef int (*libseat_close_device_fn)(struct libseat *, int);
typedef int (*libseat_close_seat_fn)(struct libseat *);
typedef void (*libseat_set_log_level_fn)(int);

static void seat_enabled(struct libseat *seat, void *userdata)
{
    (void)seat;
    (void)userdata;
    puts("[SEATPROBE] seat enabled");
}

static void seat_disabled(struct libseat *seat, void *userdata)
{
    (void)seat;
    (void)userdata;
    puts("[SEATPROBE] seat disabled");
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    void *library = dlopen("libseat.so.1", RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        printf("[SEATPROBE] dlopen failed: %s\n", dlerror());
        return 2;
    }
    libseat_open_seat_fn open_seat = (libseat_open_seat_fn)dlsym(library, "libseat_open_seat");
    libseat_open_device_fn open_device = (libseat_open_device_fn)dlsym(library, "libseat_open_device");
    libseat_close_device_fn close_device = (libseat_close_device_fn)dlsym(library, "libseat_close_device");
    libseat_close_seat_fn close_seat = (libseat_close_seat_fn)dlsym(library, "libseat_close_seat");
    libseat_set_log_level_fn set_log_level = (libseat_set_log_level_fn)dlsym(library, "libseat_set_log_level");
    if (!open_seat || !open_device || !close_device || !close_seat || !set_log_level) {
        printf("[SEATPROBE] dlsym failed: %s\n", dlerror());
        return 2;
    }
    set_log_level(3);
    const struct libseat_seat_listener listener = {
        .enable_seat = seat_enabled,
        .disable_seat = seat_disabled,
    };
    struct libseat *seat = open_seat(&listener, NULL);
    if (!seat) {
        printf("[SEATPROBE] libseat_open_seat failed errno=%d (%s)\n", errno, strerror(errno));
        return 2;
    }

    int fd = -1;
    int device_id = open_device(seat, "/dev/input/event0", &fd);
    if (device_id < 0 || fd < 0) {
        printf("[SEATPROBE] libseat_open_device rc=%d fd=%d errno=%d (%s)\n",
               device_id, fd, errno, strerror(errno));
        close_seat(seat);
        return 3;
    }

    struct input_id id = {0};
    char name[128] = {0};
    int id_rc = ioctl(fd, EVIOCGID, &id);
    int name_rc = ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name);
    printf("[SEATPROBE] device_id=%d fd=%d id_rc=%d name_rc=%d name=%s dev=%04x:%04x\n",
           device_id, fd, id_rc, name_rc, name, id.bustype, id.product);
    int close_rc = close_device(seat, device_id);
    printf("[SEATPROBE] close_device rc=%d errno=%d (%s)\n", close_rc, errno, strerror(errno));
    int seat_rc = close_seat(seat);
    printf("[SEATPROBE] close_seat rc=%d errno=%d (%s)\n", seat_rc, errno, strerror(errno));
    if (id_rc < 0 || name_rc < 0 || strstr(name, "Virtio") == NULL) return 4;
    puts("[SEATPROBE_EXIT] 0 verdict=LIBSEAT_DEVICE_FD_OK");
    return 0;
}
