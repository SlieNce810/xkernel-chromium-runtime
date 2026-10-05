/* Exercise real libinput evdev setup with direct opens and verbose diagnostics. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

struct libinput;
struct libinput_device;
struct libinput_interface {
    int (*open_restricted)(const char *path, int flags, void *userdata);
    void (*close_restricted)(int fd, void *userdata);
};

typedef struct libinput *(*create_context_fn)(const struct libinput_interface *, void *);
typedef struct libinput_device *(*add_device_fn)(struct libinput *, const char *);
typedef void (*remove_device_fn)(struct libinput_device *);
typedef void (*set_priority_fn)(struct libinput *, int);
typedef struct libinput *(*unref_fn)(struct libinput *);

static int open_restricted(const char *path, int flags, void *userdata)
{
    (void)userdata;
    int fd = open(path, flags | O_CLOEXEC);
    printf("[LIBINPUT_PROBE] open_restricted path=%s flags=%#x fd=%d errno=%d (%s)\n",
           path, flags, fd, errno, strerror(errno));
    return fd < 0 ? -errno : fd;
}

static void close_restricted(int fd, void *userdata)
{
    (void)userdata;
    printf("[LIBINPUT_PROBE] close_restricted fd=%d rc=%d errno=%d (%s)\n",
           fd, close(fd), errno, strerror(errno));
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    void *library = dlopen("libinput.so.10", RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        printf("[LIBINPUT_PROBE] dlopen failed: %s\n", dlerror());
        return 2;
    }
    create_context_fn create_context = (create_context_fn)dlsym(library, "libinput_path_create_context");
    add_device_fn add_device = (add_device_fn)dlsym(library, "libinput_path_add_device");
    remove_device_fn remove_device = (remove_device_fn)dlsym(library, "libinput_path_remove_device");
    set_priority_fn set_priority = (set_priority_fn)dlsym(library, "libinput_log_set_priority");
    unref_fn unref = (unref_fn)dlsym(library, "libinput_unref");
    if (!create_context || !add_device || !remove_device || !set_priority || !unref) {
        printf("[LIBINPUT_PROBE] dlsym failed: %s\n", dlerror());
        return 3;
    }

    const struct libinput_interface interface = {
        .open_restricted = open_restricted,
        .close_restricted = close_restricted,
    };
    struct libinput *context = create_context(&interface, NULL);
    if (!context) {
        printf("[LIBINPUT_PROBE] context creation failed errno=%d (%s)\n", errno, strerror(errno));
        return 4;
    }
    set_priority(context, 0); /* LIBINPUT_LOG_PRIORITY_DEBUG */

    int added = 0;
    for (int i = 0; i < 2; i++) {
        char path[64];
        snprintf(path, sizeof(path), "/dev/input/event%d", i);
        errno = 0;
        struct libinput_device *device = add_device(context, path);
        printf("[LIBINPUT_PROBE] add_device path=%s result=%s errno=%d (%s)\n",
               path, device ? "ok" : "null", errno, strerror(errno));
        if (device) {
            added++;
            remove_device(device);
        }
    }

    unref(context);
    printf("[LIBINPUT_PROBE_EXIT] %d devices_added=%d verdict=%s\n",
           added == 2 ? 0 : 5, added, added == 2 ? "LIBINPUT_OK" : "LIBINPUT_FAILED");
    return added == 2 ? 0 : 5;
}
