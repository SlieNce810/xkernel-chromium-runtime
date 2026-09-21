/*
 * memprobe.c —— 聚焦探针：mm 语义（含上一版丢失的用例）
 *
 * 为什么单独一个文件
 * ------------------
 * r5 轮的 compatprobe 输出在 `madvise(HOLE in middle)` 之后**中断**了，
 * 缺失了 MADV_NORMAL/WILLNEED/FREE、SCM_CREDENTIALS、PDEATHSIG、汇总等全部结果。
 *
 * 根因（探针侧）：autorun 里用 `probe 2>&1 | tee -a LOG /dev/console` ——
 * stdout 变成**管道**，stdio 转**全缓冲**，进程一旦结束/被杀，缓冲区内容全丢。
 * 所以本文件：
 *   ① `setvbuf(stdout, NULL, _IONBF, 0)` 设成无缓冲；
 *   ② 每一步前后各打一行 `STEP_ENTER` / `STEP_OK`，**死在哪一步一目了然**；
 *   ③ 补回 r5 丢失的全部用例。
 *
 * 顺带验证一个可疑点：`munmap(m, 4*PAGE)` 而其中一页已被单独 munmap（**区间有洞**）
 * 之后进程是否还活着 —— Linux 允许 munmap 覆盖带洞的区间。
 */

#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>

static int fails, oks;

static void say(const char *s)
{
	write(1, s, strlen(s));
}
static void step(const char *s)
{
	char b[160];
	snprintf(b, sizeof(b), "[MP] >>> STEP %s\n", s);
	say(b);
}
static void res(const char *name, long rc, int err, int pass)
{
	char b[240];
	if (pass)
		oks++;
	else
		fails++;
	snprintf(b, sizeof(b), "[MP] %-40s rc=%-4ld errno=%-3d %-22s %s\n",
		 name, rc, err, err ? strerror(err) : "-", pass ? "PASS" : "FAIL");
	say(b);
}

int main(void)
{
	const size_t P = 4096;
	char *a, *q;

	setvbuf(stdout, NULL, _IONBF, 0); /* ★ 关键：无缓冲，输出不再随进程消失 */
	say("[MP] begin (unbuffered)\n");

	/* ---------------- 1. munmap 语义 ---------------- */
	step("T1 mmap3 + munmap(middle single page)");
	a = mmap(NULL, P * 3, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (a == MAP_FAILED) {
		res("mmap(3 pages)", -1, errno, 0);
		a = NULL;
	} else {
		memset(a, 0x5a, P * 3);
		errno = 0;
		long rc = munmap(a + P, P);
		res("munmap(middle page)", rc, errno, rc == 0);
	}
	say("[MP] STEP_OK T1\n");

	step("T2 munmap WHOLE range that now has a hole  <-- 可疑点");
	if (a) {
		errno = 0;
		long rc = munmap(a, P * 3);
		res("munmap(range with hole)", rc, errno, rc == 0);
	}
	say("[MP] STEP_OK T2 (进程存活)\n");

	step("T3 munmap never-mapped range");
	if (a) {
		errno = 0;
		long rc = munmap(a, P);
		res("munmap(never-mapped)", rc, errno, rc == 0);
	}
	say("[MP] STEP_OK T3\n");

	/* ---------------- 2. madvise 全量 ---------------- */
	step("T4 madvise aligned+mapped / HOLE / 其他 advice");
	a = mmap(NULL, P * 4, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (a != MAP_FAILED) {
		long rc;
		int err;

		memset(a, 0xab, P * 4);

		errno = 0;
		rc = madvise(a, P, MADV_DONTNEED);
		res("madvise(aligned, DONTNEED)", rc, errno, rc == 0);

		errno = 0;
		rc = madvise(a + 1, P, MADV_DONTNEED);
		res("madvise(misaligned) EINVAL?", rc, errno,
		    rc == -1 && errno == EINVAL);

		/* 中间打洞 */
		if (munmap(a + P, P) == 0) {
			errno = 0;
			rc = madvise(a, P * 3, MADV_DONTNEED);
			err = errno;
			printf("[MP] %-40s rc=%ld errno=%d (%s)   ← Linux 期望 rc=0\n",
			       "madvise(HOLE in middle)", rc, err,
			       err ? strerror(err) : "-");
			res("  -> Linux tolerates gap", rc, err, rc == 0);
		}
		say("[MP] STEP_OK T4a\n");

		errno = 0;
		rc = madvise(a, P, MADV_NORMAL);
		res("madvise(MADV_NORMAL)", rc, errno, rc == 0);
		errno = 0;
		rc = madvise(a, P, MADV_WILLNEED);
		res("madvise(MADV_WILLNEED)", rc, errno, rc == 0);
#ifdef MADV_FREE
		errno = 0;
		rc = madvise(a, P, MADV_FREE);
		res("madvise(MADV_FREE)", rc, errno, rc == 0);
#endif
	} else {
		res("mmap(4 pages)", -1, errno, 0);
	}
	say("[MP] STEP_OK T4b\n");

	/* ---------------- 3. SCM_CREDENTIALS（crashpad 真正需要的那条） ---------------- */
	step("T5 SCM_CREDENTIALS over SOCK_SEQPACKET");
	{
		int sv[2];
		if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, sv) == 0) {
			char cbuf[CMSG_SPACE(sizeof(struct ucred))];
			char msg[4] = "c";
			struct iovec iov = { .iov_base = msg, .iov_len = 1 };
			struct msghdr mh;
			struct cmsghdr *cm;
			struct ucred *uc;

			memset(&mh, 0, sizeof(mh));
			memset(cbuf, 0, sizeof(cbuf));
			mh.msg_iov = &iov;
			mh.msg_iovlen = 1;
			mh.msg_control = cbuf;
			mh.msg_controllen = sizeof(cbuf);
			cm = CMSG_FIRSTHDR(&mh);
			cm->cmsg_level = SOL_SOCKET;
			cm->cmsg_type = SCM_CREDENTIALS;
			cm->cmsg_len = CMSG_LEN(sizeof(struct ucred));
			uc = (struct ucred *)CMSG_DATA(cm);
			uc->pid = (pid_t)getpid();
			uc->uid = getuid();
			uc->gid = getgid();

			errno = 0;
			long rc = sendmsg(sv[0], &mh, 0);
			res("sendmsg(SEQPACKET + SCM_CREDENTIALS)", rc, errno, rc == 1);

			memset(&mh, 0, sizeof(mh));
			memset(cbuf, 0, sizeof(cbuf));
			mh.msg_iov = &iov;
			mh.msg_iovlen = 1;
			mh.msg_control = cbuf;
			mh.msg_controllen = sizeof(cbuf);
			errno = 0;
			rc = recvmsg(sv[1], &mh, 0);
			{
				int found = 0;
				for (struct cmsghdr *c = CMSG_FIRSTHDR(&mh); c;
				     c = CMSG_NXTHDR(&mh, c)) {
					if (c->cmsg_level == SOL_SOCKET &&
					    c->cmsg_type == SCM_CREDENTIALS) {
						struct ucred *u =
						    (struct ucred *)CMSG_DATA(c);
						printf("[MP]   got SCM_CREDENTIALS pid=%d uid=%u gid=%u\n",
						       u->pid, u->uid, u->gid);
						found = (u->pid == (int)getpid());
					}
				}
				if (!found)
					printf("[MP]   recvmsg rc=%ld controllen=%zu（没有 SCM_CREDENTIALS）\n",
					       rc, (size_t)mh.msg_controllen);
				res("recvmsg delivers SCM_CREDENTIALS", found, 0, found == 1);
			}
			close(sv[0]);
			close(sv[1]);
		} else {
			res("socketpair(SEQPACKET|CLOEXEC)", -1, errno, 0);
		}
	}
	say("[MP] STEP_OK T5\n");

	/* ---------------- 4. prctl ---------------- */
	step("T6 prctl(PR_SET_PDEATHSIG)");
	{
		errno = 0;
		long rc = prctl(PR_SET_PDEATHSIG, SIGKILL);
		res("prctl(PR_SET_PDEATHSIG,SIGKILL)", rc, errno, rc == 0);
	}
	say("[MP] STEP_OK T6\n");

	/* 对照组：确认自身仍可正常结束 */
	step("T7 epilogue");
	q = mmap(NULL, P, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (q != MAP_FAILED) {
		errno = 0;
		long rc = munmap(q, P);
		res("munmap(fresh single page)", rc, errno, rc == 0);
	}
	printf("[MPSUM] pass=%d fail=%d\n", oks, fails);
	printf("[RESULT] fail=%d\n", fails);
	printf("[RESULT] %s\n", fails == 0 ? "ALL_PASS" : "HAD_FAILURE");
	say("[MP] ALL_STEPS_REACHED\n");
	return fails ? 1 : 0;
}
