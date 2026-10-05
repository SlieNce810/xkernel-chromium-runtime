/* Verify automatic Unix SO_PASSCRED delivery without an explicit user cmsg. */
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, pair) != 0) {
        printf("[PASSCRED] socketpair errno=%d (%s)\n", errno, strerror(errno));
        return 2;
    }
    int enabled = 1;
    if (setsockopt(pair[1], SOL_SOCKET, SO_PASSCRED, &enabled, sizeof(enabled)) != 0) {
        printf("[PASSCRED] setsockopt SO_PASSCRED errno=%d (%s)\n", errno, strerror(errno));
        return 3;
    }
    if (send(pair[0], "x", 1, 0) != 1) {
        printf("[PASSCRED] send errno=%d (%s)\n", errno, strerror(errno));
        return 4;
    }

    char byte = 0;
    struct iovec iov = { .iov_base = &byte, .iov_len = 1 };
    char control[CMSG_SPACE(sizeof(struct ucred))];
    memset(control, 0, sizeof(control));
    struct msghdr msg = {0};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control;
    msg.msg_controllen = sizeof(control);
    if (recvmsg(pair[1], &msg, 0) != 1) {
        printf("[PASSCRED] recvmsg errno=%d (%s)\n", errno, strerror(errno));
        return 5;
    }
    int found = 0;
    for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg); cmsg; cmsg = CMSG_NXTHDR(&msg, cmsg)) {
        if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_CREDENTIALS &&
            cmsg->cmsg_len >= CMSG_LEN(sizeof(struct ucred))) {
            struct ucred cred;
            memcpy(&cred, CMSG_DATA(cmsg), sizeof(cred));
            printf("[PASSCRED] received pid=%d uid=%d gid=%d expected_pid=%d\n",
                   cred.pid, cred.uid, cred.gid, getpid());
            found = cred.pid == getpid() && cred.uid == getuid() && cred.gid == getgid();
        }
    }
    close(pair[0]);
    close(pair[1]);
    printf("[PASSCRED_EXIT] %d verdict=%s\n", found ? 0 : 6, found ? "AUTO_CREDENTIALS_OK" : "AUTO_CREDENTIALS_MISSING");
    return found ? 0 : 6;
}
