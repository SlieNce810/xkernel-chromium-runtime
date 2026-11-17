// BUILD: static
//
// AF_UNIX 大消息 / 高频小消息探针。
//
// 为什么写它：
//   R3 轮的 AF_UNIX 观测账本**只记录 ≤256 B 的消息**（report/88 §4），
//   而 Chromium 的 Mojo 控制帧普遍大于 256 B，tile/文件内容更是 MB 级。
//   也就是说，真正承载 renderer 回执的那部分流量一直没有进过样本。
//   在继续加内核计数器之前，先用纯用户态把这条通道的**大数据语义**测干净：
//   如果 64 KiB 级别就出现短写、丢字节、或非阻塞 send 永久返回 0，
//   那 Mojo 握手卡住就有了内核侧的解释，不必再往 Chromium 内部找。
//
// 输出约定（一行一步，全部写 /dev/console）：
//   BULK step=<名字> rc=<0|-1> detail=<可判定字段>
//   BULK BEGIN pid=<pid>
//   BULK SUMMARY pass=<n> fail=<n>
// 判据：**同一份源码**在 T490 宿主（x86_64 Linux）与 guest（aarch64 x-kernel）
//       各跑一次，detail 必须逐字一致；rc=-1 的条目要在 Linux 上也是 -1。
//
// 时序纪律：每个 case 都有 SIGALRM 截止（默认 90 s），挂死时打印 TIMEOUT 后
//           立即 _exit(3)，不让一个 case 吃掉整轮会话。

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#define FNV_OFFSET 1469598103934665603ULL
#define FNV_PRIME 1099511628211ULL

#define CASE_TIMEOUT_S 90

static int con_fd = 1;
static int n_pass = 0;
static int n_fail = 0;
static volatile sig_atomic_t g_in_case = 0;
static const char *g_case_name = "?";

static void say(const char *fmt, ...) {
    char buf[600];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n > 0) {
        ssize_t w = write(con_fd, buf, (size_t)n);
        (void)w;
    }
}

static void on_alarm(int sig) {
    (void)sig;
    if (g_in_case) {
        const char *m = "BULK step=TIMEOUT rc=-1 detail=case_hung\n";
        ssize_t w = write(con_fd, m, strlen(m));
        (void)w;
        (void)g_case_name;
        _exit(3);
    }
}

static inline uint64_t fnv_byte(uint64_t h, unsigned char b) {
    return (h ^ b) * FNV_PRIME;
}

static inline unsigned char pat(size_t i) {
    return (unsigned char)((i * 31u + 7u) & 0xffu);
}

static void report(const char *name, int ok, const char *fmt, ...) {
    char detail[420];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(detail, sizeof(detail), fmt, ap);
    va_end(ap);
    if (ok) {
        n_pass++;
    } else {
        n_fail++;
    }
    g_in_case = 0;
    alarm(0);
    say("BULK step=%s rc=%d detail=%s\n", name, ok ? 0 : -1, detail);
}

struct child_result {
    uint64_t total;
    uint64_t hash;
    int last_errno;
    int reads;
};

/* 子进程侧：读到 EOF 为止，统计字节数与内容 hash。 */
static void child_drain(int fd, int out_fd) {
    struct child_result r;
    memset(&r, 0, sizeof(r));
    r.hash = FNV_OFFSET;
    static char buf[65536];
    for (;;) {
        ssize_t n = read(fd, buf, sizeof(buf));
        if (n == 0) {
            break;
        }
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            r.last_errno = errno;
            break;
        }
        for (ssize_t i = 0; i < n; i++) {
            r.hash = fnv_byte(r.hash, (unsigned char)buf[i]);
        }
        r.total += (uint64_t)n;
        r.reads++;
    }
    ssize_t w = write(out_fd, &r, sizeof(r));
    (void)w;
    close(fd);
    _exit(0);
}

/*
 * 阻塞式整块发送：父 send 全量后 shutdown(SHUT_WR)，子读到 EOF。
 * 这条路径对应 Mojo 的"发完一帧控制消息再等回执"。
 */
static void case_stream_blocking(const char *name, size_t total, int type) {
    int sv[2];
    int rp[2];
    if (socketpair(AF_UNIX, type, 0, sv) < 0) {
        report(name, 0, "socketpair_errno=%d", errno);
        return;
    }
    if (pipe(rp) < 0) {
        report(name, 0, "pipe_errno=%d", errno);
        close(sv[0]);
        close(sv[1]);
        return;
    }

    g_case_name = name;
    g_in_case = 1;
    alarm(CASE_TIMEOUT_S);

    pid_t pid = fork();
    if (pid == 0) {
        close(sv[0]);
        close(rp[0]);
        child_drain(sv[1], rp[1]);
    }
    close(sv[1]);
    close(rp[1]);

    static char buf[65536];
    size_t off = 0;
    int sends = 0;
    int send_errno = 0;
    while (off < total) {
        size_t chunk = total - off;
        if (chunk > sizeof(buf)) {
            chunk = sizeof(buf);
        }
        for (size_t i = 0; i < chunk; i++) {
            buf[i] = (char)pat(off + i);
        }
        ssize_t n = send(sv[0], buf, chunk, 0);
        if (n < 0) {
            if (errno == EINTR) {
                continue;
            }
            send_errno = errno;
            break;
        }
        if (n == 0) {
            send_errno = -1; /* 零进展视为异常，Linux 上不应出现 */
            break;
        }
        off += (size_t)n;
        sends++;
    }
    shutdown(sv[0], SHUT_WR);

    struct child_result r;
    memset(&r, 0, sizeof(r));
    ssize_t got = read(rp[0], &r, sizeof(r));
    close(rp[0]);
    close(sv[0]);
    int status = 0;
    waitpid(pid, &status, 0);

    uint64_t want_hash = FNV_OFFSET;
    for (size_t i = 0; i < total; i++) {
        want_hash = fnv_byte(want_hash, pat(i));
    }

    int ok = (got == (ssize_t)sizeof(r)) && send_errno == 0 &&
             r.total == (uint64_t)total && r.hash == want_hash;
    report(name, ok,
           "type=%s want=%zu sent=%zu sends=%d send_errno=%d recvd=%llu reads=%d "
           "hash_match=%d child_errno=%d",
           type == SOCK_SEQPACKET ? "seqpacket" : "stream", total, off, sends,
           send_errno, (unsigned long long)r.total, r.reads,
           (r.hash == want_hash) ? 1 : 0, r.last_errno);
}

/*
 * 非阻塞发送 + 并发接收：这是真实 IPC 的形态（发送方不能阻塞消息泵）。
 * 关注三件事：是否出现"返回 0 且无 errno"、EAGAIN 是否为唯一背压信号、
 * 以及对端并发读时总字节数是否仍然精确。
 */
static void case_stream_nonblock(size_t total) {
    int sv[2];
    int rp[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) {
        report("stream_nonblock", 0, "socketpair_errno=%d", errno);
        return;
    }
    if (pipe(rp) < 0) {
        report("stream_nonblock", 0, "pipe_errno=%d", errno);
        close(sv[0]);
        close(sv[1]);
        return;
    }

    g_case_name = "stream_nonblock";
    g_in_case = 1;
    alarm(CASE_TIMEOUT_S);

    pid_t pid = fork();
    if (pid == 0) {
        close(sv[0]);
        close(rp[0]);
        child_drain(sv[1], rp[1]);
    }
    close(sv[1]);
    close(rp[1]);

    int fl = fcntl(sv[0], F_GETFL, 0);
    if (fl < 0 || fcntl(sv[0], F_SETFL, fl | O_NONBLOCK) < 0) {
        report("stream_nonblock", 0, "fcntl_nonblock_errno=%d", errno);
        close(sv[0]);
        close(rp[0]);
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        return;
    }

    static char buf[65536];
    size_t off = 0;
    int sends = 0;
    int eagain = 0;
    int zero_returns = 0;
    int other_errno = 0;
    for (;;) {
        if (off >= total) {
            break;
        }
        size_t chunk = total - off;
        if (chunk > sizeof(buf)) {
            chunk = sizeof(buf);
        }
        for (size_t i = 0; i < chunk; i++) {
            buf[i] = (char)pat(off + i);
        }
        ssize_t n = send(sv[0], buf, chunk, 0);
        if (n > 0) {
            off += (size_t)n;
            sends++;
            continue;
        }
        if (n == 0) {
            zero_returns++;
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            eagain++;
            continue; /* 忙等重试，靠子进程并发读腾出空间 */
        }
        if (errno == EINTR) {
            continue;
        }
        other_errno = errno;
        break;
    }
    shutdown(sv[0], SHUT_WR);

    struct child_result r;
    memset(&r, 0, sizeof(r));
    ssize_t got = read(rp[0], &r, sizeof(r));
    close(rp[0]);
    close(sv[0]);
    int status = 0;
    waitpid(pid, &status, 0);

    uint64_t want_hash = FNV_OFFSET;
    for (size_t i = 0; i < total; i++) {
        want_hash = fnv_byte(want_hash, pat(i));
    }

    int ok = (got == (ssize_t)sizeof(r)) && other_errno == 0 &&
             zero_returns == 0 && r.total == (uint64_t)total &&
             r.hash == want_hash;
    report("stream_nonblock", ok,
           "want=%zu sent=%zu sends=%d eagain=%d zero_returns=%d other_errno=%d "
           "recvd=%llu reads=%d hash_match=%d child_errno=%d",
           total, off, sends, eagain, zero_returns, other_errno,
           (unsigned long long)r.total, r.reads,
           (r.hash == want_hash) ? 1 : 0, r.last_errno);
}

/*
 * 高频小消息：模拟 Mojo 控制帧的节奏。关注是否有丢消息（子进程 reads 数
 * 应等于父进程 sends 数；因为流式 socket 可能合并，故只要求字节数与 hash）。
 */
static void case_small_stream(int count, size_t size) {
    int sv[2];
    int rp[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) {
        report("small_stream", 0, "socketpair_errno=%d", errno);
        return;
    }
    if (pipe(rp) < 0) {
        report("small_stream", 0, "pipe_errno=%d", errno);
        close(sv[0]);
        close(sv[1]);
        return;
    }

    g_case_name = "small_stream";
    g_in_case = 1;
    alarm(CASE_TIMEOUT_S);

    pid_t pid = fork();
    if (pid == 0) {
        close(sv[0]);
        close(rp[0]);
        child_drain(sv[1], rp[1]);
    }
    close(sv[1]);
    close(rp[1]);

    char buf[256];
    size_t total = 0;
    int sends = 0;
    int send_errno = 0;
    uint64_t want_hash = FNV_OFFSET;
    for (int k = 0; k < count; k++) {
        for (size_t i = 0; i < size; i++) {
            buf[i] = (char)((k + (int)i) & 0xff);
            want_hash = fnv_byte(want_hash, (unsigned char)buf[i]);
        }
        ssize_t n = send(sv[0], buf, size, 0);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) {
                continue;
            }
            send_errno = (n == 0) ? -1 : errno;
            break;
        }
        if ((size_t)n != size) {
            send_errno = -2; /* 小消息出现短写，单独标记 */
            total += (size_t)n;
            break;
        }
        total += size;
        sends++;
    }
    shutdown(sv[0], SHUT_WR);

    struct child_result r;
    memset(&r, 0, sizeof(r));
    ssize_t got = read(rp[0], &r, sizeof(r));
    close(rp[0]);
    close(sv[0]);
    int status = 0;
    waitpid(pid, &status, 0);

    int ok = (got == (ssize_t)sizeof(r)) && send_errno == 0 && sends == count &&
             r.total == total && r.hash == want_hash;
    report("small_stream", ok,
           "count=%d size=%zu sent_msgs=%d sent_bytes=%zu send_errno=%d "
           "recvd=%llu hash_match=%d child_errno=%d",
           count, size, sends, total, send_errno, (unsigned long long)r.total,
           (r.hash == want_hash) ? 1 : 0, r.last_errno);
}

/*
 * MSG_PEEK 一致性：peek 不得消费数据。Chromium 的 message_pipe 在探测
 * "是否还有下一条消息"时会用到这个语义。
 */
static void case_peek(void) {
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) {
        report("peek", 0, "socketpair_errno=%d", errno);
        return;
    }
    g_case_name = "peek";
    g_in_case = 1;
    alarm(CASE_TIMEOUT_S);

    char out[64];
    for (size_t i = 0; i < sizeof(out); i++) {
        out[i] = (char)('A' + (i % 26));
    }
    ssize_t sn = send(sv[0], out, sizeof(out), 0);

    char peekbuf[64];
    memset(peekbuf, 0, sizeof(peekbuf));
    ssize_t pn = recv(sv[1], peekbuf, sizeof(peekbuf), MSG_PEEK);

    char realbuf[64];
    memset(realbuf, 0, sizeof(realbuf));
    ssize_t rn = recv(sv[1], realbuf, sizeof(realbuf), 0);

    int peek_ok = (pn == (ssize_t)sizeof(out)) &&
                  memcmp(peekbuf, out, sizeof(out)) == 0;
    int real_ok = (rn == (ssize_t)sizeof(out)) &&
                  memcmp(realbuf, out, sizeof(out)) == 0;
    close(sv[0]);
    close(sv[1]);

    report("peek", (sn == (ssize_t)sizeof(out)) && peek_ok && real_ok,
           "sent=%zd peek=%zd real=%zd peek_intact=%d real_intact=%d",
           sn, pn, rn, peek_ok ? 1 : 0, real_ok ? 1 : 0);
}

int main(int argc, char **argv) {
    con_fd = open("/dev/console", O_WRONLY);
    if (con_fd < 0) {
        con_fd = 1;
    }
    (void)argc;
    (void)argv;

    signal(SIGALRM, on_alarm);
    /* 不能让写端在子进程先退时把自己打死 */
    signal(SIGPIPE, SIG_IGN);

    say("BULK BEGIN pid=%d page=%ld\n", (int)getpid(), (long)sysconf(_SC_PAGESIZE));

    case_stream_blocking("stream_4k", 4096, SOCK_STREAM);
    case_stream_blocking("stream_64k", 65536, SOCK_STREAM);
    case_stream_blocking("stream_1m", 1024 * 1024, SOCK_STREAM);
    case_stream_nonblock(1024 * 1024);
    /* SEQPACKET 单条消息受 SO_SNDBUF 限制，用 8 KiB 探边界；errno 与 Linux 对齐 */
    case_stream_blocking("seqpacket_8k", 8192, SOCK_SEQPACKET);
    case_small_stream(5000, 128);
    case_peek();

    say("BULK SUMMARY pass=%d fail=%d\n", n_pass, n_fail);
    return n_fail == 0 ? 0 : 1;
}
