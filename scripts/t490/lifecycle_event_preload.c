// BUILD: dynamic-so
#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

typedef int (*epoll_wait_fn)(int, struct epoll_event *, int, int);
typedef int (*epoll_pwait_fn)(int, struct epoll_event *, int, int,
                              const sigset_t *);
typedef pid_t (*fork_fn)(void);
typedef int (*openat_fn)(int, const char *, int, ...);
typedef int (*open_fn)(const char *, int, ...);

static epoll_wait_fn next_epoll_wait;
static epoll_pwait_fn next_epoll_pwait;
static fork_fn next_fork;
static openat_fn next_openat;
static open_fn next_open;

static pid_t cached_pid = -1;
static char process_role[24] = "unknown";
static char run_id[96];
static char navigation_id[64];
static char page_path[256];
static char page_url[512];
static char event_path[256] = "/root/lifecycle-probe-events.jsonl";
static char renderer_state_path[192];
static char pending_request_id[192];
static char pending_navigation_id[64];
static uint64_t request_number;
static bool browser_ready_reported;
static bool renderer_ready_reported;
static bool navigation_reported;
static uint64_t event_number;

static uint64_t monotonic_time_ns(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0)
        return 0;
    return (uint64_t)value.tv_sec * 1000000000ULL + (uint64_t)value.tv_nsec;
}

static long raw_openat(int dirfd, const char *path, int flags, mode_t mode) {
    return syscall(SYS_openat, dirfd, path, flags, mode);
}

static ssize_t raw_read(int fd, void *buffer, size_t size) {
    return syscall(SYS_read, fd, buffer, size);
}

static ssize_t raw_write(int fd, const void *buffer, size_t size) {
    return syscall(SYS_write, fd, buffer, size);
}

static ssize_t read_process_text(pid_t pid, const char *suffix, char *buffer,
                                 size_t capacity) {
    char path[96];
    int path_size = snprintf(path, sizeof(path), "/proc/%d/%s", pid, suffix);
    if (path_size <= 0 || (size_t)path_size >= sizeof(path) || capacity == 0) {
        if (capacity)
            buffer[0] = '\0';
        return -1;
    }
    long fd = raw_openat(AT_FDCWD, path, O_RDONLY | O_CLOEXEC, 0);
    if (fd < 0) {
        buffer[0] = '\0';
        return -1;
    }
    ssize_t amount = raw_read((int)fd, buffer, capacity - 1);
    syscall(SYS_close, (int)fd);
    if (amount < 0)
        return -1;
    buffer[amount] = '\0';
    return amount;
}

static void classify_process(void) {
    pid_t pid = getpid();
    if (pid == cached_pid)
        return;

    cached_pid = pid;
    browser_ready_reported = false;
    renderer_ready_reported = false;
    navigation_reported = false;
    char cmdline[4096];
    ssize_t cmdline_size = read_process_text(pid, "cmdline", cmdline,
                                             sizeof(cmdline));
    if (cmdline_size > 0) {
        for (ssize_t i = 0; i < cmdline_size; ++i) {
            if (cmdline[i] == '\0')
                cmdline[i] = ' ';
        }
    }
    if (strstr(cmdline, "--type=renderer"))
        snprintf(process_role, sizeof(process_role), "%s", "renderer");
    else if (strstr(cmdline, "--type=zygote"))
        snprintf(process_role, sizeof(process_role), "%s", "zygote");
    else if (strstr(cmdline, "--type=utility"))
        snprintf(process_role, sizeof(process_role), "%s", "utility");
    else if (strstr(cmdline, "crashpad_handler") ||
             strstr(cmdline, "--type=gpu-process"))
        snprintf(process_role, sizeof(process_role), "%s", "other");
    else if (cmdline[0] != '\0')
        snprintf(process_role, sizeof(process_role), "%s", "browser");
    else
        snprintf(process_role, sizeof(process_role), "%s", "other");
}

static uint64_t process_start_ticks(pid_t pid) {
    char line[4096];
    read_process_text(pid, "stat", line, sizeof(line));
    char *right_paren = strrchr(line, ')');
    if (!right_paren || right_paren[1] != ' ')
        return 0;
    char *save = NULL;
    char *token = strtok_r(right_paren + 2, " ", &save);
    unsigned field = 3;
    while (token) {
        if (field == 22) {
            char *end = NULL;
            errno = 0;
            unsigned long long value = strtoull(token, &end, 10);
            if (errno || end == token || *end)
                return 0;
            return (uint64_t)value;
        }
        ++field;
        token = strtok_r(NULL, " ", &save);
    }
    return 0;
}

static void get_process_instance(pid_t pid, char *out, size_t capacity) {
    int result = snprintf(out, capacity, "%d-%llu", pid,
                          (unsigned long long)process_start_ticks(pid));
    if (result < 0 || (size_t)result >= capacity)
        out[0] = '\0';
}

static void append_probe_event(const char *event, uint64_t t_ns, pid_t pid,
                               pid_t ppid, const char *role,
                               const char *process_instance,
                               const char *nav_id, const char *request_id,
                               const char *renderer_id, pid_t child_pid,
                               const char *source, const char *url) {
    if (!run_id[0] || t_ns == 0)
        return;
    uint64_t local_number = __atomic_add_fetch(&event_number, 1, __ATOMIC_RELAXED);
    char line[1536];
    int size = snprintf(
        line, sizeof(line),
        "{\"schema\":\"xkernel.browser.lifecycle.v1\","
        "\"run_id\":\"%s\",\"clock_id\":\"LINUX_CLOCK_MONOTONIC\","
        "\"t_ns\":%llu,\"event_id\":\"%s:%d:%llu:%llu\","
        "\"event\":\"%s\",\"pid\":%d,\"ppid\":%d,"
        "\"process_instance\":\"%s\",\"role\":\"%s\","
        "\"navigation_id\":\"%s\",\"request_id\":\"%s\","
        "\"renderer_id\":\"%s\",\"child_pid\":%d,"
        "\"source\":\"%s\",\"url\":\"%s\"}\n",
        run_id, (unsigned long long)t_ns, run_id, pid,
        (unsigned long long)t_ns, (unsigned long long)local_number, event,
        pid, ppid, process_instance ? process_instance : "",
        role ? role : "", nav_id ? nav_id : "", request_id ? request_id : "",
        renderer_id ? renderer_id : "", child_pid, source ? source : "",
        url ? url : "");
    if (size <= 0 || (size_t)size >= sizeof(line))
        return;
    long fd = raw_openat(AT_FDCWD, event_path,
                         O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0644);
    if (fd >= 0) {
        (void)raw_write((int)fd, line, (size_t)size);
        syscall(SYS_close, (int)fd);
    }
}

static void maybe_report_loop_ready(void) {
    classify_process();
    pid_t pid = getpid();
    pid_t tid = (pid_t)syscall(SYS_gettid);
    if (tid != pid)
        return;
    char instance[96];
    get_process_instance(pid, instance, sizeof(instance));
    if (strcmp(process_role, "browser") == 0 && !browser_ready_reported) {
        browser_ready_reported = true;
        append_probe_event("browser_main_loop_ready", monotonic_time_ns(), pid,
                           getppid(), process_role, instance, "", "", "", 0,
                           "browser-main-thread-first-epoll-wait", "");
        return;
    }
    if (strcmp(process_role, "renderer") == 0 && !renderer_ready_reported &&
        pending_request_id[0] && pending_navigation_id[0]) {
        renderer_ready_reported = true;
        uint64_t ready_ns = monotonic_time_ns();
        append_probe_event("renderer_ready", ready_ns, pid, getppid(),
                           process_role, instance, pending_navigation_id,
                           pending_request_id, instance, 0,
                           "renderer-main-thread-first-epoll-wait", "");
        char state_line[512];
        int size = snprintf(state_line, sizeof(state_line),
                            "%d %s %s %s %llu\n", pid, instance, instance,
                            pending_request_id,
                            (unsigned long long)ready_ns);
        if (size > 0 && (size_t)size < sizeof(state_line)) {
            long fd = raw_openat(AT_FDCWD, renderer_state_path,
                                 O_WRONLY | O_TRUNC | O_CREAT | O_CLOEXEC,
                                 0644);
            if (fd >= 0) {
                (void)raw_write((int)fd, state_line, (size_t)size);
                syscall(SYS_close, (int)fd);
            }
        }
    }
}

static bool matches_page_path(int dirfd, const char *path) {
    if (!path || !page_path[0])
        return false;
    if (dirfd != AT_FDCWD && path[0] != '/')
        return false;
    return strcmp(path, page_path) == 0;
}

static void maybe_report_navigation(int dirfd, const char *path, int fd,
                                    uint64_t request_ns) {
    classify_process();
    if (fd < 0 || strcmp(process_role, "browser") != 0 ||
        navigation_reported || !matches_page_path(dirfd, path))
        return;
    navigation_reported = true;
    pid_t pid = getpid();
    char instance[96];
    get_process_instance(pid, instance, sizeof(instance));
    append_probe_event("navigation_requested", request_ns, pid, getppid(),
                       process_role, instance, navigation_id, "", "", 0,
                       "browser-file-url-open", page_url);
}

static void *required_symbol(void **destination, const char *name) {
    void *symbol = dlsym(RTLD_NEXT, name);
    *destination = symbol;
    return symbol;
}

__attribute__((constructor)) static void initialize_lifecycle_preload(void) {
    required_symbol((void **)&next_epoll_wait, "epoll_wait");
    required_symbol((void **)&next_epoll_pwait, "epoll_pwait");
    required_symbol((void **)&next_fork, "fork");
    required_symbol((void **)&next_openat, "openat");
    required_symbol((void **)&next_open, "open");
    const char *value = getenv("XK_METRICS_RUN_ID");
    if (value)
        snprintf(run_id, sizeof(run_id), "%s", value);
    value = getenv("XK_METRICS_NAV_ID");
    if (value)
        snprintf(navigation_id, sizeof(navigation_id), "%s", value);
    value = getenv("XK_METRICS_PAGE_PATH");
    snprintf(page_path, sizeof(page_path), "%s",
             value && *value ? value : "/usr/share/html-test/index.html");
    value = getenv("XK_METRICS_PAGE_URL");
    snprintf(page_url, sizeof(page_url), "%s",
             value && *value ? value : "file:///usr/share/html-test/index.html");
    value = getenv("XK_METRICS_EVENT_PATH");
    if (value && value[0] == '/')
        snprintf(event_path, sizeof(event_path), "%s", value);
    if (run_id[0])
        snprintf(renderer_state_path, sizeof(renderer_state_path),
                 "/root/lifecycle-renderer-%s.state", run_id);
    classify_process();
}

int epoll_wait(int epfd, struct epoll_event *events, int maxevents, int timeout) {
    maybe_report_loop_ready();
    if (next_epoll_wait)
        return next_epoll_wait(epfd, events, maxevents, timeout);
    errno = ENOSYS;
    return -1;
}

int epoll_pwait(int epfd, struct epoll_event *events, int maxevents, int timeout,
                const sigset_t *sigmask) {
    maybe_report_loop_ready();
    if (next_epoll_pwait)
        return next_epoll_pwait(epfd, events, maxevents, timeout, sigmask);
    errno = ENOSYS;
    return -1;
}

pid_t fork(void) {
    classify_process();
    if (!next_fork) {
        errno = ENOSYS;
        return -1;
    }
    if (strcmp(process_role, "zygote") != 0)
        return next_fork();

    uint64_t request_ns = monotonic_time_ns();
    uint64_t counter = __atomic_add_fetch(&request_number, 1, __ATOMIC_RELAXED);
    char request_id[sizeof(pending_request_id)];
    snprintf(request_id, sizeof(request_id), "%s:z%d:%llu:%llu", run_id,
             getpid(), (unsigned long long)request_ns,
             (unsigned long long)counter);
    snprintf(pending_request_id, sizeof(pending_request_id), "%s", request_id);
    snprintf(pending_navigation_id, sizeof(pending_navigation_id), "%s",
             navigation_id);

    pid_t child = next_fork();
    if (child == 0) {
        classify_process();
        return 0;
    }
    if (child > 0) {
        char instance[96];
        get_process_instance(getpid(), instance, sizeof(instance));
        append_probe_event("renderer_create_requested", request_ns, getpid(),
                           getppid(), process_role, instance,
                           navigation_id, request_id, "", child,
                           "zygote-fork-boundary", "");
    }
    pending_request_id[0] = '\0';
    pending_navigation_id[0] = '\0';
    return child;
}

int openat(int dirfd, const char *path, int flags, ...) {
    mode_t mode = 0;
    bool has_mode = (flags & O_CREAT) != 0;
#ifdef O_TMPFILE
    has_mode = has_mode || (flags & O_TMPFILE) == O_TMPFILE;
#endif
    if (has_mode) {
        va_list args;
        va_start(args, flags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    uint64_t request_ns = monotonic_time_ns();
    int fd;
    if (next_openat)
        fd = has_mode ? next_openat(dirfd, path, flags, mode)
                      : next_openat(dirfd, path, flags);
    else
        fd = (int)raw_openat(dirfd, path, flags, mode);
    maybe_report_navigation(dirfd, path, fd, request_ns);
    return fd;
}

int open(const char *path, int flags, ...) {
    mode_t mode = 0;
    bool has_mode = (flags & O_CREAT) != 0;
#ifdef O_TMPFILE
    has_mode = has_mode || (flags & O_TMPFILE) == O_TMPFILE;
#endif
    if (has_mode) {
        va_list args;
        va_start(args, flags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    uint64_t request_ns = monotonic_time_ns();
    int fd;
    if (next_open)
        fd = has_mode ? next_open(path, flags, mode) : next_open(path, flags);
    else
        fd = (int)raw_openat(AT_FDCWD, path, flags, mode);
    maybe_report_navigation(AT_FDCWD, path, fd, request_ns);
    return fd;
}
