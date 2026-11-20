#define _GNU_SOURCE

#include <sys/epoll.h>
#include <fcntl.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 2)
        return 2;
    int fd = open(argv[1], O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return 3;
    close(fd);

    int epoll_fd = epoll_create1(EPOLL_CLOEXEC);
    if (epoll_fd < 0)
        return 4;
    struct epoll_event event;
    (void)epoll_wait(epoll_fd, &event, 1, 0);
    close(epoll_fd);
    return 0;
}
