/* Pathname AF_UNIX SOCK_SEQPACKET connect/listen/accept control-channel probe. */
#define _GNU_SOURCE
#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#define PATHNAME "/run/xk-seqpacket-probe.sock"

static int fail(const char *step)
{
    printf("[SEQPACKET] %s FAILED errno=%d (%s)\n", step, errno, strerror(errno));
    unlink(PATHNAME);
    return 1;
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    unlink(PATHNAME);

    int server = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (server < 0) return fail("socket(server)");
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, PATHNAME, sizeof(PATHNAME));
    socklen_t address_len = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + sizeof(PATHNAME));

    if (bind(server, (struct sockaddr *)&address, address_len) != 0) return fail("bind");
    if (listen(server, 1) != 0) return fail("listen");

    int client = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0);
    if (client < 0) return fail("socket(client)");
    if (connect(client, (struct sockaddr *)&address, address_len) != 0) return fail("connect");
    int accepted = accept(server, NULL, NULL);
    if (accepted < 0) return fail("accept");

    const char request[] = "udev-control-request";
    if (send(client, request, sizeof(request), 0) != (ssize_t)sizeof(request))
        return fail("send(request)");
    char buffer[64] = {0};
    ssize_t got = recv(accepted, buffer, sizeof(buffer), 0);
    if (got != (ssize_t)sizeof(request) || memcmp(buffer, request, sizeof(request)) != 0)
        return fail("recv(request)");

    const char response[] = "udev-control-response";
    if (send(accepted, response, sizeof(response), 0) != (ssize_t)sizeof(response))
        return fail("send(response)");
    memset(buffer, 0, sizeof(buffer));
    got = recv(client, buffer, sizeof(buffer), 0);
    if (got != (ssize_t)sizeof(response) || memcmp(buffer, response, sizeof(response)) != 0)
        return fail("recv(response)");

    printf("[SEQPACKET] socket/bind/listen/connect/accept + one control roundtrip PASS\n");
    close(accepted);
    close(client);
    close(server);
    unlink(PATHNAME);
    printf("[SEQPACKET_EXIT] 0 verdict=PATH_SOCKET_OK\n");
    return 0;
}
