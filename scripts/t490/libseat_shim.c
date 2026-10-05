/* libseat_shim.c v5 — LD_PRELOAD shim：让 libseat 完全不需要 seatd / logind
 *
 * 用途与背景
 *   Weston 14 的 DRM backend 通过 libseat 打开 DRM 设备：
 *       weston_launcher_open() -> libseat_open_device(seat, path, &fd)
 *   在 x-kernel guest 上，真 libseat 即使已通过 seatd 拿到 session control
 *   （日志：`Seat opened with backend 'seatd'` + `session control granted`），
 *   仍然在下一步失败：
 *       ERROR: could not open DRM device '/dev/dri/card0'   （完整路径同样失败）
 *   判定：seatd 要判断"该设备属于哪个 seat"，依赖 libudev/sysfs 枚举设备；
 *   本 guest 的 /sys/class 只有 graphics、/sys/class/drm 不存在 ⇒ 枚举不到 ⇒ 拒绝打开。
 *   本 shim 让 Weston 完全绕过 libseat 的后端逻辑：open_seat 给假 seat，
 *   open_device 直接 open(path)（以 root 身份），从而绕开设备归属检查。
 *
 * 修复记录（v3 → v4 → v5）
 *   v3: 在 libseat_open_seat() 内部**同步**回调 enable_seat —— 但此时该函数尚未返回，
 *       weston 的 b->libseat 字段还没赋值 ⇒ weston 在内部状态不完整时继续初始化 ⇒
 *       症状是 **"could not open DRM device" 且从未调用 libseat_open_device**。
 *       （★ 这个症状具有极强的误导性：看起来像设备/权限问题，实际是调用时序问题。
 *          weston3 轮用真 libseat 时症状与之完全一致，因此 v5 保留延迟回调这一关键设计。）
 *   v4: 改为**延迟回调**（独立线程 sleep 100ms 再触发 enable_seat），保证 open_seat 已返回。
 *   v5: 补齐 libseat 的全部公开 API 符号 —— 若某个符号缺失，动态链接器会**回退到真
 *       libseat**，而真 libseat 拿到的是本 shim 的假 seat 指针 ⇒ 状态错乱。
 *       因此把 0.7.x / 0.8.x 两代 API 都提供：set_device_activity / set_device_enabled。
 *
 * 编译（Alpine 是 musl，必须用 musl 交叉工具链以匹配 libc）：
 *   aarch64-linux-musl-gcc -shared -fPIC -O2 -o libseat-shim.so libseat_shim.c -lpthread
 *
 * 用法：
 *   LD_PRELOAD=/shim/libseat-shim.so weston --backend=drm-backend.so ...
 */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>

struct libseat_seat_listener {
    void (*enable_seat)(void *seat, void *userdata);
    void (*disable_seat)(void *seat, void *userdata);
};

static int g_fake_seat;
static int g_devnull_fd = -1;
static const struct libseat_seat_listener *g_listener;
static void *g_userdata;
static int g_enabled;

/* 自增的 device_id：真 libseat 的 open_device 返回非负 device_id，这里保持一致语义 */
static int g_next_device_id = 1;

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
    fprintf(stderr, "[libseat-shim] close_seat(%p) -> 0\n", seat);
    return 0;
}

int libseat_disable_seat(void *seat)
{
    fprintf(stderr, "[libseat-shim] disable_seat(%p) -> 0\n", seat);
    return 0;
}

/* ★ 核心：直接打开设备，绕开 seatd 的设备归属检查 */
int libseat_open_device(void *seat, const char *path, int *fd)
{
    errno = 0;
    int f = open(path, O_RDWR | O_CLOEXEC);
    if (f < 0) {
        fprintf(stderr, "[libseat-shim] open(%s) FAILED: errno=%d (%s)\n",
                path ? path : "(null)", errno, strerror(errno));
        return -1;
    }
    *fd = f;
    fprintf(stderr, "[libseat-shim] open(%s) -> fd=%d OK, device_id=%d\n",
            path, f, g_next_device_id);
    return g_next_device_id++;
}

int libseat_close_device(void *seat, int device_id)
{
    fprintf(stderr, "[libseat-shim] close_device(%d) -> 0\n", device_id);
    return 0;
}

const char *libseat_seat_name(void *seat)
{
    fprintf(stderr, "[libseat-shim] seat_name -> seat0\n");
    return "seat0";
}

int libseat_get_fd(void *seat)
{
    if (g_devnull_fd < 0)
        g_devnull_fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
    /* 不打印（会被高频轮询刷屏）；返回的 fd 在 epoll 里永不 ready，dispatch 恒 0 */
    return g_devnull_fd;
}

int libseat_dispatch(void *seat, int timeout)
{
    (void)timeout;
    return 0;                      /* 0 = 本次没有事件，Weston 主循环照常继续 */
}

int libseat_seat_release(void *seat)
{
    fprintf(stderr, "[libseat-shim] seat_release -> 0\n");
    return 0;
}

/* 0.7.x API */
int libseat_set_device_activity(void *seat, bool active)
{
    fprintf(stderr, "[libseat-shim] set_device_activity(%d) -> 0\n", (int)active);
    return 0;
}

/* 0.8.x API（若 Weston 调到这个而 shim 没提供，会回退到真 libseat ⇒ 状态错乱） */
int libseat_set_device_enabled(void *seat, int device_id, bool enabled)
{
    fprintf(stderr, "[libseat-shim] set_device_enabled(id=%d, en=%d) -> 0\n",
            device_id, (int)enabled);
    return 0;
}

/* 0.8.x 可能存在的 seat 级开关（保守 stub） */
int libseat_set_seat_enabled(void *seat, bool enabled)
{
    fprintf(stderr, "[libseat-shim] set_seat_enabled(%d) -> 0\n", (int)enabled);
    return 0;
}

/* ==========================================================================
 * v6 补齐：这 3 个符号是真 libseat 导出、且 drm-backend.so **实际引用**的。
 *
 * 为什么必须补（本轮吃过的最大一个坑）：
 *   LD_PRELOAD 是**逐符号**解析的 —— 对 shim 提供了的名字走 shim，
 *   对 shim **没有**提供的名字**静默回退到真 libseat.so.1**。
 *   而真 libseat 拿到的 seat 指针是本 shim 的假 seat（内部布局完全不同），
 *   于是一调用就出错：weston 在 `libseat_switch_session` 失败后直接认定
 *   "设备不可用"，报 `could not open DRM device`，
 *   **于是 libseat_open_device 从头到尾没被调用过一次**
 *   （shim 日志里只有 open_seat / close_seat，永远等不到 open(...) 那行）。
 *
 * 判据（可复用）：drm-backend.so 的 libseat UND 符号集合 ⊆ shim 的导出集合。
 *   真 libseat 导出 11 个：close_device/close_seat/disable_seat/dispatch/get_fd/
 *   open_device/open_seat/seat_name/set_log_handler/set_log_level/switch_session
 *   drm-backend.so 引用其中 10 个（不含 seat_name），v5 恰缺下列 3 个。
 * ========================================================================== */

/* 日志处理器注册：weston 用它接管 libseat 日志。直接接受但不改用（本 shim 自带日志）。 */
int libseat_set_log_handler(void (*handler)(int level, const char *fmt, void *args))
{
    fprintf(stderr, "[libseat-shim] set_log_handler(%p) -> 0\n", (void *)handler);
    return 0;
}

int libseat_set_log_level(int level)
{
    fprintf(stderr, "[libseat-shim] set_log_level(%d) -> 0\n", level);
    return 0;
}

/* ★ 会话切换（VT switch）：本环境没有 VT 子系统，恒报成功。
 *   这是本轮的关键修复点 —— 返回值非 0 会让 weston 判定会话激活失败并提前退出。 */
int libseat_switch_session(void *seat, int session)
{
    fprintf(stderr, "[libseat-shim] switch_session(seat=%p, session=%d) -> 0 "
                    "(no VT subsystem, pretend OK)\n", seat, session);
    return 0;
}
