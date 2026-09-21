/*
 * p2probe.c — 直接验证 P2 补丁的两处修复（不依赖 Chromium 日志推断）
 *
 * 验证项
 * ------
 * 【SCHED】musl 的 `pthread_getschedparam` 传的是**目标线程的内核 tid**：
 *              __syscall(SYS_sched_getparam, t->tid, param);
 *          补丁前 x-kernel 的 `scheduler_target()` 只按 tgid 查进程，于是任何
 *          **非主线程**调用都会得到 ESRCH(3)（Chromium/absl 实测：
 *          `[mutex.cc : 956] RAW: pthread_getschedparam failed: 3`）。
 *          本探针分别在主线程与子线程上调用，判定 tid 解析是否修好。
 *
 * 【NETLINK】Chromium 的 `AddressTrackerLinux` 无条件用 `nl_groups` 订阅路由组，
 *          补丁前 `NetlinkSocket::bind()` 对 NETLINK_ROUTE + groups!=0 直接返回
 *          EOPNOTSUPP(95)（实测：`Could not bind NETLINK socket: Not supported (95)`）。
 *          本探针做 groups=0（对照）与 groups!=0（目标）两次 bind。
 *
 * 编译（宿主交叉编译，静态 musl）
 *     aarch64-linux-musl-gcc -static -O2 -Wall -Wextra -pthread -o p2probe p2probe.c
 * 运行（guest 内）
 *     /p2probe
 *
 * 输出约定：`[SCHED] ...` / `[NETLINK] ...` 明细，`KEY=PASS|FAIL` 汇总行便于 grep。
 *
 * 注：为避免内核头文件差异，Linux ABI 常量与 syscall 号直接写死（aarch64 generic）。
 */

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef AF_NETLINK
#define AF_NETLINK 16
#endif
#ifndef SOCK_RAW
#define SOCK_RAW 3
#endif
#define NETLINK_ROUTE_ 0

#ifndef SYS_gettid
#define SYS_gettid 178
#endif
#ifndef SYS_sched_getparam
#define SYS_sched_getparam 121
#endif
#ifndef SYS_sched_getscheduler
#define SYS_sched_getscheduler 120
#endif

/* Linux 的 struct sockaddr_nl（aarch64 上 nl_family/nl_pad 各 2 字节，后两个 u32） */
struct sockaddr_nl_abi {
    unsigned short nl_family;
    unsigned short nl_pad;
    unsigned int nl_pid;
    unsigned int nl_groups;
};

/* RTMGRP_* 的典型组合：LINK | IPV4_IFADDR | IPV4_ROUTE */
#define GROUPS_CHROMIUM_LIKE (1u | 4u | 8u)

static int g_fail = 0;

static void verdict(const char *key, int ok, const char *what) {
    printf("[%s] %s=%s  (%s)\n", key, key, ok ? "PASS" : "FAIL", what);
    if (!ok) g_fail++;
}

/* ------------------------------------------------------------------ SCHED */

static void probe_sched_main(void) {
    struct sched_param param;
    memset(&param, 0, sizeof(param));
    param.sched_priority = -12345;

    errno = 0;
    int r = (int)syscall(SYS_sched_getparam, 0, &param);
    printf("[SCHED] sched_getparam(pid=0) -> %d errno=%d (%s) prio=%d\n",
           r, errno, strerror(errno), param.sched_priority);
    verdict("SCHED_PID0", r == 0, "主线程按 pid=0 查询（对照，补丁前后都应通过）");

    errno = 0;
    int pol = (int)syscall(SYS_sched_getscheduler, 0);
    printf("[SCHED] sched_getscheduler(pid=0) -> %d errno=%d (%s)\n", pol, errno, strerror(errno));
    verdict("SCHED_PID0_POLICY", pol >= 0, "主线程查询策略");
}

static void *thread_main(void *arg) {
    (void)arg;
    pid_t tid = (pid_t)syscall(SYS_gettid);
    pid_t pid = (pid_t)getpid();
    printf("[SCHED] 子线程: gettid=%d getpid=%d (tid != pid ⇒ 这是本项的关键)\n", (int)tid, (int)pid);

    struct sched_param param;
    memset(&param, 0, sizeof(param));
    param.sched_priority = -12345;
    errno = 0;
    int r = (int)syscall(SYS_sched_getparam, (int)tid, &param);
    printf("[SCHED] raw sched_getparam(tid=%d) -> %d errno=%d (%s) prio=%d\n",
           (int)tid, r, errno, strerror(errno), param.sched_priority);
    verdict("SCHED_THREAD_TID", r == 0, "子线程按**自己的 tid** 查询（补丁前应为 ESRCH=3）");

    errno = 0;
    int pol = (int)syscall(SYS_sched_getscheduler, (int)tid);
    printf("[SCHED] raw sched_getscheduler(tid=%d) -> %d errno=%d (%s)\n",
           (int)tid, pol, errno, strerror(errno));
    verdict("SCHED_THREAD_TID_POLICY", pol >= 0, "子线程按 tid 查询策略");

    /* 真正和 Chromium 一致的用户态入口 */
    int policy = -1;
    struct sched_param p2;
    memset(&p2, 0, sizeof(p2));
    errno = 0;
    int rc = pthread_getschedparam(pthread_self(), &policy, &p2);
    printf("[SCHED] pthread_getschedparam(pthread_self()) -> rc=%d errno=%d (%s) policy=%d prio=%d\n",
           rc, errno, strerror(errno), policy, p2.sched_priority);
    verdict("SCHED_PTHREAD_GETSCHEDPARAM", rc == 0 && policy >= 0,
            "musl pthread_getschedparam —— Chromium/absl 实际走的路径");

    return NULL;
}

/* ---------------------------------------------------------------- NETLINK */

static int nl_bind_once(unsigned int groups, const char *label) {
    int fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_ROUTE_);
    if (fd < 0) {
        printf("[NETLINK] %s: socket() -> -1 errno=%d (%s)\n", label, errno, strerror(errno));
        return -1;
    }

    struct sockaddr_nl_abi a;
    memset(&a, 0, sizeof(a));
    a.nl_family = AF_NETLINK;
    a.nl_pid = 0;
    a.nl_groups = groups;

    errno = 0;
    int r = bind(fd, (struct sockaddr *)&a, sizeof(a));
    printf("[NETLINK] %s: bind(fd=%d, nl_groups=0x%x) -> %d errno=%d (%s)\n",
           label, fd, groups, r, errno, strerror(errno));
    close(fd);
    return r;
}

static void probe_netlink(void) {
    int r0 = nl_bind_once(0, "groups=0 对照");
    verdict("NETLINK_BIND_NO_GROUPS", r0 == 0, "不带多播组的 bind（对照，补丁前后都应通过）");

    errno = 0;
    int r1 = nl_bind_once(GROUPS_CHROMIUM_LIKE, "groups!=0 目标");
    verdict("NETLINK_BIND_GROUPS", r1 == 0,
            "带 RTMGRP 多播组的 bind —— Chromium AddressTrackerLinux 的用法（补丁前应为 EOPNOTSUPP=95）");
}

int main(void) {
    printf("=== p2probe: sched tid 解析 + netlink 多播组 bind ===\n");
    printf("[ENV] pid=%d tid=%d\n", (int)getpid(), (int)syscall(SYS_gettid));

    probe_sched_main();

    pthread_t th;
    errno = 0;
    if (pthread_create(&th, NULL, thread_main, NULL) == 0) {
        pthread_join(th, NULL);
    } else {
        printf("[SCHED] pthread_create 失败 errno=%d (%s)\n", errno, strerror(errno));
        verdict("SCHED_THREAD_CREATE", 0, "创建子线程");
    }

    probe_netlink();

    printf("\n[RESULT] fail=%d\n", g_fail);
    if (g_fail == 0) {
        printf("[RESULT] ALL_PASS — P2 两处修复均生效\n");
        return 0;
    }
    printf("[RESULT] HAD_FAILURE — 逐项看上面 KEY=FAIL 的行与 errno\n");
    return 1;
}
