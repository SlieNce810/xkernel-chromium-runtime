/*
 * compatprobe.c —— Chromium 子系统依赖项体检（不依赖 Chromium 日志推断）
 *
 * 为什么需要它
 * ------------
 * P3 修好 `prctl(PR_SET_NO_NEW_PRIVS)` 之后，Chromium 的子进程**已经能 exec 成功**
 * （不再有 fork/exec 之间的 abort），但：
 *   - C 段（标准多进程）里 GPU 子进程仍反复崩溃，浏览器报
 *     `GPU process exited unexpectedly: exit_code=48896`
 *     —— 而 **48896 = 191 << 8**，即该子进程的**原始 wait status 是 0xBF00**
 *     （WIFEXITED=true、退出码 191）。也就是说子进程 exec 之后、在**自己的 main() 里**
 *     以 191 静默退出，日志里一行错误都没有。
 *   - crashpad 报 `third_party/crashpad/util/linux/socket.cc:177 missing credentials`
 *     —— 指向 **SO_PEERCRED**（取对端进程凭据）不可用。
 *
 * 本探针逐项体检"Chromium / Mojo / crashpad 强依赖、但 x-kernel 未必实现"的接口，
 * 把 errno 打出来，用于**登记缺口**而不是继续猜。
 *
 * 判据：rc==0（或按 Linux 基线应得的返回值）= PASS；否则 FAIL 并打 errno。
 */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/signalfd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/timerfd.h>
#include <sys/uio.h>
#include <sys/wait.h>
#include <unistd.h>

static int fails, oks;

static void rep(const char *name, long rc, int err, int pass)
{
	if (pass)
		oks++;
	else
		fails++;
	printf("[CP] %-38s rc=%-5ld errno=%-3d %-28s %s\n", name, rc, err,
	       err ? strerror(err) : "-", pass ? "PASS" : "FAIL");
}

/* 便于连续调用的小包装 */
static void chk(const char *name, long rc, int err, int pass)
{
	rep(name, rc, err, pass);
}

int main(void)
{
	int fds[2], fd, rc, err;
	char buf[64];

	/* ★ 无缓冲：r5 轮因 stdout 被接到 tee（管道）转全缓冲，进程退出时丢了后半段输出 */
	setvbuf(stdout, NULL, _IONBF, 0);
	printf("[CP] pid=%d tid=%ld\n", (int)getpid(), syscall(SYS_gettid));

	/* ---------- 1. unix socket 家族 ---------- */
	errno = 0; rc = socketpair(AF_UNIX, SOCK_STREAM, 0, fds);
	chk("socketpair(AF_UNIX,STREAM)", rc, errno, rc == 0);
	int sp = (rc == 0) ? fds[0] : -1;

	/* SO_PEERCRED: crashpad 的 "missing credentials" 指向它 */
	if (sp >= 0) {
		struct ucred cr;
		socklen_t len = sizeof(cr);
		memset(&cr, 0, sizeof(cr));
		errno = 0;
		rc = getsockopt(sp, SOL_SOCKET, SO_PEERCRED, &cr, &len);
		err = errno;
		printf("[CP] %-38s rc=%d len=%u pid=%d uid=%u gid=%u\n",
		       "getsockopt(SO_PEERCRED)", rc, (unsigned)len, cr.pid,
		       cr.uid, cr.gid);
		/* Linux: rc=0 且 cr.pid == getpid() */
		chk("  -> peer pid matches", cr.pid, err,
		    rc == 0 && cr.pid == (int)getpid());
	}

	if (sp >= 0) {
		int v = 0;
		socklen_t len = sizeof(v);
		errno = 0; rc = getsockopt(sp, SOL_SOCKET, SO_SNDBUF, &v, &len);
		printf("[CP] %-38s rc=%d sbuf=%d\n", "getsockopt(SO_SNDBUF)", rc, v);
		chk("  -> SO_SNDBUF readable", rc, errno, rc == 0 && v > 0);

		/* Mojo 用 sendmsg；MSG_NOSIGNAL 是 Linux 上防 SIGPIPE 的常规做法 */
		struct iovec iov = { .iov_base = (void *)"x", .iov_len = 1 };
		struct msghdr mh;
		memset(&mh, 0, sizeof(mh));
		mh.msg_iov = &iov;
		mh.msg_iovlen = 1;
		errno = 0; rc = (int)sendmsg(fds[1], &mh, MSG_NOSIGNAL);
		chk("sendmsg(MSG_NOSIGNAL) on unix", rc, errno, rc == 1);

		errno = 0; rc = (int)recv(sp, buf, sizeof(buf), 0);
		chk("recv() after MSG_NOSIGNAL send", rc, errno, rc == 1);
		close(sp); close(fds[1]);
	}

	errno = 0; rc = socketpair(AF_UNIX, SOCK_SEQPACKET, 0, fds);
	chk("socketpair(AF_UNIX,SEQPACKET)", rc, errno, rc == 0);
	if (rc == 0) { close(fds[0]); close(fds[1]); }

	errno = 0; rc = socketpair(AF_UNIX, SOCK_DGRAM, 0, fds);
	chk("socketpair(AF_UNIX,DGRAM)", rc, errno, rc == 0);
	if (rc == 0) { close(fds[0]); close(fds[1]); }

	errno = 0; rc = socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0, fds);
	chk("socketpair(STREAM|CLOEXEC|NB)", rc, errno, rc == 0);
	if (rc == 0) { close(fds[0]); close(fds[1]); }

	/* ---------- 2. 共享内存（Chromium 图形/合成强依赖） ---------- */
#ifdef SYS_memfd_create
	errno = 0; fd = (int)syscall(SYS_memfd_create, "xk6probe", 0);
	err = errno;
	if (fd >= 0) {
		errno = 0; rc = ftruncate(fd, 4096);
		chk("memfd_create + ftruncate", rc, errno, rc == 0);
		close(fd);
	} else {
		chk("memfd_create", fd, err, 0);
	}
#endif

	errno = 0; fd = shm_open("/xk6probe", O_CREAT | O_RDWR, 0600);
	err = errno;
	if (fd >= 0) {
		errno = 0; rc = ftruncate(fd, 4096);
		int e2 = errno;
		void *p = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
		int e3 = errno;
		chk("shm_open + ftruncate + mmap(MAP_SHARED)", rc,
		    (rc != 0) ? e2 : ((p == MAP_FAILED) ? e3 : 0),
		    rc == 0 && p != MAP_FAILED);
		if (p != MAP_FAILED) munmap(p, 4096);
		close(fd);
		shm_unlink("/xk6probe");
	} else {
		chk("shm_open(/dev/shm)", fd, err, 0);
	}

	/* /dev/shm 目录可写性（POSIX shm 的物理载体） */
	errno = 0; fd = open("/dev/shm/.xk6probe", O_CREAT | O_RDWR, 0600);
	chk("open(/dev/shm/.xk6probe)", fd, errno, fd >= 0);
	if (fd >= 0) { close(fd); unlink("/dev/shm/.xk6probe"); }

	/* ---------- 3. 事件/定时器（消息循环强依赖） ---------- */
	errno = 0; fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
	err = errno;
	if (fd >= 0) {
		uint64_t one = 1, got = 0;
		errno = 0; rc = (int)write(fd, &one, 8);
		int e2 = errno;
		errno = 0; rc = (int)read(fd, &got, 8);
		chk("eventfd write+read", rc, (rc != 8) ? errno : 0,
		    rc == 8 && got == 1);
		(void)e2;
		close(fd);
	} else {
		chk("eventfd(EFD_CLOEXEC|NONBLOCK)", fd, err, 0);
	}

	errno = 0; fd = timerfd_create(CLOCK_MONOTONIC, TFD_CLOEXEC | TFD_NONBLOCK);
	chk("timerfd_create(CLOCK_MONOTONIC)", fd, errno, fd >= 0);
	if (fd >= 0) close(fd);

	errno = 0; fd = epoll_create1(EPOLL_CLOEXEC);
	err = errno;
	if (fd >= 0) {
		int p2[2];
		if (pipe2(p2, O_CLOEXEC | O_NONBLOCK) == 0) {
			struct epoll_event ev;
			memset(&ev, 0, sizeof(ev));
			ev.events = EPOLLIN;
			ev.data.fd = p2[0];
			errno = 0; rc = epoll_ctl(fd, EPOLL_CTL_ADD, p2[0], &ev);
			int e2 = errno;
			chk("epoll_ctl(ADD, pipe read end)", rc, e2, rc == 0);
			/* 真等一次（Mojo/message pump 的核心） */
			errno = 0; rc = (int)write(p2[1], "a", 1);
			int e3 = errno;
			errno = 0; rc = epoll_wait(fd, &ev, 1, 100);
			chk("epoll_wait sees readable pipe", rc, (rc != 1) ? errno : 0,
			    rc == 1 && (ev.events & EPOLLIN));
			(void)e3;
			close(p2[0]); close(p2[1]);
		} else {
			chk("pipe2(O_CLOEXEC|O_NONBLOCK)", -1, errno, 0);
		}
		close(fd);
	} else {
		chk("epoll_create1(EPOLL_CLOEXEC)", fd, err, 0);
	}

	{
		sigset_t mask;
		sigemptyset(&mask); sigaddset(&mask, SIGCHLD);
		errno = 0; fd = signalfd(-1, &mask, SFD_CLOEXEC | SFD_NONBLOCK);
		chk("signalfd(SIGCHLD)", fd, errno, fd >= 0);
		if (fd >= 0) close(fd);
	}

	/* ---------- 4. 杂项 ---------- */
	errno = 0; rc = (int)syscall(SYS_getrandom, buf, 16, 0);
	chk("getrandom(16)", rc, errno, rc == 16);

	/* ---------- 5. MADV_* 语义（★ 页对齐 & "中间打洞"才是真正的分歧点） ---------- */
	/*
	 * 注意（重要教训）：早前版本用 `madvise(栈缓冲, 16, MADV_DONTNEED)` 测，
	 * 结果 EINVAL —— 但那是**探针自身缺陷**：Linux 的 madvise 也要求 addr 页对齐。
	 * 所以这里改为 mmap 出页对齐区间，并**显式包含一个负对照**（故意不对齐，
	 * 期望两边都返回 EINVAL），以及真正的分歧点"区间中间有洞"。
	 */
	{
		const size_t P = 4096;
		char *m = mmap(NULL, P * 4, PROT_READ | PROT_WRITE,
		               MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (m == MAP_FAILED) {
			chk("mmap(4 pages anon)", -1, errno, 0);
		} else {
			memset(m, 0xab, P * 4);   /* 触页 */

			errno = 0; rc = madvise(m, P, MADV_DONTNEED);
			chk("madvise(aligned, DONTNEED)", rc, errno, rc == 0);

			/* 负对照：地址不对齐 —— Linux 也返回 EINVAL，故 PASS 条件是 rc==-1 */
			errno = 0; rc = madvise(m + 1, P, MADV_DONTNEED);
			chk("madvise(misaligned) expect EINVAL", rc, errno,
			    rc == -1 && errno == EINVAL);

			/* 中间打洞：Linux 容忍（只丢弃已映射部分），x-kernel 是否容忍？ */
			if (munmap(m + P, P) == 0) {
				errno = 0; rc = madvise(m, P * 3, MADV_DONTNEED);
				printf("[CP] %-38s rc=%d errno=%d (%s)\n",
				       "madvise(HOLE in middle)", rc, errno,
				       errno ? strerror(errno) : "-");
				chk("  -> Linux tolerates gap (expect 0)", rc, errno,
				    rc == 0);
			}
			munmap(m, P * 4);
		}

		/* 其他 advice：Linux 对未知/MADV_NORMAL 等一律接受并返回 0 */
		char *q = mmap(NULL, P, PROT_READ | PROT_WRITE,
		               MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
		if (q != MAP_FAILED) {
			memset(q, 1, P);
			errno = 0; rc = madvise(q, P, MADV_NORMAL);
			chk("madvise(MADV_NORMAL)", rc, errno, rc == 0);
			errno = 0; rc = madvise(q, P, MADV_WILLNEED);
			chk("madvise(MADV_WILLNEED)", rc, errno, rc == 0);
#ifdef MADV_FREE
			errno = 0; rc = madvise(q, P, MADV_FREE);
			chk("madvise(MADV_FREE)", rc, errno, rc == 0);
#endif
			munmap(q, P);
		}
	}

	/* ---------- 6. SCM_CREDENTIALS（crashpad 真正需要的那条） ---------- */
	/*
	 * crashpad 的 UnixCredentialSocket 用 SOCK_SEQPACKET socketpair，
	 * 并**显式**在 sendmsg 里附带 SCM_CREDENTIALS；接收侧靠它认客户端。
	 * 注意：这**不是** SO_PEERCRED（后者本机实测正常）。
	 *
	 * 环境变量 XK_SKIP_CRED 可跳过本组（用于隔离变量）。
	 */
	{
		int sv[2];
		if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, sv) == 0) {
			char msg[8] = "c";
			char cbuf[CMSG_SPACE(sizeof(struct ucred))];
			struct msghdr mh;
			struct iovec iov = { .iov_base = msg, .iov_len = 1 };

			memset(&mh, 0, sizeof(mh));
			memset(cbuf, 0, sizeof(cbuf));
			mh.msg_iov = &iov;
			mh.msg_iovlen = 1;
			mh.msg_control = cbuf;
			mh.msg_controllen = sizeof(cbuf);
			struct cmsghdr *cm = CMSG_FIRSTHDR(&mh);
			cm->cmsg_level = SOL_SOCKET;
			cm->cmsg_type = SCM_CREDENTIALS;
			cm->cmsg_len = CMSG_LEN(sizeof(struct ucred));
			struct ucred *uc = (struct ucred *)CMSG_DATA(cm);
			uc->pid = (pid_t)getpid();
			uc->uid = getuid();
			uc->gid = getgid();

			errno = 0; rc = (int)sendmsg(sv[0], &mh, 0);
			printf("[CP] %-38s rc=%d errno=%d\n",
			       "sendmsg(SEQPACKET, SCM_CREDENTIALS)", rc, errno);
			chk("  -> send accepted", rc, errno, rc == 1);

			memset(&mh, 0, sizeof(mh));
			memset(cbuf, 0, sizeof(cbuf));
			mh.msg_iov = &iov;
			mh.msg_iovlen = 1;
			mh.msg_control = cbuf;
			mh.msg_controllen = sizeof(cbuf);
			errno = 0; rc = (int)recvmsg(sv[1], &mh, 0);
			int found = 0;
			if (rc >= 0) {
				for (struct cmsghdr *c = CMSG_FIRSTHDR(&mh); c;
				     c = CMSG_NXTHDR(&mh, c)) {
					if (c->cmsg_level == SOL_SOCKET &&
					    c->cmsg_type == SCM_CREDENTIALS) {
						struct ucred *u =
						    (struct ucred *)CMSG_DATA(c);
						printf("[CP]   SCM_CREDENTIALS pid=%d uid=%u gid=%u\n",
						       u->pid, u->uid, u->gid);
						found = (u->pid == (int)getpid());
					}
				}
			}
			if (!found)
				printf("[CP]   recvmsg rc=%d controllen=%zu（未收到 SCM_CREDENTIALS）\n",
				       rc, (size_t)mh.msg_controllen);
			chk("recvmsg delivers SCM_CREDENTIALS", found, 0, found == 1);

			close(sv[0]);
			close(sv[1]);
		} else {
			chk("socketpair(SEQPACKET|CLOEXEC)", -1, errno, 0);
		}
	}

	errno = 0; rc = prctl(PR_SET_PDEATHSIG, SIGKILL);
	chk("prctl(PR_SET_PDEATHSIG,SIGKILL)", rc, errno, rc == 0);

	/* ---------- 5. 受继承性检查：fork+exec 后 fd 是否仍可用 ---------- */
	{
		int pp[2];
		if (pipe2(pp, 0) == 0) {
			pid_t p = fork();
			if (p == 0) {
				/* 子进程里写父进程建的 pipe，验证 fd 跨 fork 仍可用 */
				ssize_t n = write(pp[1], "z", 1);
				_exit(n == 1 ? 0 : 1);
			}
			int st = 0;
			waitpid(p, &st, 0);
			int code = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
			chk("child writes to inherited pipe fd", code, 0, code == 0);
			close(pp[0]); close(pp[1]);
		}
	}

	printf("[CPSUM] pass=%d fail=%d\n", oks, fails);
	printf("[RESULT] fail=%d\n", fails);
	printf("[RESULT] %s\n", fails == 0 ? "ALL_PASS" : "HAD_FAILURE");
	return fails ? 1 : 0;
}
