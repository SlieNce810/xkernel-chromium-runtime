/*
 * nvprobe.c —— 直接验证 prctl(PR_SET_NO_NEW_PRIVS) 的语义（P3 补丁验收）
 *
 * 为什么需要它
 * ------------
 * Chromium 的子进程死得"悄无声息"，只能从浏览器日志里看到一行无前缀的
 *     prctl(PR_SET_NO_NEW_PRIVS) failed
 * 该行的来源是 base/process/launch_posix.cc 的 **fork 之后、execvp 之前**：
 *
 *     if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) {
 *       if (errno != EINVAL && errno != EPERM) {
 *         RAW_LOG(FATAL, "prctl(PR_SET_NO_NEW_PRIVS) failed");   // ← 子进程 abort
 *       }
 *     }
 *
 * 所以本探针不去"猜 Chromium"，而是：
 *   T1/T2 直接验 syscall 语义（补丁前 ENOSYS=38 → 补丁后 0）
 *   T3    验参数校验仍与 Linux 一致（arg2 != 1 → EINVAL）
 *   T4    验 fork 继承（Linux: no_new_privs 跨 fork/clone 继承）
 *   T5    **逐字复刻** LaunchProcess 子进程侧的失败判据 + 随后的 execve
 *
 * 判据：补丁前 T1/T2/T5 必 FAIL（T5 退出码 134 = abort 等价），补丁后 ALL_PASS。
 */

#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef PR_SET_NO_NEW_PRIVS
#define PR_SET_NO_NEW_PRIVS 38
#endif

static int fails;

static void verdict(int ok, const char *name)
{
	printf("[NV] %-44s %s\n", name, ok ? "PASS" : "FAIL");
	if (!ok)
		fails++;
}

int main(void)
{
	long v;
	int rc, err;
	pid_t p;
	int st, code;

	printf("[NV] pid=%d tid=%ld\n", (int)getpid(), syscall(SYS_gettid));

	/* ---- T0: 前置现值（本探针进程是首次调用，应为 0） ---- */
	errno = 0;
	v = prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0);
	printf("[NV] T0 PR_GET_NO_NEW_PRIVS (before) = %ld errno=%d\n", v, errno);

	/* ---- T1: 设置。Linux 3.5+ 返回 0；x-kernel 补丁前返回 -1/ENOSYS(38) ---- */
	errno = 0;
	rc = prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
	err = errno;
	printf("[NV] T1 PR_SET_NO_NEW_PRIVS(1) -> rc=%d errno=%d (%s)\n",
	       rc, err, strerror(err));
	verdict(rc == 0 && err == 0, "T1 set returns 0 (was ENOSYS=38)");

	/* ---- T2: 读回，应为 1 ---- */
	errno = 0;
	v = prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0);
	printf("[NV] T2 PR_GET_NO_NEW_PRIVS (after) = %ld errno=%d\n", v, errno);
	verdict(v == 1, "T2 get reads back 1");

	/* ---- T3: 参数校验必须保持 Linux 语义 ---- */
	errno = 0;
	rc = prctl(PR_SET_NO_NEW_PRIVS, 0, 0, 0, 0);
	err = errno;
	printf("[NV] T3 PR_SET_NO_NEW_PRIVS(0) -> rc=%d errno=%d\n", rc, err);
	verdict(rc == -1 && err == EINVAL, "T3 arg2=0 rejected with EINVAL(22)");

	/* ---- T4: fork 继承 ---- */
	p = fork();
	if (p == 0) {
		long cv = prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0);
		_exit(cv == 1 ? 0 : (cv == 0 ? 1 : 2));
	}
	if (p < 0) {
		printf("[NV] T4 fork failed: %s\n", strerror(errno));
		verdict(0, "T4 flag inherited across fork");
	} else {
		st = 0;
		waitpid(p, &st, 0);
		code = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
		printf("[NV] T4 fork child read  -> %s (raw exit=%d)\n",
		       code == 0 ? "1" : (code == 1 ? "0" : "error"), code);
		verdict(code == 0, "T4 flag inherited across fork");
	}

	/* ---- T5: 逐字复刻 Chromium LaunchProcess 的 fork->prctl->execve 路径 ---- */
	p = fork();
	if (p == 0) {
		/* --- 以下 4 行与 base/process/launch_posix.cc 同构 --- */
		if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) {
			if (errno != EINVAL && errno != EPERM) {
				/* RAW_LOG(FATAL) 等价物：写共享 stderr 后立即退出 */
				fprintf(stderr,
					"prctl(PR_SET_NO_NEW_PRIVS) failed\n");
				_exit(134); /* = abort() 的 shell 可见退出码 */
			}
		}
		execl("/bin/sh", "sh", "-c", "exit 0", (char *)0);
		_exit(127);
	}
	if (p < 0) {
		printf("[NV] T5 fork failed: %s\n", strerror(errno));
		verdict(0, "T5 chromium-style child survives execve");
	} else {
		st = 0;
		waitpid(p, &st, 0);
		code = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
		printf("[NV] T5 chromium-style child exit=%d"
		       " (0=survived, 134=RAW_LOG(FATAL) path, 127=execve fail)\n",
		       code);
		verdict(code == 0, "T5 chromium-style child survives execve");
	}

	printf("[NV] ---- helper: 复刻结果对照 ----\n");
	printf("[NV] errno 语义: EINVAL(22) 与 EPERM(1) 被 Chromium 容忍；"
	       "ENOSYS(38) 不在容忍集 → FATAL\n");

	printf("[RESULT] fail=%d\n", fails);
	printf("[RESULT] %s\n", fails == 0 ? "ALL_PASS" : "HAD_FAILURE");
	return fails ? 1 : 0;
}
