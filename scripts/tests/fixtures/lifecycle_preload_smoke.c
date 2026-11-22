#define _GNU_SOURCE

#include <sys/epoll.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "--type=zygote") == 0) {
        pid_t child = fork();
        if (child < 0)
            return 5;
        if (child == 0) {
            (void)prctl(PR_SET_NAME, "CrRendererMain", 0, 0, 0);
            struct pollfd event = {.fd = -1, .events = POLLIN};
            struct timespec timeout = {.tv_sec = 0, .tv_nsec = 0};
            sigset_t mask;
            sigemptyset(&mask);
            (void)ppoll(&event, 1, &timeout, &mask);
            _exit(0);
        }
        int status = 0;
        if (waitpid(child, &status, 0) != child)
            return 6;
        return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : 7;
    }
    if (argc != 2)
        return 2;
    int fd = open(argv[1], O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return 3;
    close(fd);

    const char *wait_kind = getenv("LIFECYCLE_TEST_WAIT");
    if (wait_kind && strcmp(wait_kind, "poll") == 0) {
        struct pollfd event = {.fd = -1, .events = POLLIN};
        (void)poll(&event, 1, 0);
    } else if (wait_kind && strcmp(wait_kind, "ppoll") == 0) {
        struct pollfd event = {.fd = -1, .events = POLLIN};
        struct timespec timeout = {.tv_sec = 0, .tv_nsec = 0};
        sigset_t mask;
        sigemptyset(&mask);
        (void)ppoll(&event, 1, &timeout, &mask);
    } else {
        int epoll_fd = epoll_create1(EPOLL_CLOEXEC);
        if (epoll_fd < 0)
            return 4;
        struct epoll_event event;
        (void)epoll_wait(epoll_fd, &event, 1, 0);
        close(epoll_fd);
    }
    return 0;
}
