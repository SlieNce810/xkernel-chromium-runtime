// BUILD: dynamic-so
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdarg.h>
#include <string.h>
#include <unistd.h>

typedef struct wl_proxy wl_proxy;
typedef struct wl_interface wl_interface;
typedef struct wl_display wl_display;
typedef union wl_argument {
    uint32_t u;
    int32_t i;
    int32_t f;
    const char *s;
    void *o;
    uint32_t n;
    const void *a;
} wl_argument;
typedef void *(*marshal_flags_fn)(wl_proxy *, uint32_t, const wl_interface *, uint32_t, uint32_t, ...);
typedef wl_proxy *(*marshal_array_flags_fn)(wl_proxy *, uint32_t, const wl_interface *, uint32_t, uint32_t, wl_argument *);
typedef void *(*marshal_fn)(wl_proxy *, uint32_t, ...);
typedef wl_proxy *(*marshal_array_fn)(wl_proxy *, uint32_t, wl_argument *);
typedef const char *(*get_class_fn)(const wl_proxy *);

static marshal_flags_fn real_marshal_flags;
static marshal_array_flags_fn real_marshal_array_flags;
static marshal_fn real_marshal;
static marshal_array_fn real_marshal_array;
static get_class_fn real_get_class;
static __thread int in_shim;
static wl_proxy *seen[32];
static unsigned seen_count;

static void note(const char *msg) {
    size_t n = strlen(msg);
    (void)write(STDERR_FILENO, msg, n);
    int fd = open("/dev/console", O_WRONLY | O_CLOEXEC);
    if (fd >= 0) {
        (void)write(fd, msg, n);
        (void)close(fd);
    }
}

__attribute__((constructor)) static void init(void) {
    note("[wayland-damage-pass] loaded\n");
}

static void resolve(void) {
    if (!real_marshal_flags)
        real_marshal_flags = (marshal_flags_fn)dlsym(RTLD_NEXT, "wl_proxy_marshal_flags");
    if (!real_marshal_array_flags)
        real_marshal_array_flags = (marshal_array_flags_fn)dlsym(RTLD_NEXT, "wl_proxy_marshal_array_flags");
    if (!real_marshal)
        real_marshal = (marshal_fn)dlsym(RTLD_NEXT, "wl_proxy_marshal");
    if (!real_marshal_array)
        real_marshal_array = (marshal_array_fn)dlsym(RTLD_NEXT, "wl_proxy_marshal_array");
    if (!real_get_class)
        real_get_class = (get_class_fn)dlsym(RTLD_NEXT, "wl_proxy_get_class");
}

static int first_commit(wl_proxy *proxy, uint32_t opcode) {
    if (in_shim || opcode != 6 || !real_get_class)
        return 0;
    const char *klass = real_get_class(proxy);
    if (!klass || strcmp(klass, "wl_surface") != 0)
        return 0;
    for (unsigned i = 0; i < seen_count; ++i)
        if (seen[i] == proxy)
            return 0;
    if (seen_count < sizeof(seen) / sizeof(seen[0]))
        seen[seen_count++] = proxy;
    return 1;
}

static void inject_damage(wl_proxy *proxy) {
    if (!real_marshal_array_flags)
        return;
    wl_argument args[4];
    memset(args, 0, sizeof(args));
    args[2].i = INT32_MAX;
    args[3].i = INT32_MAX;
    in_shim = 1;
    (void)real_marshal_array_flags(proxy, 2, NULL, 0, 0, args);
    in_shim = 0;
    note("[wayland-damage-pass] injected initial damage\n");
}

void *wl_proxy_marshal_flags(wl_proxy *proxy,
                             uint32_t opcode,
                             const wl_interface *interface,
                             uint32_t version,
                             uint32_t flags, ...) {
    resolve();
    if (!real_marshal_flags)
        return NULL;
    int inject = first_commit(proxy, opcode);
    void *args = __builtin_apply_args();
    void *result = __builtin_apply((void (*)())real_marshal_flags, args, 128);
    if (inject)
        inject_damage(proxy);
    __builtin_return(result);
}

void *wl_proxy_marshal(wl_proxy *proxy, uint32_t opcode, ...) {
    resolve();
    if (!real_marshal)
        return NULL;
    int inject = first_commit(proxy, opcode);
    void *args = __builtin_apply_args();
    void *result = __builtin_apply((void (*)())real_marshal, args, 128);
    if (inject)
        inject_damage(proxy);
    __builtin_return(result);
}

wl_proxy *wl_proxy_marshal_array(wl_proxy *proxy, uint32_t opcode, wl_argument *args) {
    resolve();
    if (!real_marshal_array)
        return NULL;
    int inject = first_commit(proxy, opcode);
    wl_proxy *result = real_marshal_array(proxy, opcode, args);
    if (inject)
        inject_damage(proxy);
    return result;
}
