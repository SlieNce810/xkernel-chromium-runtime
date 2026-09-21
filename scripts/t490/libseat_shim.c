/* libseat_shim.c v4 — LD_PRELOAD shim：让 libseat 完全不需要 seatd/logind
 *
 * 修复记录（v3 → v4）：
 *   v3 在 libseat_open_seat() 内部**同步**回调 enable_seat，但此调用返回前
 *   weston 的 b->libseat 字段尚未赋值 → weston 在内部状态不完整时继续初始化，
 *   导致 "could not open DRM device"（且从未调用 libseat_open_device）。
 *   v4 改为**延迟回调**（独立线程 sleep 100ms 后再触发 enable_seat），
 *   保证 open_seat 已返回、weston 状态就绪。
 *
 * 编译：aarch64-linux-musl-gcc -shared -fPIC -O2 -o libseat-shim.so libseat_shim.c -lpthread
 */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>

struct libseat_seat_listener {
    void (*enable_seat)(void *seat, void *userdata);
    void (*disable_seat)(void *seat, void *userdata);
};

static int g_fake_seat;
static int g_devnull_fd = -1;
static const struct libseat_seat_listener *g_listener;
static void *g_userdata;
static int g_enabled;

static void *delayed_enable(void *arg)
{
    (void)arg;
    usleep(100000);                 /* 100ms：确保 open_seat 已返回、weston 状态就绪 */
    if (!g_enabled && g_listener && g_listener->enable_seat) {
        g_enabled = 1;
        fprintf(stderr, "[libseat-shim] (thread) calling enable_seat\n");
        g_listener->enable_seat(&g_fake_seat, g_userdata);
        fprintf(stderr, "[libseat-shim] (thread) enable_seat returned\n");
    }
    return NULL;
}

void *libseat_open_seat(const struct libseat_seat_listener *listener, void *userdata)
{
    fprintf(stderr, "[libseat-shim] open_seat(listener=%p, userdata=%p)\n",
            (const void *)listener, userdata);
    g_listener = listener;
    g_userdata = userdata;
    if (listener) {
        fprintf(stderr, "[libseat-shim]   enable_seat=%p (will call delayed)\n",
                (const void *)listener->enable_seat);
        pthread_t t;
        if (pthread_create(&t, NULL, delayed_enable, NULL) == 0)
            pthread_detach(t);
        else
            fprintf(stderr, "[libseat-shim]   WARN: pthread_create failed\n");
    }
    fprintf(stderr, "[libseat-shim] open_seat -> fake seat (returning)\n");
    return &g_fake_seat;
}

int libseat_close_seat(void *seat)
{
    fprintf(stderr, "[libseat-shim] close_seat -> 0\n");
    return 0;
}

int libseat_disable_seat(void *seat)
{
    fprintf(stderr, "[libseat-shim] disable_seat -> 0\n");
    return 0;
}

int libseat_open_device(void *seat, const char *path, int *fd)
{
    int f = open(path, O_RDWR | O_CLOEXEC);
    if (f < 0) {
        fprintf(stderr, "[libseat-shim] open(%s) FAILED: %s\n", path, strerror(errno));
        return -1;
    }
    *fd = f;
    fprintf(stderr, "[libseat-shim] open(%s) -> fd=%d OK\n", path, f);
    return 1;
}

int libseat_close_device(void *seat, int device_id)
{
    fprintf(stderr, "[libseat-shim] close_device(%d) -> 0\n", device_id);
    return 0;
}

const char *libseat_seat_name(void *seat)
{
    return "seat0";
}

int libseat_get_fd(void *seat)
{
    if (g_devnull_fd < 0)
        g_devnull_fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
    fprintf(stderr, "[libseat-shim] get_fd -> %d\n", g_devnull_fd);
    return g_devnull_fd;
}

int libseat_dispatch(void *seat, int timeout)
{
    (void)timeout;
    return 0;
}
