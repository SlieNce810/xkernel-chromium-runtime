#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int fail(const char *step) {
    printf("[SBOXIPC] %s FAILED errno=%d (%s)\n", step, errno, strerror(errno));
    return 1;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    int ctl[2] = {-1, -1};
    int reply[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, ctl) != 0)
        return fail("socketpair control");
    if (shutdown(ctl[0], SHUT_RD) != 0)
        return fail("shutdown child SHUT_RD");
    if (shutdown(ctl[1], SHUT_WR) != 0)
        return fail("shutdown browser SHUT_WR");
    if (socketpair(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0, reply) != 0)
        return fail("socketpair reply");

    const char payload[] = "sandbox-ipc-request";
    struct iovec iov = {.iov_base = (void *)payload, .iov_len = sizeof(payload)};
    char control[CMSG_SPACE(sizeof(int))];
    memset(control, 0, sizeof(control));
    struct msghdr msg = {
        .msg_iov = &iov,
        .msg_iovlen = 1,
        .msg_control = control,
        .msg_controllen = sizeof(control),
    };
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(reply[0]));
    memcpy(CMSG_DATA(cmsg), &reply[0], sizeof(reply[0]));
    msg.msg_controllen = cmsg->cmsg_len;

    ssize_t sent = sendmsg(ctl[0], &msg, 0);
    if (sent != (ssize_t)sizeof(payload))
        return fail("sendmsg control + SCM_RIGHTS");

    char received[128] = {0};
    struct iovec riov = {.iov_base = received, .iov_len = sizeof(received)};
    char received_control[CMSG_SPACE(sizeof(int))];
    memset(received_control, 0, sizeof(received_control));
    struct msghdr rmsg = {
        .msg_iov = &riov,
        .msg_iovlen = 1,
        .msg_control = received_control,
        .msg_controllen = sizeof(received_control),
    };
    ssize_t got = recvmsg(ctl[1], &rmsg, MSG_CMSG_CLOEXEC);
    if (got != (ssize_t)sizeof(payload) || memcmp(received, payload, sizeof(payload)) != 0)
        return fail("recvmsg control payload");
    int received_fd = -1;
    cmsg = CMSG_FIRSTHDR(&rmsg);
    if (!cmsg || cmsg->cmsg_level != SOL_SOCKET || cmsg->cmsg_type != SCM_RIGHTS ||
        cmsg->cmsg_len < CMSG_LEN(sizeof(received_fd)))
        return fail("recvmsg SCM_RIGHTS header");
    memcpy(&received_fd, CMSG_DATA(cmsg), sizeof(received_fd));
    if (received_fd < 0)
        return fail("recvmsg SCM_RIGHTS fd");
    int fdflags = fcntl(received_fd, F_GETFD);
    if (fdflags < 0 || !(fdflags & FD_CLOEXEC))
        return fail("MSG_CMSG_CLOEXEC flag");

    const char response[] = "sandbox-ipc-response";
    if (send(received_fd, response, sizeof(response), 0) != (ssize_t)sizeof(response))
        return fail("send response over received fd");
    char response_buf[128] = {0};
    if (recv(reply[1], response_buf, sizeof(response_buf), 0) != (ssize_t)sizeof(response) ||
        memcmp(response_buf, response, sizeof(response)) != 0)
        return fail("recv response on temporary socket");

    errno = 0;
    if (send(ctl[1], "x", 1, 0) >= 0 || (errno != EPIPE && errno != ENOTCONN))
        return fail("browser SHUT_WR enforcement");
    printf("[SBOXIPC] socketpair shutdown + SCM_RIGHTS + MSG_CMSG_CLOEXEC + reply PASS\n");
    close(received_fd);
    close(reply[0]);
    close(reply[1]);
    close(ctl[0]);
    close(ctl[1]);
    printf("[SBOXIPC_EXIT] 0 verdict=SANDBOX_IPC_SOCKETPAIR_OK\n");
    return 0;
}
