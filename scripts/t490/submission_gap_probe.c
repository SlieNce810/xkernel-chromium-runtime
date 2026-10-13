/* Observable ABI checks for gaps not covered by the existing socket probes. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int failures;
static void check(const char *name, int ok, long value, int error)
{
    printf("[GAP] %s %s value=%ld errno=%d\n", name, ok ? "PASS" : "FAIL", value, error);
    failures += !ok;
}

static void file_excerpt(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) { printf("[OBS] %s unavailable errno=%d\n", path, errno); return; }
    char line[256];
    int count = 0;
    while (fgets(line, sizeof(line), f) && count < 4) {
        if (strstr(path, "status") && !strstr(line, "Threads:") && !strstr(line, "VmRSS:") && !strstr(line, "State:")) continue;
        printf("[OBS] %s %s", path, line);
        count++;
    }
    fclose(f);
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc == 2 && strcmp(argv[1], "--inherit-fd") == 0) {
        char c = 0;
        return read(3, &c, 1) == 1 && c == 'q' ? 0 : 2;
    }
    printf("[SCOPE] basic fd/ppoll/procfs/prctl/TCP/PI-limit checks; no Chromium zygote protocol or hardware input verdict\n");
    int pipes[2];
    if (pipe(pipes) == 0) {
        errno = 0;
        int duplicate = fcntl(pipes[0], F_DUPFD, 100);
        check("G1.fcntl_lower_bound", duplicate >= 100, duplicate, errno);
        if (duplicate >= 0) close(duplicate);
        write(pipes[1], "q", 1);
        pid_t child = fork();
        if (child == 0) {
            close(pipes[1]);
            if (pipes[0] != 3 && dup3(pipes[0], 3, 0) < 0) _exit(3);
            execl(argv[0], argv[0], "--inherit-fd", (char *)NULL);
            _exit(4);
        }
        int status = 0;
        pid_t waited = child > 0 ? waitpid(child, &status, 0) : -1;
        check("G1.fd3_fork_exec", waited == child && child > 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0, status, errno);
        close(pipes[0]); close(pipes[1]);
    } else check("G1.pipe_setup", 0, -1, errno);
    if (pipe(pipes) == 0) {
        write(pipes[1], "p", 1);
        struct pollfd fd = {.fd = pipes[0], .events = POLLIN};
        struct timespec timeout = {.tv_sec = 0, .tv_nsec = 100000000};
        errno = 0;
        int result = ppoll(&fd, 1, &timeout, NULL);
        check("G3.native_ppoll_ready", result == 1 && (fd.revents & POLLIN), result, errno);
        /* 414 is NOT Linux AArch64's native ppoll ABI. Record, don't assert. */
#if defined(__aarch64__)
        fd.revents = 0; errno = 0;
        long raw = syscall(414, &fd, 1, &timeout, NULL, 8);
        printf("[OBS] G3.aarch64_raw_414 rc=%ld errno=%d revents=%d native_ppoll_sysno=%ld\n", raw, errno, fd.revents, (long)SYS_ppoll);
#endif
        close(pipes[0]); close(pipes[1]);
    }
    file_excerpt("/proc/self/status"); file_excerpt("/proc/self/statm");
    file_excerpt("/proc/meminfo"); file_excerpt("/proc/uptime");
    struct timespec delay = {.tv_sec = 0, .tv_nsec = 200000000};
    nanosleep(&delay, NULL); file_excerpt("/proc/uptime");
    errno = 0;
    int result = prctl(PR_SET_PDEATHSIG, SIGTERM);
    check("G5.set_pdeathsig", result == 0, result, errno);
    int signal_number = -1;
    errno = 0; result = prctl(PR_GET_PDEATHSIG, &signal_number);
    check("G5.get_pdeathsig", result == 0 && signal_number == SIGTERM, signal_number, errno);
    prctl(PR_SET_PDEATHSIG, 0);
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock >= 0) {
        int options[] = {TCP_KEEPIDLE, TCP_KEEPINTVL, TCP_KEEPCNT};
        int values[] = {60, 10, 3};
        const char *names[] = {"G6.TCP_KEEPIDLE", "G6.TCP_KEEPINTVL", "G6.TCP_KEEPCNT"};
        for (int i = 0; i < 3; i++) {
            errno = 0; int set = setsockopt(sock, IPPROTO_TCP, options[i], &values[i], sizeof(int));
            int got = 0; socklen_t size = sizeof(got);
            int get = getsockopt(sock, IPPROTO_TCP, options[i], &got, &size);
            check(names[i], set == 0 && get == 0 && got == values[i], got, errno);
        }
        close(sock);
    } else check("G6.socket_setup", 0, -1, errno);
    int futex_word = 0;
    errno = 0;
    long pi = syscall(SYS_futex, &futex_word, 6 | 128, 0, NULL, NULL, 0);
    int pi_error = errno;
    printf("[OBS] G7.FUTEX_LOCK_PI_PRIVATE rc=%ld errno=%d (Linux supports PI; guest may expose unsupported feature)\n", pi, pi_error);
    if (pi == 0) syscall(SYS_futex, &futex_word, 7 | 128, 0, NULL, NULL, 0);
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit) == 0) {
        printf("[OBS] G7.RLIMIT_NOFILE soft=%llu hard=%llu\n", (unsigned long long)limit.rlim_cur, (unsigned long long)limit.rlim_max);
        struct rlimit requested = limit;
        requested.rlim_cur = 65536;
        errno = 0; result = setrlimit(RLIMIT_NOFILE, &requested);
        printf("[OBS] G7.set_soft_65536 rc=%d errno=%d (original hard limit preserved)\n", result, errno);
        setrlimit(RLIMIT_NOFILE, &limit);
    }
    printf("[GAP_SUMMARY] failures=%d; observations and untested branches are separate\n", failures);
    return failures ? 1 : 0;
}
