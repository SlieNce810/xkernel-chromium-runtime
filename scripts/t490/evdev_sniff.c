// BUILD: static
// 裸 evdev 事件嗅探（M2 输入链第一段）
//
// 目的：把"QMP 发了事件"和"guest 收到事件"这两件事分开。
// run_input_final 那轮里 before/after PPM 的 SHA 完全相同、9 帧只有 1 个唯一哈希，
// 说明画面一点没动；但 QMP 侧 input-send-event 22 次、send-key 14 次全部返回成功。
// 所以断点一定在 QEMU 之后。
//
// 本程序不起 Weston、不抢图形栈，只 open + poll + read：
//   收到事件 → virtio-input 驱动与 evdev 这一层是通的，问题在 libinput/Weston/焦点；
//   收不到   → 断在 virtio-input 驱动或 QEMU 的 console 路由（VNC 无客户端时 console 可能没有焦点）。
//
// 用法：evdev_sniff /dev/input/event0 [/dev/input/event1 ...]
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define MAXFD 8

// aarch64/64 位：timeval 16 字节 + u16 + u16 + s32 = 24 字节
struct input_event_compat {
    unsigned long sec;
    unsigned long usec;
    unsigned short type;
    unsigned short code;
    int value;
};

static const char *type_name(unsigned short t) {
    switch (t) {
    case 0: return "SYN";
    case 1: return "KEY";
    case 2: return "REL";
    case 3: return "ABS";
    case 4: return "MSC";
    default: return "?";
    }
}

int main(int argc, char **argv) {
    // stdout 被重定向到 /dev/console 时不是 tty，默认是**块缓冲**。
    // 探针常驻 poll 循环、永不退出，缓冲区就一直不刷——上一轮就是这样：
    // autorun 打印了 EVDEV_READY，探针自己也"跑了"，但一行输出都没有。
    setvbuf(stdout, NULL, _IONBF, 0);

    if (argc < 2) {
        printf("EVDEV usage: evdev_sniff /dev/input/eventN ...\n");
        return 2;
    }
    int fds[MAXFD];
    int n = 0;
    for (int i = 1; i < argc && n < MAXFD; i++) {
        // open 之前先打一行：上一轮"进程活着但一行输出都没有"，
        // 唯一能解释的就是 open() 本身没返回。这行是那个判断的锚点。
        printf("EVDEV trying path=%s\n", argv[i]);
        int fd = open(argv[i], O_RDONLY | O_NONBLOCK);
        printf("EVDEV open_returned path=%s fd=%d errno=%d\n", argv[i], fd, fd < 0 ? errno : 0);
        if (fd < 0) {
            printf("EVDEV open_fail path=%s errno=%d\n", argv[i], errno);
            continue;
        }
        char name[128] = "";
        // EVIOCGNAME(128) = _IOC(_IOC_READ, 'E', 0x06, 128) = 0x80804506
        // （之前手算成 0x80ff4506，size 字段塞了 0xff，只会拿到 EINVAL）
        if (ioctl(fd, 0x80804506, name) >= 0)
            printf("EVDEV opened path=%s name=%s fd=%d\n", argv[i], name, fd);
        else
            printf("EVDEV opened path=%s name=? fd=%d\n", argv[i], fd);
        fds[n++] = fd;
    }
    if (n == 0) {
        printf("EVDEV no_device\n");
        return 1;
    }
    printf("EVDEV READY n=%d\n", n);
    fflush(stdout);

    unsigned long total = 0;
    for (;;) {
        struct pollfd pfd[MAXFD];
        for (int i = 0; i < n; i++) {
            pfd[i].fd = fds[i];
            pfd[i].events = POLLIN;
            pfd[i].revents = 0;
        }
        int rc = poll(pfd, (nfds_t)n, 1000);
        if (rc < 0) {
            if (errno == EINTR) continue;
            printf("EVDEV poll_fail errno=%d\n", errno);
            break;
        }
        if (rc == 0) continue; // 每秒醒一次，静默，不刷屏
        for (int i = 0; i < n; i++) {
            if (!(pfd[i].revents & POLLIN)) continue;
            struct input_event_compat ev;
            while (read(fds[i], &ev, sizeof ev) == (ssize_t)sizeof ev) {
                total++;
                // 只打非 SYN/MSC 的有效事件，SYN 太多会淹掉串口
                if (ev.type != 0 && ev.type != 4) {
                    printf("EVDEV ev fd=%d type=%s(%u) code=%u value=%d n=%lu\n",
                           fds[i], type_name(ev.type), ev.type, ev.code, ev.value, total);
                    fflush(stdout);
                }
            }
        }
    }
    printf("EVDEV END total=%lu\n", total);
    fflush(stdout);
    return 0;
}
