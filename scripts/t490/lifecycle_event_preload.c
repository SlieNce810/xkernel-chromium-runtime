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
typedef int (*epoll_pwait2_fn)(int, struct epoll_event *, int,
                               const struct timespec *, const sigset_t *);
typedef int (*poll_fn)(struct pollfd *, nfds_t, int);
typedef int (*ppoll_fn)(struct pollfd *, nfds_t, const struct timespec *,
                        const sigset_t *);
typedef pid_t (*fork_fn)(void);
typedef int (*execve_fn)(const char *, char *const[], char *const[]);
typedef int (*execveat_fn)(int, const char *, char *const[], char *const[], int);
typedef int (*openat_fn)(int, const char *, int, ...);
typedef int (*open_fn)(const char *, int, ...);

static epoll_wait_fn next_epoll_wait;
static epoll_pwait_fn next_epoll_pwait;
static epoll_pwait2_fn next_epoll_pwait2;
static poll_fn next_poll;
static ppoll_fn next_ppoll;
static fork_fn next_fork;
static execve_fn next_execve;
static execveat_fn next_execveat;
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

static bool read_thread_comm(pid_t pid, pid_t tid, char *buffer,
                             size_t capacity) {
    char suffix[64];
    int size = snprintf(suffix, sizeof(suffix), "task/%d/comm", tid);
    if (size <= 0 || (size_t)size >= sizeof(suffix) || capacity == 0)
        return false;
    ssize_t amount = read_process_text(pid, suffix, buffer, capacity);
    if (amount <= 0)
        return false;
    while (amount > 0 && (buffer[amount - 1] == '\n' || buffer[amount - 1] == '\r'))
        buffer[--amount] = '\0';
    return amount > 0;
}

static void classify_process(void) {
    pid_t pid = getpid();
    if (pid == cached_pid && process_role[0] != '\0' &&
        !(strcmp(process_role, "zygote") == 0 && pending_request_id[0]))
        return;
    if (pid != cached_pid) {
        cached_pid = pid;
        browser_ready_reported = false;
        renderer_ready_reported = false;
        navigation_reported = false;
        process_role[0] = '\0';
    }

    char comm[64];
    if (read_thread_comm(pid, pid, comm, sizeof(comm))) {
        if (strcmp(comm, "CrRendererMain") == 0) {
            snprintf(process_role, sizeof(process_role), "%s", "renderer");
            return;
        }
        if (strcmp(comm, "CrZygoteMain") == 0) {
            snprintf(process_role, sizeof(process_role), "%s", "zygote");
            return;
        }
        if (strcmp(comm, "CrBrowserMain") == 0) {
            snprintf(process_role, sizeof(process_role), "%s", "browser");
            return;
        }
    }
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
        "\"seq\":%llu,"
        "\"t_ns\":%llu,\"event_id\":\"%s:%d:%llu:%llu\","
        "\"event\":\"%s\",\"pid\":%d,\"ppid\":%d,"
        "\"process_instance\":\"%s\",\"role\":\"%s\","
        "\"navigation_id\":\"%s\",\"request_id\":\"%s\","
        "\"renderer_id\":\"%s\",\"child_pid\":%d,"
        "\"source\":\"%s\",\"url\":\"%s\"}\n",
        run_id, (unsigned long long)local_number, (unsigned long long)t_ns, run_id, pid,
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
    pid_t pid = getpid();
    if (pid == cached_pid &&
        ((strcmp(process_role, "browser") == 0 && browser_ready_reported) ||
         (strcmp(process_role, "renderer") == 0 && renderer_ready_reported) ||
         (strcmp(process_role, "zygote") == 0 && !pending_request_id[0]) ||
         (strcmp(process_role, "utility") == 0) ||
         (strcmp(process_role, "gpu") == 0) ||
         (strcmp(process_role, "other") == 0)))
        return;
    classify_process();
    pid = getpid();
    pid_t tid = (pid_t)syscall(SYS_gettid);
    if (strcmp(process_role, "browser") != 0 &&
        strcmp(process_role, "renderer") != 0 &&
        !(strcmp(process_role, "zygote") == 0 && pending_request_id[0]))
        return;
    char comm[64];
    bool got_comm = read_thread_comm(pid, tid, comm, sizeof(comm));
    bool named_browser_main = got_comm && strcmp(comm, "CrBrowserMain") == 0;
    bool named_renderer_main = got_comm && strcmp(comm, "CrRendererMain") == 0;
    if (tid != pid && !named_browser_main && !named_renderer_main)
        return;
    char instance[96];
    get_process_instance(pid, instance, sizeof(instance));
    if (strcmp(process_role, "browser") == 0 && !browser_ready_reported) {
        browser_ready_reported = true;
        append_probe_event("browser_main_loop_ready", monotonic_time_ns(), pid,
                           getppid(), process_role, instance, "", "", "", 0,
                           "CrBrowserMain-first-poll-or-epoll-wait", "");
        return;
    }
    if (strcmp(process_role, "renderer") == 0 && !renderer_ready_reported &&
        pending_request_id[0] && pending_navigation_id[0]) {
        renderer_ready_reported = true;
        uint64_t ready_ns = monotonic_time_ns();
        append_probe_event("renderer_ready", ready_ns, pid, getppid(),
                           process_role, instance, pending_navigation_id,
                           pending_request_id, instance, 0,
                           "CrRendererMain-first-poll-or-epoll-wait", "");
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

static bool renderer_command(char *const argv[]) {
    if (!argv)
        return false;
    for (size_t index = 0; argv[index]; ++index) {
        if (strcmp(argv[index], "--type=renderer") == 0)
            return true;
    }
    return false;
}

static bool add_renderer_preload(char *const envp[], char ***out_envp,
                                 char *preload_entry, size_t preload_capacity,
                                 const char *request_entry,
                                 const char *navigation_entry) {
    if (!envp || !out_envp || !preload_entry || preload_capacity == 0)
        return false;
    const char *existing = NULL;
    size_t count = 0;
    for (; envp[count]; ++count) {
        if (strncmp(envp[count], "LD_PRELOAD=", 11) == 0)
            existing = envp[count] + 11;
    }
    const char *library = "/lifecycle_event_preload.so";
    bool need_preload = !(existing && *existing &&
                          strstr(existing, "lifecycle_event_preload.so"));
    if (need_preload && existing && *existing) {
        int size = snprintf(preload_entry, preload_capacity, "LD_PRELOAD=%s:%s",
                            existing, library);
        if (size <= 0 || (size_t)size >= preload_capacity)
            return false;
    } else if (need_preload) {
        int size = snprintf(preload_entry, preload_capacity, "LD_PRELOAD=%s",
                            library);
        if (size <= 0 || (size_t)size >= preload_capacity)
            return false;
    }

    size_t extra = (need_preload ? 1 : 0) +
                   ((request_entry && *request_entry) ? 1 : 0) +
                   ((navigation_entry && *navigation_entry) ? 1 : 0);
    char **copy = calloc(count + extra + 1, sizeof(*copy));
    if (!copy)
        return false;
    size_t output = 0;
    for (size_t index = 0; index < count; ++index) {
        if (!need_preload || strncmp(envp[index], "LD_PRELOAD=", 11) != 0)
            copy[output++] = envp[index];
    }
    if (need_preload)
        copy[output++] = preload_entry;
    if (request_entry && *request_entry)
        copy[output++] = (char *)request_entry;
    if (navigation_entry && *navigation_entry)
        copy[output++] = (char *)navigation_entry;
    copy[output] = NULL;
    *out_envp = copy;
    return true;
}

static int execve_renderer_with_preload(const char *filename,
                                        char *const argv[],
                                        char *const envp[]) {
    if (!renderer_command(argv))
        return next_execve ? next_execve(filename, argv, envp) : -1;
    if (pending_request_id[0]) {
        // Chromium's zygote passes the inherited environment to execve. Carry
        // the observer's request identity across that exec so the freshly
        // loaded renderer preload can emit a paired renderer_ready event.
        (void)setenv("XK_METRICS_RENDERER_REQUEST_ID", pending_request_id, 1);
        (void)setenv("XK_METRICS_RENDERER_NAV_ID", pending_navigation_id, 1);
    }
    char preload_entry[1024];
    char request_entry[256];
    char navigation_entry[128];
    char **new_envp = NULL;
    request_entry[0] = navigation_entry[0] = '\0';
    if (pending_request_id[0]) {
        snprintf(request_entry, sizeof(request_entry),
                 "XK_METRICS_RENDERER_REQUEST_ID=%s", pending_request_id);
        snprintf(navigation_entry, sizeof(navigation_entry),
                 "XK_METRICS_RENDERER_NAV_ID=%s", pending_navigation_id);
    }
    if (!add_renderer_preload(envp, &new_envp, preload_entry,
                              sizeof(preload_entry), request_entry,
                              navigation_entry))
        return next_execve ? next_execve(filename, argv, envp) : -1;
    int result = next_execve ? next_execve(filename, argv, new_envp) : -1;
    int saved_errno = errno;
    free(new_envp);
    errno = saved_errno;
    return result;
}

static int execveat_renderer_with_preload(int dirfd, const char *filename,
                                          char *const argv[],
                                          char *const envp[], int flags) {
    if (!renderer_command(argv))
        return next_execveat ? next_execveat(dirfd, filename, argv, envp, flags)
                             : (int)syscall(SYS_execveat, dirfd, filename,
                                             argv, envp, flags);
    if (pending_request_id[0]) {
        (void)setenv("XK_METRICS_RENDERER_REQUEST_ID", pending_request_id, 1);
        (void)setenv("XK_METRICS_RENDERER_NAV_ID", pending_navigation_id, 1);
    }
    char preload_entry[1024];
    char request_entry[256];
    char navigation_entry[128];
    char **new_envp = NULL;
    request_entry[0] = navigation_entry[0] = '\0';
    if (pending_request_id[0]) {
        snprintf(request_entry, sizeof(request_entry),
                 "XK_METRICS_RENDERER_REQUEST_ID=%s", pending_request_id);
        snprintf(navigation_entry, sizeof(navigation_entry),
                 "XK_METRICS_RENDERER_NAV_ID=%s", pending_navigation_id);
    }
    if (!add_renderer_preload(envp, &new_envp, preload_entry,
                              sizeof(preload_entry), request_entry,
                              navigation_entry))
        return next_execveat ? next_execveat(dirfd, filename, argv, envp, flags)
                             : (int)syscall(SYS_execveat, dirfd, filename,
                                             argv, envp, flags);
    int result = next_execveat
                     ? next_execveat(dirfd, filename, argv, new_envp, flags)
                     : (int)syscall(SYS_execveat, dirfd, filename, argv,
                                     new_envp, flags);
    int saved_errno = errno;
    free(new_envp);
    errno = saved_errno;
    return result;
}

int execve(const char *filename, char *const argv[], char *const envp[]) {
    return execve_renderer_with_preload(filename, argv, envp);
}

int execveat(int dirfd, const char *filename, char *const argv[],
            char *const envp[], int flags) {
    return execveat_renderer_with_preload(dirfd, filename, argv, envp, flags);
}

__attribute__((constructor)) static void initialize_lifecycle_preload(void) {
    required_symbol((void **)&next_epoll_wait, "epoll_wait");
    required_symbol((void **)&next_epoll_pwait, "epoll_pwait");
    required_symbol((void **)&next_epoll_pwait2, "epoll_pwait2");
    required_symbol((void **)&next_poll, "poll");
    required_symbol((void **)&next_ppoll, "ppoll");
    required_symbol((void **)&next_fork, "fork");
    required_symbol((void **)&next_execve, "execve");
    required_symbol((void **)&next_execveat, "execveat");
    required_symbol((void **)&next_openat, "openat");
    required_symbol((void **)&next_open, "open");
    const char *value = getenv("XK_METRICS_RUN_ID");
    if (value)
        snprintf(run_id, sizeof(run_id), "%s", value);
    value = getenv("XK_METRICS_NAV_ID");
    if (value)
        snprintf(navigation_id, sizeof(navigation_id), "%s", value);
    value = getenv("XK_METRICS_RENDERER_REQUEST_ID");
    if (value)
        snprintf(pending_request_id, sizeof(pending_request_id), "%s", value);
    value = getenv("XK_METRICS_RENDERER_NAV_ID");
    if (value)
        snprintf(pending_navigation_id, sizeof(pending_navigation_id), "%s", value);
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
    {
        pid_t pid = getpid();
        char instance[96];
        get_process_instance(pid, instance, sizeof(instance));
        append_probe_event("preload_attached", monotonic_time_ns(), pid,
                           getppid(), "unknown", instance, "", "", "", 0,
                           "preload-constructor", "");
    }
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

int epoll_pwait2(int epfd, struct epoll_event *events, int maxevents,
                 const struct timespec *timeout, const sigset_t *sigmask) {
    maybe_report_loop_ready();
    if (next_epoll_pwait2)
        return next_epoll_pwait2(epfd, events, maxevents, timeout, sigmask);
    errno = ENOSYS;
    return -1;
}

int poll(struct pollfd *fds, nfds_t count, int timeout) {
    maybe_report_loop_ready();
    if (next_poll)
        return next_poll(fds, count, timeout);
    errno = ENOSYS;
    return -1;
}

int ppoll(struct pollfd *fds, nfds_t count, const struct timespec *timeout,
          const sigset_t *sigmask) {
    maybe_report_loop_ready();
    if (next_ppoll)
        return next_ppoll(fds, count, timeout, sigmask);
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
        append_probe_event("zygote_fork_boundary", request_ns, getpid(),
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
