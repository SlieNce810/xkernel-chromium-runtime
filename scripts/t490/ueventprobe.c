/* Prove that writing sysfs eventN/uevent reaches a NETLINK_KOBJECT_UEVENT subscriber. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/netlink.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    int fd = socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC, NETLINK_KOBJECT_UEVENT);
    if (fd < 0) {
        printf("[UEVENT_PROBE] socket failed errno=%d (%s)\n", errno, strerror(errno));
        return 2;
    }

    struct sockaddr_nl addr;
    memset(&addr, 0, sizeof(addr));
    addr.nl_family = AF_NETLINK;
    addr.nl_pid = (unsigned)getpid();
    addr.nl_groups = 1;
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        printf("[UEVENT_PROBE] bind group1 failed errno=%d (%s)\n", errno, strerror(errno));
        close(fd);
        return 3;
    }

    int uevent = open("/sys/class/input/event0/uevent", O_WRONLY | O_CLOEXEC);
    if (uevent < 0) {
        printf("[UEVENT_PROBE] open sysfs uevent failed errno=%d (%s)\n", errno, strerror(errno));
        close(fd);
        return 4;
    }
    ssize_t written = write(uevent, "add\n", 4);
    int write_errno = errno;
    close(uevent);
    printf("[UEVENT_PROBE] write action=add rc=%ld errno=%d\n", (long)written, write_errno);
    if (written != 4) {
        close(fd);
        return 5;
    }

    struct pollfd pfd = { .fd = fd, .events = POLLIN };
    int ready = poll(&pfd, 1, 3000);
    if (ready <= 0) {
        printf("[UEVENT_PROBE] poll rc=%d errno=%d (%s)\n", ready, errno, strerror(errno));
        close(fd);
        return 6;
    }

    char payload[4096];
    ssize_t count = recv(fd, payload, sizeof(payload) - 1, 0);
    close(fd);
    if (count < 0) {
        printf("[UEVENT_PROBE] recv failed errno=%d (%s)\n", errno, strerror(errno));
        return 7;
    }
    payload[count] = '\0';
    printf("[UEVENT_PROBE] received %ld bytes:\n", (long)count);
    for (size_t at = 0; at < (size_t)count;) {
        size_t left = (size_t)count - at;
        size_t len = strnlen(payload + at, left);
        if (len == 0) {
            at++;
            continue;
        }
        printf("  %.*s\n", (int)len, payload + at);
        at += len + 1;
    }
    if (!memmem(payload, (size_t)count, "ACTION=add", sizeof("ACTION=add") - 1) ||
        !memmem(payload, (size_t)count, "SUBSYSTEM=input", sizeof("SUBSYSTEM=input") - 1) ||
        !memmem(payload, (size_t)count, "DEVNAME=input/event0", sizeof("DEVNAME=input/event0") - 1))
        return 8;

    printf("[UEVENT_PROBE_EXIT] 0 verdict=UEVENT_DELIVERED\n");
    return 0;
}
