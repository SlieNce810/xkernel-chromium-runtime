/*
 * fdprobe.c — AF_UNIX SCM_RIGHTS 文件描述符跨进程传递探针
 *
 * 用途
 * ----
 * 判定 x-kernel 的 unix socket 能否把 fd 从进程 A 传到进程 B，并区分是
 * **SOCK_STREAM** 还是 **SOCK_DGRAM** 的问题。
 *
 * 为什么需要它
 * ------------
 * T490 v16 实测：weston compositor 起来后，desktop-shell 客户端立刻失败——
 *     libwayland: file descriptor expected, object (10), message create_pool(nhi)
 * Wayland 的 `wl_shm.create_pool` 必须把 memfd 传过 AF_UNIX **SOCK_STREAM** 连接。
 * 源码核查发现 `net/knet/src/unix/stream*.rs` 里 `ancillary` 出现 **0 次**，
 * 而 `unix/dgram.rs` 有 5 次 → 怀疑 stream 传输层整体丢弃了 ancillary。
 *
 * 本探针用四个用例证实/证伪，并作为补丁的**回归验收工具**：
 *   T1 STREAM 1 条消息带 1 个 fd（fork 跨进程）  期望 fd=1 且收到的 fd 真的可读写
 *   T2 STREAM 纯数据不带 fd                       期望 fd=0（证明数据通路本身是好的）
 *   T3 STREAM A(带fd) 紧跟 B(不带fd)，两次 recv   期望 fd 序列 = 1, 0（验证队列语义）
 *   T4 DGRAM 1 条消息带 1 个 fd                   正对照：dgram 已实现，应通过
 *
 * 判定口径：T2/T4 通过而 T1/T3 失败 → 缺口定位在 stream 传输层，而非用户态或 libc。
 *
 * 编译（宿主交叉编译，静态链接 musl）
 *     aarch64-linux-musl-gcc -static -O2 -o fdprobe fdprobe.c
 *
 * 运行（guest 内，root）
 *     /usr/bin/fdprobe
 *
 * 输出约定：每行形如 `[Tn] KEY=VALUE`，最后 `[RESULT] ...` 便于 grep 取证。
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#define TARGET_PATH "/tmp/fdprobe-target"
#define MAGIC_ORIGINAL "MAGIC-ORIGINAL-0123456789"
#define MAGIC_CHILD "CHILD-WROTE-9876543210"

static int g_pass = 0;
static int g_fail = 0;
/* T1 里子进程实际收到的 fd 个数；-1 = 没拿到观测值。
 * 这是整份探针最关键的一个数字：0 表示跨进程 fd 完全没送到。 */
static int g_t1_fd_count = -1;

#define T1_COUNT_PATH "/tmp/fdprobe-t1.count"

/* 子进程把观测到的 fd 个数落盘，供父进程汇总（父进程看不到子进程的 stdout 变量） */
static void write_count_file(const char *path, int count) {
    int f = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0644);
    if (f < 0) return;
    char b[32];
    int n = snprintf(b, sizeof(b), "%d\n", count);
    if (n > 0) {
        ssize_t w = write(f, b, (size_t)n);
        (void)w;
    }
    close(f);
}

static int read_count_file(const char *path) {
    int f = open(path, O_RDONLY);
    if (f < 0) return -1;
    char b[32];
    ssize_t n = read(f, b, sizeof(b) - 1);
    close(f);
    if (n <= 0) return -1;
    b[n] = '\0';
    return atoi(b);
}

static void verdict(const char *tag, const char *what, int ok) {
    printf("[%s] VERDICT_%s=%s  (%s)\n", tag, ok ? "PASS" : "FAIL", ok ? "PASS" : "FAIL", what);
    if (ok) g_pass++; else g_fail++;
}

/* 创建/重置目标文件，返回 fd（调用方负责 close） */
static int make_target(void) {
    int fd = open(TARGET_PATH, O_CREAT | O_TRUNC | O_RDWR, 0644);
    if (fd < 0) {
        printf("[SETUP] open(%s) failed errno=%d (%s)\n", TARGET_PATH, errno, strerror(errno));
        return -1;
    }
    if (write(fd, MAGIC_ORIGINAL, strlen(MAGIC_ORIGINAL)) != (ssize_t)strlen(MAGIC_ORIGINAL)) {
        printf("[SETUP] write target failed errno=%d\n", errno);
        close(fd);
        return -1;
    }
    lseek(fd, 0, SEEK_SET);
    return fd;
}

/*
 * 用 sendmsg 发一条消息。pass_fd >= 0 时附带 SCM_RIGHTS。
 * 返回 0 成功，-1 失败（并打印 errno）。
 */
static int send_msg(int sock, const char *data, size_t len, int pass_fd, const char *tag) {
    char cbuf[CMSG_SPACE(sizeof(int))];
    struct iovec iov;
    struct msghdr msg;

    memset(&msg, 0, sizeof(msg));
    memset(cbuf, 0, sizeof(cbuf));

    iov.iov_base = (void *)data;
    iov.iov_len = len;
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;

    if (pass_fd >= 0) {
        msg.msg_control = cbuf;
        msg.msg_controllen = sizeof(cbuf);
        struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
        c->cmsg_level = SOL_SOCKET;
        c->cmsg_type = SCM_RIGHTS;
        c->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(c), &pass_fd, sizeof(int));
        msg.msg_controllen = CMSG_SPACE(sizeof(int));
    }

    for (;;) {
        ssize_t n = sendmsg(sock, &msg, 0);
        if (n == (ssize_t)len) return 0;
        if (n < 0 && errno == EINTR) continue;
        printf("[%s] sendmsg(fd=%d) -> %zd errno=%d (%s)\n",
               tag, pass_fd, n, errno, strerror(errno));
        return -1;
    }
}

/*
 * 用 recvmsg 收一条消息，解析 SCM_RIGHTS。
 * out_fds[0..] 返回收到的 fd；返回值 = 收到的 fd 个数（负数表示 recvmsg 失败）。
 * 同时打印 msg_controllen / MSG_CTRUNC，便于定位"完全没带 cmsg"还是"带了但被截断"。
 */
static int recv_msg(int sock, char *buf, size_t buflen, int *out_fds, int max_fds, const char *tag) {
    char cbuf[CMSG_SPACE(sizeof(int) * 4)];
    struct iovec iov;
    struct msghdr msg;

    memset(&msg, 0, sizeof(msg));
    memset(cbuf, 0, sizeof(cbuf));

    iov.iov_base = buf;
    iov.iov_len = buflen;
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cbuf;
    msg.msg_controllen = sizeof(cbuf);

    ssize_t n;
    for (;;) {
        n = recvmsg(sock, &msg, 0);
        if (n >= 0 || errno != EINTR) break;
    }
    if (n < 0) {
        printf("[%s] recvmsg -> -1 errno=%d (%s)\n", tag, errno, strerror(errno));
        return -1;
    }

    int count = 0;
    int truncated = (msg.msg_flags & MSG_CTRUNC) ? 1 : 0;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&msg); c != NULL; c = CMSG_NXTHDR(&msg, c)) {
        if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
            size_t body = c->cmsg_len - CMSG_LEN(0);
            int nfd = (int)(body / sizeof(int));
            for (int i = 0; i < nfd && count < max_fds; i++) {
                int fd;
                memcpy(&fd, CMSG_DATA(c) + i * sizeof(int), sizeof(int));
                out_fds[count++] = fd;
            }
        }
    }

    printf("[%s] recvmsg bytes=%zd msg_controllen=%zu msg_flags=0x%x(CTRUNC=%d) fd_count=%d\n",
           tag, n, (size_t)msg.msg_controllen, (unsigned)msg.msg_flags, truncated, count);
    return count;
}

/* 校验收到的 fd 是否指向我们那个目标文件，且可读写 */
static int verify_fd(int fd, const char *tag) {
    char buf[64];
    memset(buf, 0, sizeof(buf));
    if (lseek(fd, 0, SEEK_SET) < 0) {
        printf("[%s] lseek(fd=%d) failed errno=%d\n", tag, fd, errno);
        return 0;
    }
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    if (n < 0) {
        printf("[%s] read(fd=%d) failed errno=%d (%s)\n", tag, fd, errno, strerror(errno));
        return 0;
    }
    buf[n] = '\0';
    int is_same = (strcmp(buf, MAGIC_ORIGINAL) == 0);
    printf("[%s] read(fd=%d)=\"%s\" same_as_original=%d\n", tag, fd, buf, is_same);
    if (!is_same) return 0;

    /* 通过收到的 fd 写回，再用新 open 读，证明是同一个 inode。
     *
     * 注意：目标文件比 MAGIC_CHILD 长，覆盖写只改了前 N 字节、尾部残留仍在，
     * 所以必须**按前缀比较**，不能要求整串相等（首版就是在这里误判成 FAIL 的）。 */
    if (lseek(fd, 0, SEEK_SET) < 0) return 0;
    if (write(fd, MAGIC_CHILD, strlen(MAGIC_CHILD)) != (ssize_t)strlen(MAGIC_CHILD)) {
        printf("[%s] write(fd=%d) failed errno=%d\n", tag, fd, errno);
        return 0;
    }
    int fresh = open(TARGET_PATH, O_RDONLY);
    if (fresh < 0) {
        printf("[%s] fresh open failed errno=%d\n", tag, errno);
        return 0;
    }
    memset(buf, 0, sizeof(buf));
    n = read(fresh, buf, sizeof(buf) - 1);
    close(fresh);
    if (n < 0) n = 0;
    buf[n] = '\0';
    size_t want = strlen(MAGIC_CHILD);
    int wrote_through = ((size_t)n >= want && memcmp(buf, MAGIC_CHILD, want) == 0);
    printf("[%s] fresh_read=\"%s\" len=%zd write_through_fd=%d\n", tag, buf, n, wrote_through);
    return wrote_through;
}

/* ---------- T1/T2/T3：SOCK_STREAM ---------- */

static int test_stream_single_fd(void) {
    const char *tag = "T1";
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) {
        printf("[%s] socketpair(STREAM) failed errno=%d\n", tag, errno);
        verdict(tag, "socketpair", 0);
        return 0;
    }
    int target = make_target();

    pid_t pid = fork();
    if (pid == 0) {
        close(sv[0]);
        char buf[64];
        int fds[4];
        int cnt = recv_msg(sv[1], buf, sizeof(buf), fds, 4, tag);
        write_count_file(T1_COUNT_PATH, cnt);
        int ok = 0;
        if (cnt == 1 && verify_fd(fds[0], tag)) {
            ok = 1;
            close(fds[0]);
        }
        printf("[%s] CHILD_EXIT ok=%d\n", tag, ok);
        _exit(ok ? 0 : 1);
    }
    close(sv[1]);
    if (send_msg(sv[0], "PING1", 5, target, tag) < 0) {
        verdict(tag, "sendmsg with fd", 0);
        close(sv[0]); if (target >= 0) close(target);
        waitpid(pid, NULL, 0);
        return 0;
    }
    int st = 0;
    waitpid(pid, &st, 0);
    g_t1_fd_count = read_count_file(T1_COUNT_PATH);
    printf("[%s] T1_fd_count=%d (0 = 跨进程 fd 完全没送到, 1 = 送到)\n", tag, g_t1_fd_count);
    int ok = (WIFEXITED(st) && WEXITSTATUS(st) == 0);
    verdict(tag, "STREAM 跨进程传 1 个 fd 且收到的 fd 可读写", ok);
    close(sv[0]);
    if (target >= 0) close(target);
    return ok;
}

static int test_stream_no_fd(void) {
    const char *tag = "T2";
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) {
        verdict(tag, "socketpair", 0);
        return 0;
    }
    pid_t pid = fork();
    if (pid == 0) {
        close(sv[0]);
        char buf[64];
        int fds[4];
        int cnt = recv_msg(sv[1], buf, sizeof(buf), fds, 4, tag);
        int data_ok = (strncmp(buf, "PLAIN", 5) == 0);
        int ok = (cnt == 0 && data_ok);
        printf("[%s] CHILD_EXIT data_ok=%d fd_count=%d ok=%d\n", tag, data_ok, cnt, ok);
        _exit(ok ? 0 : 1);
    }
    close(sv[1]);
    if (send_msg(sv[0], "PLAIN", 5, -1, tag) < 0) {
        verdict(tag, "sendmsg without fd", 0);
        close(sv[0]);
        waitpid(pid, NULL, 0);
        return 0;
    }
    int st = 0;
    waitpid(pid, &st, 0);
    int ok = (WIFEXITED(st) && WEXITSTATUS(st) == 0);
    verdict(tag, "STREAM 纯数据通路正常且不带多余 cmsg（fd=0）", ok);
    close(sv[0]);
    return ok;
}

static int test_stream_two_msgs(void) {
    const char *tag = "T3";
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) {
        verdict(tag, "socketpair", 0);
        return 0;
    }
    int target = make_target();

    pid_t pid = fork();
    if (pid == 0) {
        close(sv[0]);
        char buf[64];
        int fds[4];
        int c1 = recv_msg(sv[1], buf, 4, fds, 4, tag);
        int fd1 = (c1 > 0) ? fds[0] : -1;
        int c2 = recv_msg(sv[1], buf, 4, fds, 4, tag);
        int fd2 = (c2 > 0) ? fds[0] : -1;
        int usable = (fd1 >= 0) ? verify_fd(fd1, tag) : 0;
        int ok = (c1 == 1 && c2 == 0 && usable);
        printf("[%s] CHILD_EXIT fd_seq=%d,%d usable_first=%d\n", tag, c1, c2, usable);
        if (fd1 >= 0) close(fd1);
        if (fd2 >= 0) close(fd2);
        _exit(ok ? 0 : 1);
    }
    close(sv[1]);
    if (send_msg(sv[0], "AAAA", 4, target, tag) < 0 ||
        send_msg(sv[0], "BBBB", 4, -1, tag) < 0) {
        verdict(tag, "sendmsg A(+fd)+B", 0);
        close(sv[0]); if (target >= 0) close(target);
        waitpid(pid, NULL, 0);
        return 0;
    }
    int st = 0;
    waitpid(pid, &st, 0);
    int ok = (WIFEXITED(st) && WEXITSTATUS(st) == 0);
    verdict(tag, "A(+fd) 与 B(无fd) 分两次 recv，fd 序列应为 1,0", ok);
    close(sv[0]);
    if (target >= 0) close(target);
    return ok;
}

/* ---------- T4：SOCK_DGRAM（正对照，源码显示 dgram 已实现） ---------- */

static int test_dgram_single_fd(void) {
    const char *tag = "T4";
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) < 0) {
        verdict(tag, "socketpair(DGRAM)", 0);
        return 0;
    }
    int target = make_target();

    pid_t pid = fork();
    if (pid == 0) {
        close(sv[0]);
        char buf[64];
        int fds[4];
        int cnt = recv_msg(sv[1], buf, sizeof(buf), fds, 4, tag);
        int ok = 0;
        if (cnt == 1 && verify_fd(fds[0], tag)) {
            ok = 1;
            close(fds[0]);
        }
        printf("[%s] CHILD_EXIT ok=%d\n", tag, ok);
        _exit(ok ? 0 : 1);
    }
    close(sv[1]);
    if (send_msg(sv[0], "DGRM", 4, target, tag) < 0) {
        verdict(tag, "sendmsg DGRAM with fd", 0);
        close(sv[0]); if (target >= 0) close(target);
        waitpid(pid, NULL, 0);
        return 0;
    }
    int st = 0;
    waitpid(pid, &st, 0);
    int ok = (WIFEXITED(st) && WEXITSTATUS(st) == 0);
    verdict(tag, "DGRAM 传 1 个 fd（正对照）", ok);
    close(sv[0]);
    if (target >= 0) close(target);
    return ok;
}

int main(void) {
    printf("=== fdprobe: AF_UNIX SCM_RIGHTS 跨进程 fd 传递探针 ===\n");
    printf("[ENV] pid=%d CMSG_LEN(0)=%zu CMSG_SPACE(0)=%zu CMSG_SPACE(int)=%zu\n",
           (int)getpid(), (size_t)CMSG_LEN(0), (size_t)CMSG_SPACE(0), (size_t)CMSG_SPACE(sizeof(int)));

    test_stream_single_fd();
    test_stream_no_fd();
    test_stream_two_msgs();
    test_dgram_single_fd();

    printf("\n[RESULT] pass=%d fail=%d\n", g_pass, g_fail);
    printf("[RESULT] T1_fd_count=%d   <-- 核心判据：0 表示 AF_UNIX SOCK_STREAM 上 fd 未送达\n",
           g_t1_fd_count);
    if (g_t1_fd_count > 0) {
        printf("[SUMMARY] stream 已能把 fd 跨进程送达\n");
    } else {
        printf("[SUMMARY] stream 仍无法跨进程送达 fd\n");
    }
    if (g_fail == 0) {
        printf("[RESULT] ALL_PASS — stream/dgram 均可跨进程传 fd\n");
        return 0;
    }
    printf("[RESULT] HAD_FAILURE — 逐项看上面每个 T 的 fd_count 与 write_through_fd\n");
    return 1;
}
