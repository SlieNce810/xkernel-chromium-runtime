// BUILD: dynamic-so
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef struct wl_proxy wl_proxy;
typedef struct wl_display wl_display;
typedef struct wl_interface wl_interface;
typedef union wl_argument {
    uint32_t u;
    int32_t i;
    int32_t f;
    const char *s;
    void *o;
    uint32_t n;
    const void *a;
} wl_argument;
typedef wl_proxy *(*marshal_array_flags_fn)(wl_proxy *, uint32_t, const wl_interface *, uint32_t, uint32_t, wl_argument *);
typedef wl_proxy *(*marshal_array_fn)(wl_proxy *, uint32_t, wl_argument *);
typedef wl_display *(*display_connect_fn)(const char *name);
typedef const char *(*get_class_fn)(const wl_proxy *);

static marshal_array_flags_fn real_marshal_array_flags;
static marshal_array_fn real_marshal_array;
static display_connect_fn real_display_connect;
static get_class_fn get_class;
static __thread int in_shim;
static wl_proxy *seen[128];
static unsigned seen_count;

static void emit_line(const char *fmt, ...) {
    char line[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(line, sizeof(line), fmt, ap);
    va_end(ap);
    if (n < 0)
        return;
    size_t len = (size_t)n < sizeof(line) ? (size_t)n : sizeof(line) - 1;
    (void)write(STDERR_FILENO, line, len);
    int fd = open("/dev/console", O_WRONLY | O_CLOEXEC);
    if (fd >= 0) {
        (void)write(fd, line, len);
        (void)close(fd);
    }
}

__attribute__((constructor)) static void shim_init(void) {
    emit_line("[wayland-damage-shim] loaded pid=%ld\n", (long)getpid());
}

static void resolve_symbols(void) {
    if (!real_marshal_array_flags)
        real_marshal_array_flags = (marshal_array_flags_fn)dlsym(RTLD_NEXT, "wl_proxy_marshal_array_flags");
    if (!real_marshal_array)
        real_marshal_array = (marshal_array_fn)dlsym(RTLD_NEXT, "wl_proxy_marshal_array");
    if (!real_display_connect)
        real_display_connect = (display_connect_fn)dlsym(RTLD_NEXT, "wl_display_connect");
    if (!get_class)
        get_class = (get_class_fn)dlsym(RTLD_NEXT, "wl_proxy_get_class");
}

static int mark_first_surface(wl_proxy *proxy) {
    for (unsigned i = 0; i < seen_count; ++i)
        if (seen[i] == proxy)
            return 0;
    if (seen_count < sizeof(seen) / sizeof(seen[0]))
        seen[seen_count++] = proxy;
    return 1;
}

static int is_first_commit(wl_proxy *proxy, uint32_t opcode) {
    const char *klass = get_class ? get_class(proxy) : NULL;
    if (!klass || strcmp(klass, "wl_surface") != 0 || opcode != 6 || in_shim)
        return 0;
    return mark_first_surface(proxy);
}

static void inject_damage(wl_proxy *proxy) {
    if (!real_marshal_array_flags)
        return;
    wl_argument damage[4];
    memset(damage, 0, sizeof(damage));
    damage[0].i = 0;
    damage[1].i = 0;
    damage[2].i = INT32_MAX;
    damage[3].i = INT32_MAX;
    in_shim = 1;
    (void)real_marshal_array_flags(proxy, 2, NULL, 0, 0, damage);
    in_shim = 0;
    emit_line("[wayland-damage-shim] injected initial wl_surface.damage pid=%ld\n", (long)getpid());
}

static void trace_request(wl_proxy *proxy, uint32_t opcode, const char *entry) {
    const char *klass = get_class ? get_class(proxy) : NULL;
    emit_line("[wayland-damage-shim] %s class=%s opcode=%u pid=%ld\n",
              entry, klass ? klass : "?", opcode, (long)getpid());
}

wl_display *wl_display_connect(const char *name) {
    resolve_symbols();
    emit_line("[wayland-damage-shim] wl_display_connect name=%s pid=%ld\n",
              name ? name : "<null>", (long)getpid());
    return real_display_connect ? real_display_connect(name) : NULL;
}

wl_proxy *wl_proxy_marshal_array_flags(wl_proxy *proxy,
                                       uint32_t opcode,
                                       const wl_interface *interface,
                                       uint32_t version,
                                       uint32_t flags,
                                       wl_argument *args) {
    resolve_symbols();
    if (!real_marshal_array_flags)
        return NULL;
    trace_request(proxy, opcode, "array_flags");
    int inject = is_first_commit(proxy, opcode);
    wl_proxy *result = real_marshal_array_flags(proxy, opcode, interface, version, flags, args);
    if (inject)
        inject_damage(proxy);
    return result;
}

wl_proxy *wl_proxy_marshal_array(wl_proxy *proxy,
                                 uint32_t opcode,
                                 wl_argument *args) {
    resolve_symbols();
    if (!real_marshal_array)
        return NULL;
    trace_request(proxy, opcode, "array");
    int inject = is_first_commit(proxy, opcode);
    wl_proxy *result = real_marshal_array(proxy, opcode, args);
    if (inject)
        inject_damage(proxy);
    return result;
}

