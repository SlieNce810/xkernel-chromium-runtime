/* Verify SCM_RIGHTS over the pathname SOCK_SEQPACKET bridge used by libseat. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/un.h>
#include <unistd.h>

#define IOC_NRBITS 8
#define IOC_TYPEBITS 8
#define IOC_SIZEBITS 14
#define IOC_DIRBITS 2
#define IOC_NRSHIFT 0
#define IOC_TYPESHIFT (IOC_NRSHIFT + IOC_NRBITS)
#define IOC_SIZESHIFT (IOC_TYPESHIFT + IOC_TYPEBITS)
#define IOC_DIRSHIFT (IOC_SIZESHIFT + IOC_SIZEBITS)
#define IOC_READ 2U
#define IOC(dir, type, nr, size) \
    ((unsigned long)(((dir) << IOC_DIRSHIFT) | ((type) << IOC_TYPESHIFT) | \
                     ((nr) << IOC_NRSHIFT) | ((size) << IOC_SIZESHIFT)))
#define _IOR(type, nr, size) IOC(IOC_READ, (type), (nr), sizeof(size))
#define EVIOCGID _IOR('E', 0x02, struct input_id)
#define EVIOCGNAME(len) IOC(IOC_READ, 'E', 0x06, (len))

struct input_id {
    unsigned short bustype;
    unsigned short vendor;
    unsigned short product;
    unsigned short version;
};

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *sock_path = "/run/fdpassprobe.sock";
    unlink(sock_path);

    int listener = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (listener < 0) {
        printf("[FDPASS] server socket errno=%d (%s)\n", errno, strerror(errno));
        return 2;
    }
    struct sockaddr_un addr = { .sun_family = AF_UNIX };
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);
    if (bind(listener, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(listener, 1) != 0) {
        printf("[FDPASS] bind/listen errno=%d (%s)\n", errno, strerror(errno));
        return 3;
    }

    int client = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (client < 0 || connect(client, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        printf("[FDPASS] client connect errno=%d (%s)\n", errno, strerror(errno));
        return 4;
    }
    int server = accept(listener, NULL, NULL);
    if (server < 0) {
        printf("[FDPASS] accept errno=%d (%s)\n", errno, strerror(errno));
        return 5;
    }

    int input_fd = open("/dev/input/event0", O_RDONLY | O_CLOEXEC);
    if (input_fd < 0) {
        printf("[FDPASS] open input errno=%d (%s)\n", errno, strerror(errno));
        return 6;
    }

    char sent = 'x';
    struct iovec send_iov = { .iov_base = &sent, .iov_len = 1 };
    char send_control[CMSG_SPACE(sizeof(int))];
    memset(send_control, 0, sizeof(send_control));
    struct msghdr send_msg = {0};
    send_msg.msg_iov = &send_iov;
    send_msg.msg_iovlen = 1;
    send_msg.msg_control = send_control;
    send_msg.msg_controllen = sizeof(send_control);
    struct cmsghdr *send_cmsg = CMSG_FIRSTHDR(&send_msg);
    send_cmsg->cmsg_level = SOL_SOCKET;
    send_cmsg->cmsg_type = SCM_RIGHTS;
    send_cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(send_cmsg), &input_fd, sizeof(input_fd));
    ssize_t sent_count = sendmsg(server, &send_msg, 0);
    if (sent_count != 1) {
        printf("[FDPASS] sendmsg rc=%ld errno=%d (%s)\n", (long)sent_count, errno, strerror(errno));
        return 7;
    }

    char received = 0;
    struct iovec recv_iov = { .iov_base = &received, .iov_len = 1 };
    char recv_control[CMSG_SPACE(sizeof(int))];
    memset(recv_control, 0, sizeof(recv_control));
    struct msghdr recv_msg = {0};
    recv_msg.msg_iov = &recv_iov;
    recv_msg.msg_iovlen = 1;
    recv_msg.msg_control = recv_control;
    recv_msg.msg_controllen = sizeof(recv_control);
    ssize_t recv_count = recvmsg(client, &recv_msg, 0);
    if (recv_count != 1) {
        printf("[FDPASS] recvmsg rc=%ld errno=%d (%s)\n", (long)recv_count, errno, strerror(errno));
        return 8;
    }
    int received_fd = -1;
    for (struct cmsghdr *cmsg = CMSG_FIRSTHDR(&recv_msg); cmsg != NULL; cmsg = CMSG_NXTHDR(&recv_msg, cmsg)) {
        if (cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS &&
            cmsg->cmsg_len >= CMSG_LEN(sizeof(int))) {
            memcpy(&received_fd, CMSG_DATA(cmsg), sizeof(received_fd));
            break;
        }
    }
    if (received_fd < 0) {
        printf("[FDPASS] SCM_RIGHTS missing flags=%#x controllen=%zu\n", recv_msg.msg_flags, recv_msg.msg_controllen);
        return 9;
    }

    struct input_id id = {0};
    char name[128] = {0};
    int id_rc = ioctl(received_fd, EVIOCGID, &id);
    int name_rc = ioctl(received_fd, EVIOCGNAME(sizeof(name) - 1), name);
    printf("[FDPASS] received_fd=%d id_rc=%d name_rc=%d name=%s dev=%04x:%04x\n",
           received_fd, id_rc, name_rc, name, id.bustype, id.product);
    close(received_fd);
    close(input_fd);
    close(server);
    close(client);
    close(listener);
    unlink(sock_path);
    if (id_rc < 0 || name_rc < 0 || strstr(name, "Virtio") == NULL) return 10;
    printf("[FDPASS_EXIT] 0 verdict=SCM_RIGHTS_DEVICE_IOCTL_OK\n");
    return 0;
}
