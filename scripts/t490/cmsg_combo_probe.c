#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    int sv[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, sv) != 0) {
        printf("[CMSG_COMBO] socketpair errno=%d (%s)\n", errno, strerror(errno));
        return 2;
    }
    int passcred = 1;
    if (setsockopt(sv[1], SOL_SOCKET, SO_PASSCRED, &passcred, sizeof(passcred)) != 0) {
        printf("[CMSG_COMBO] setsockopt errno=%d (%s)\n", errno, strerror(errno));
        return 3;
    }
    int payload_fd = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (payload_fd < 0) {
        printf("[CMSG_COMBO] open errno=%d (%s)\n", errno, strerror(errno));
        return 4;
    }

    char byte = 'x';
    struct iovec iov = {.iov_base = &byte, .iov_len = 1};
    char control[CMSG_SPACE(sizeof(int)) + CMSG_SPACE(sizeof(struct ucred))];
    memset(control, 0, sizeof(control));
    struct msghdr msg = {0};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control;
    msg.msg_controllen = sizeof(control);

    struct cmsghdr *rights = CMSG_FIRSTHDR(&msg);
    rights->cmsg_level = SOL_SOCKET;
    rights->cmsg_type = SCM_RIGHTS;
    rights->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(rights), &payload_fd, sizeof(payload_fd));
    struct cmsghdr *cred_hdr = CMSG_NXTHDR(&msg, rights);
    if (!cred_hdr) {
        printf("[CMSG_COMBO] CMSG_NXTHDR returned NULL before send\n");
        return 5;
    }
    struct ucred cred = {.pid = (pid_t)getpid(), .uid = (uid_t)getuid(), .gid = (gid_t)getgid()};
    cred_hdr->cmsg_level = SOL_SOCKET;
    cred_hdr->cmsg_type = SCM_CREDENTIALS;
    cred_hdr->cmsg_len = CMSG_LEN(sizeof(cred));
    memcpy(CMSG_DATA(cred_hdr), &cred, sizeof(cred));
    msg.msg_controllen = (size_t)((char *)cred_hdr - control) + CMSG_SPACE(sizeof(cred));

    if (sendmsg(sv[0], &msg, 0) != 1) {
        printf("[CMSG_COMBO] sendmsg errno=%d (%s)\n", errno, strerror(errno));
        return 6;
    }

    char recv_byte = 0;
    char recv_control[256];
    memset(recv_control, 0, sizeof(recv_control));
    struct iovec recv_iov = {.iov_base = &recv_byte, .iov_len = 1};
    struct msghdr recv_msg = {0};
    recv_msg.msg_iov = &recv_iov;
    recv_msg.msg_iovlen = 1;
    recv_msg.msg_control = recv_control;
    recv_msg.msg_controllen = sizeof(recv_control);
    if (recvmsg(sv[1], &recv_msg, 0) != 1) {
        printf("[CMSG_COMBO] recvmsg errno=%d (%s)\n", errno, strerror(errno));
        return 7;
    }

    int rights_count = 0;
    int cred_count = 0;
    int received_fd = -1;
    for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&recv_msg); cmsg;
         cmsg = CMSG_NXTHDR(&recv_msg, cmsg)) {
        if (cmsg->cmsg_level != SOL_SOCKET) continue;
        if (cmsg->cmsg_type == SCM_RIGHTS) {
            rights_count++;
            memcpy(&received_fd, CMSG_DATA(cmsg), sizeof(received_fd));
        } else if (cmsg->cmsg_type == SCM_CREDENTIALS) {
            cred_count++;
        }
    }
    printf("[CMSG_COMBO] byte=%c rights=%d creds=%d fd=%d flags=%#x controllen=%zu\n",
           recv_byte, rights_count, cred_count, received_fd, recv_msg.msg_flags,
           recv_msg.msg_controllen);
    if (received_fd >= 0) close(received_fd);
    close(payload_fd);
    close(sv[0]);
    close(sv[1]);
    if (rights_count != 1 || cred_count < 1 || recv_msg.msg_flags != 0) return 8;
    printf("[CMSG_COMBO_EXIT] 0 aligned_multi_cmsg_ok\n");
    return 0;
}
