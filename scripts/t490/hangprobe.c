/*
 * hangprobe.c —— 定位"进程在哪一步卡住"
 *
 * 起因（r5 / r6 两轮交叉验证）
 * ---------------------------
 *   compatprobe（r5）：输出停在 `madvise(HOLE in middle)` 之后的
 *                      `munmap(m, 4*PAGE)`（其中 m+PAGE 已被单独 munmap）之前，**再没返回**；
 *   memprobe（r6）   ：输出被重定向到文件 → 因为进程**从未返回**，文件内容始终没被 cat 出来，
 *                      连退出码都没有。
 *   但两轮的**会话本身都正常**（screendump 按时成功、QEMU monitor 可响应）
 *   → **不是内核整体卡死，而是该进程挂住了**，autorun 一直等它。
 *
 * 因此本探针的设计目标只有一个：**把"卡在哪一步"变成确定性事实**。
 *   - 每个操作**前后**都用 write(2) 直接往 dev/console 写一行
 *     （不缓冲、不经 tee、不受 stdout 重定向影响）；
 *   - 同时 alarm(25) + SIGALRM 处理，若信号能送达就打 ALARM_FIRED；
 *   - 用例按"由轻到重"排列，卡住时前面已跑过的结论全部保留。
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <unistd.h>

static int con = -1;

/* 直写 /dev/console：不缓冲、不经 tee、重定向也拦不住 */
static void mk(const char *s)
{
	if (con >= 0)
		write(con, s, strlen(s));
	write(1, s, strlen(s));
}
static void mark(const char *s)
{
	char b[200];
	snprintf(b, sizeof(b), "[HP] MARK %s\n", s);
	mk(b);
}
static void ok(const char *name, long rc, int err)
{
	char b[220];
	snprintf(b, sizeof(b), "[HP] %-42s rc=%-4ld errno=%d\n", name, rc, err);
	mk(b);
}

static void on_alarm(int sig)
{
	(void)sig;
	mk("[HP] ALARM_FIRED（信号可送达，说明未完全失联）\n");
}

int main(void)
{
	const size_t P = 4096;
	char *a;
	long rc;
	int err;

	setvbuf(stdout, NULL, _IONBF, 0);
	con = open("/dev/console", O_WRONLY | O_NONBLOCK);
	signal(SIGALRM, on_alarm);
	alarm(25);

	mk("[HP] ================ begin ================\n");
	mark("0 baseline: getpid/写作正常");

	/* -------- 1. 单页 munmap（已知可行，做基线） -------- */
	mark("1a mmap(3 pages)");
	a = mmap(NULL, P * 3, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (a == MAP_FAILED) {
		ok("mmap(3p)", -1, errno);
		a = NULL;
	} else {
		ok("mmap(3p)", 0, 0);
		memset(a, 0x5a, P * 3);
		mark("1b munmap(middle page)");
		errno = 0;
		rc = munmap(a + P, P);
		ok("munmap(middle page)", rc, errno);
		mark("1c 单页 munmap 已返回");
	}

	/* -------- 2. ★ 可疑点：munmap 覆盖"带洞"的整个区间 -------- */
	if (a) {
		mark("2a ABOUT TO munmap(a, 3*P)  <-- 区间中间有洞");
		errno = 0;
		rc = munmap(a, P * 3);
		err = errno;
		ok("munmap(range with hole)", rc, err);
		mark("2b munmap(range with hole) 已返回 ★ 未卡住");
	}

	/* -------- 3. madvise 家族 -------- */
	a = mmap(NULL, P * 4, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (a != MAP_FAILED) {
		memset(a, 0xab, P * 4);

		mark("3a madvise(aligned, DONTNEED)");
		errno = 0;
		rc = madvise(a, P, MADV_DONTNEED);
		ok("madvise(aligned,DONTNEED)", rc, errno);

		mark("3b madvise(misaligned)");
		errno = 0;
		rc = madvise(a + 1, P, MADV_DONTNEED);
		ok("madvise(misaligned)", rc, errno);

		mark("3c munmap(middle) 制造洞");
		errno = 0;
		rc = munmap(a + P, P);
		ok("munmap(middle) #2", rc, errno);

		mark("3d madvise over HOLE (前一版返回 ENOMEM=12)");
		errno = 0;
		rc = madvise(a, P * 3, MADV_DONTNEED);
		ok("madvise(HOLE)", rc, errno);

		mark("3e madvise(MADV_NORMAL/WILLNEED/FREE)");
		errno = 0;
		rc = madvise(a, P, MADV_NORMAL);
		ok("madvise(MADV_NORMAL)", rc, errno);
		errno = 0;
		rc = madvise(a, P, MADV_WILLNEED);
		ok("madvise(MADV_WILLNEED)", rc, errno);
#ifdef MADV_FREE
		errno = 0;
		rc = madvise(a, P, MADV_FREE);
		ok("madvise(MADV_FREE)", rc, errno);
#endif
	}

	/* -------- 4. SCM_CREDENTIALS（crashpad 需要的那条） -------- */
	mark("4 SCM_CREDENTIALS over SEQPACKET");
	{
		int sv[2];
		if (socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sv) == 0) {
			char cbuf[CMSG_SPACE(sizeof(struct ucred))];
			char msg[4] = "c";
			struct iovec iov = { .iov_base = msg, .iov_len = 1 };
			struct msghdr mh = { 0 };
			struct cmsghdr *cm;
			struct ucred *uc;

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
			rc = sendmsg(sv[0], &mh, 0);
			ok("sendmsg(SEQPACKET+SCM_CREDENTIALS)", rc, errno);

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
						char b[160];
						snprintf(b, sizeof(b),
							 "[HP]   GOT SCM_CREDENTIALS pid=%d uid=%u gid=%u\n",
							 u->pid, u->uid, u->gid);
						mk(b);
						found = (u->pid == (int)getpid());
					}
				}
				if (!found) {
					char b[160];
					snprintf(b, sizeof(b),
						 "[HP]   NO SCM_CREDENTIALS (rc=%ld controllen=%zu)\n",
						 rc, (size_t)mh.msg_controllen);
					mk(b);
				}
				ok("recvmsg delivers SCM_CREDENTIALS", found, 0);
			}
			close(sv[0]);
			close(sv[1]);
		}
	}

	/* -------- 5. prctl -------- */
	mark("5 prctl(PR_SET_PDEATHSIG,SIGKILL)");
	errno = 0;
	rc = prctl(PR_SET_PDEATHSIG, SIGKILL);
	ok("prctl(PR_SET_PDEATHSIG)", rc, errno);

	mark("Z ALL_STEPS_REACHED");
	mk("[HP] ================ end ================\n");
	return 0;
}
