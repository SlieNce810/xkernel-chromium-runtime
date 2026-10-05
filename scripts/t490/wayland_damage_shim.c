// BUILD: dynamic-so
#define _GNU_SOURCE
#include <dlfcn.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef struct wl_proxy wl_proxy;
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
typedef void *(*marshal_flags_fn)(wl_proxy *, uint32_t, const wl_interface *, uint32_t, uint32_t, ...);
typedef wl_proxy *(*marshal_array_flags_fn)(wl_proxy *, uint32_t, const wl_interface *, uint32_t, uint32_t, wl_argument *);
typedef wl_proxy *(*marshal_array_fn)(wl_proxy *, uint32_t, wl_argument *);
typedef const char *(*get_class_fn)(const wl_proxy *);

static marshal_flags_fn real_marshal;
static marshal_array_flags_fn real_marshal_array_flags;
static marshal_array_fn real_marshal_array;
static get_class_fn get_class;
static __thread int in_shim;
static wl_proxy *seen[128];
static unsigned seen_count;

__attribute__((constructor)) static void shim_init(void) {
    fprintf(stderr, "[wayland-damage-shim] loaded pid=%ld\n", (long)getpid());
}

static void resolve_symbols(void) {
    if (!real_marshal)
        real_marshal = (marshal_flags_fn)dlsym(RTLD_NEXT, "wl_proxy_marshal_flags");
    if (!real_marshal_array_flags)
        real_marshal_array_flags = (marshal_array_flags_fn)dlsym(RTLD_NEXT, "wl_proxy_marshal_array_flags");
    if (!real_marshal_array)
        real_marshal_array = (marshal_array_fn)dlsym(RTLD_NEXT, "wl_proxy_marshal_array");
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
    fprintf(stderr, "[wayland-damage-shim] injected initial wl_surface.damage\n");
}

static void trace_request(wl_proxy *proxy, uint32_t opcode, const char *entry) {
    const char *klass = get_class ? get_class(proxy) : NULL;
    fprintf(stderr, "[wayland-damage-shim] %s class=%s opcode=%u\n",
            entry, klass ? klass : "?", opcode);
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

void *wl_proxy_marshal_flags(wl_proxy *proxy,
                             uint32_t opcode,
                             const wl_interface *interface,
                             uint32_t version,
                             uint32_t flags, ...) {
    resolve_symbols();
    if (!real_marshal)
        return NULL;

    trace_request(proxy, opcode, "flags");
    int inject = is_first_commit(proxy, opcode);

    /* GCC's apply builtins preserve the unknown variadic request arguments. */
    void *args = __builtin_apply_args();
    void *result = __builtin_apply((void (*)())real_marshal, args, 128);
    if (inject)
        inject_damage(proxy);
    __builtin_return(result);
}
