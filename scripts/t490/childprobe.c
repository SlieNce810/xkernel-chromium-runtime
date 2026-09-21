/*
 * childprobe.c — 验证 Chromium「子进程启动路径」的三个环节
 *
 * 为什么测这个
 * ------------
 * T490 实测：Chromium browser 进程常驻，但 utility / renderer 子进程**起来就死且零日志**，
 * 内核侧无 panic / 无 trap / 无 OOM，未实现 syscall 只有 landlock_create_ruleset。
 * 而 chromium.log 里**只有 browser 自己的 PID**，子进程一个字都没打出来
 * → 子进程在能输出日志之前就死了，问题在"启动子进程"这一步本身。
 *
 * Chromium 在 Linux 上启动子进程的做法（base::LaunchProcess）：
 *     fork() → 子进程设置 pgid/sid → execve("/proc/self/exe", argv_with_--type=xxx, envp)
 * 所以本探针逐环节验证：
 *   C1  readlink("/proc/self/exe")                    —— 能不能拿到自身路径
 *   C2  fork() + 子进程跑起来并退出                    —— 纯 fork 通路
 *   C3  fork() + execve("/proc/self/exe", "--child")  —— **和 Chromium 完全一致的通路**
 *   C4  fork() + execve(绝对路径自身)                  —— 排除 execve 本身的问题
 *   C5  posix_spawn 一个真实外部程序（/bin/busybox true）—— 常规 exec 通路对照
 *
 * 若 C2 通过而 C3/C4 失败 ⇒ execve 通路有问题；
 * 若 C3 失败而 C4 通过 ⇒ `/proc/self/exe` 这个路径不能被 exec（符号链接解析问题）；
 * 若 C2 都失败 ⇒ fork/clone 本身有问题。
 *
 * 编译：aarch64-linux-musl-gcc -static -O2 -Wall -Wextra -pthread -o childprobe childprobe.c
 * 运行：/childprobe          （自测模式）
 *       /childprobe --child  （被 exec 起来的子进程模式）
 *
 * 输出：`[C1]..` 明细 + `CHILD_*=PASS|FAIL` 汇总行。
 */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static int g_fail = 0;

static void verdict(const char *key, int ok, const char *what) {
    printf("[%s] %s=%s  (%s)\n", key, key, ok ? "PASS" : "FAIL", what);
    if (!ok) g_fail++;
}

/* 子进程模式：被 exec 起来后只打印一行并退出 */
static int child_mode(void) {
    printf("[CHILD] 我是被 exec 起来的子进程: pid=%d ppid=%d\n", (int)getpid(), (int)getppid());
    fflush(stdout);
    return 0;
}

int main(int argc, char **argv) {
    if (argc > 1 && strcmp(argv[1], "--child") == 0) {
        return child_mode();
    }

    printf("=== childprobe: Chromium 子进程启动路径验证 ===\n");
    printf("[ENV] pid=%d ppid=%d\n", (int)getpid(), (int)getppid());

    /* ---------- C1: /proc/self/exe ---------- */
    char exe[512];
    memset(exe, 0, sizeof(exe));
    ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (n > 0) {
        exe[n] = '\0';
        printf("[C1] readlink(/proc/self/exe) -> \"%s\"\n", exe);
    } else {
        printf("[C1] readlink(/proc/self/exe) -> -1 errno=%d (%s)\n", errno, strerror(errno));
    }
    verdict("CHILD_PROC_SELF_EXE", n > 0, "读取 /proc/self/exe（Chromium 用它定位自身）");

    /* ---------- C2: 纯 fork ---------- */
    {
        pid_t pid = fork();
        if (pid == 0) {
            printf("[C2] fork 子进程运行中 pid=%d ppid=%d\n", (int)getpid(), (int)getppid());
            fflush(stdout);
            _exit(0);
        } else if (pid < 0) {
            printf("[C2] fork -> -1 errno=%d (%s)\n", errno, strerror(errno));
            verdict("CHILD_FORK", 0, "纯 fork");
        } else {
            int st = 0;
            waitpid(pid, &st, 0);
            int ok = WIFEXITED(st) && WEXITSTATUS(st) == 0;
            printf("[C2] fork 子进程 waitpid: exited=%d code=%d signaled=%d\n",
                   WIFEXITED(st), WIFEXITED(st) ? WEXITSTATUS(st) : -1, WIFSIGNALED(st));
            verdict("CHILD_FORK", ok, "纯 fork 通路");
        }
    }

    /* ---------- C3: fork + execve(/proc/self/exe) —— Chromium 的做法 ---------- */
    if (n > 0) {
        pid_t pid = fork();
        if (pid == 0) {
            char *cargv[3];
            cargv[0] = exe;
            cargv[1] = "--child";
            cargv[2] = NULL;
            execve(exe, cargv, environ);
            printf("[C3] execve(\"%s\") 失败 errno=%d (%s)\n", exe, errno, strerror(errno));
            fflush(stdout);
            _exit(127);
        } else if (pid < 0) {
            printf("[C3] fork -> -1 errno=%d\n", errno);
            verdict("CHILD_EXEC_SELF_EXE", 0, "execve(/proc/self/exe)");
        } else {
            int st = 0;
            waitpid(pid, &st, 0);
            int code = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
            printf("[C3] waitpid: exited=%d code=%d signaled=%d%s\n",
                   WIFEXITED(st), code, WIFSIGNALED(st),
                   (WIFEXITED(st) && code == 127) ? "  ← 127 = execve 失败" : "");
            verdict("CHILD_EXEC_SELF_EXE", WIFEXITED(st) && code == 0,
                    "fork + execve(/proc/self/exe, \"--child\") —— **Chromium 子进程启动路径**");
        }
    } else {
        verdict("CHILD_EXEC_SELF_EXE", 0, "跳过（C1 没拿到自身路径）");
    }

    /* ---------- C4: fork + execve(绝对路径自身) ---------- */
    {
        pid_t pid = fork();
        if (pid == 0) {
            char *cargv[3];
            cargv[0] = "/childprobe";
            cargv[1] = "--child";
            cargv[2] = NULL;
            execve("/childprobe", cargv, environ);
            printf("[C4] execve(\"/childprobe\") 失败 errno=%d (%s)\n", errno, strerror(errno));
            fflush(stdout);
            _exit(127);
        } else if (pid < 0) {
            verdict("CHILD_EXEC_ABSPATH", 0, "fork 失败");
        } else {
            int st = 0;
            waitpid(pid, &st, 0);
            int code = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
            printf("[C4] waitpid: exited=%d code=%d signaled=%d\n", WIFEXITED(st), code, WIFSIGNALED(st));
            verdict("CHILD_EXEC_ABSPATH", WIFEXITED(st) && code == 0,
                    "fork + execve(\"/childprobe\") 绝对路径对照");
        }
    }

    /* ---------- C5: posix_spawn 一个外部程序 ---------- */
    {
        pid_t pid = fork();
        if (pid == 0) {
            char *cargv[3];
            cargv[0] = "true";
            cargv[1] = NULL;
            cargv[2] = NULL;
            execve("/bin/busybox", cargv, environ);
            printf("[C5] execve(\"/bin/busybox\", \"true\") 失败 errno=%d (%s)\n", errno, strerror(errno));
            fflush(stdout);
            _exit(127);
        } else if (pid < 0) {
            verdict("CHILD_EXEC_BUSYBOX", 0, "fork 失败");
        } else {
            int st = 0;
            waitpid(pid, &st, 0);
            int code = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
            printf("[C5] busybox true: exited=%d code=%d signaled=%d\n", WIFEXITED(st), code, WIFSIGNALED(st));
            verdict("CHILD_EXEC_BUSYBOX", WIFEXITED(st) && code == 0, "execve 外部程序 /bin/busybox");
        }
    }

    printf("\n[RESULT] fail=%d\n", g_fail);
    printf("[RESULT] %s\n", g_fail == 0 ? "ALL_PASS" : "HAD_FAILURE");
    return g_fail == 0 ? 0 : 1;
}
