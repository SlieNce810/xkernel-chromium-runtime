/*
 * credprobe.c —— SCM_CREDENTIALS 在 AF_UNIX 上的收发语义（G17 补丁验收）
 *
 * 为什么需要它
 * ------------
 * Chromium 的 crashpad handler 走 AF_UNIX **SOCK_SEQPACKET** 与浏览器做 IPC，
 * 并在消息上用 cmsg 传递对端凭证。x-kernel 的 cmsg 层此前只实现了 SCM_RIGHTS：
 * 遇到 (SOL_SOCKET, SCM_CREDENTIALS) 落进 `_ =>` 分支直接返回 EINVAL(22)，
 * 而 Linux 对**良构**的该 cmsg 返回 0。crashpad 因此打出
 *     missing credentials
 * 并让子进程在初始化阶段静默退出（rc=191）—— 这是 renderer 至今无法创建的
 * 已证实根因之一（见 report/13 §G17、report/16）。
 *
 * 判据
 * ----
 *   补丁前：T2 / T3 / T6 必 FAIL（sendmsg 返回 -1，errno=22 EINVAL）
 *   补丁后：全部 PASS
 *
 *   ⚠️ sendmsg 成功时返回**已发送字节数**（>0），失败才返回 -1 并置 errno。
 *      本探针首版误按 "rc == 0 才算成功" 判定，在原生 Linux 上大面积误报
 *      FAIL，已修正为 `rc >= 0`。这类"以 0 为成功"的错误在 syscall 探针里
 *      极易发生，值得记一笔。
 *
 *   两份产物同源比较（服务于「与 Linux 行为基线对比」评分项）：
 *     gcc              -o credprobe-linux credprobe.c   # 在 T490 原生跑 = Linux 基线
 *     aarch64-linux-musl-gcc -static -o credprobe credprobe.c  # 注入 guest 跑
 *
 * 用例
 * ----
 *   T1  socketpair(AF_UNIX, SOCK_SEQPACKET)          —— crashpad 用的就是它
 *   T2  SEQPACKET 上 sendmsg 携带 SCM_CREDENTIALS     —— 核心判据（EINVAL → 0）
 *   T3  SOCK_DGRAM / SOCK_STREAM 上同样操作           —— 三种 socket 类型一致
 *   T4  pid=0 的「请内核填真实凭证」写法              —— Linux 也允许
 *   T5  接收侧 SO_PASSCRED=1 → recvmsg 应自动带上
 *       SCM_CREDENTIALS（这是 Linux 上 SO_PASSCRED 的语义）
 *   T6  SCM_RIGHTS 在 SEQPACKET 上仍可用              —— 回归保护，别把 P1 弄坏
 *   T7  cmsg 长度非法（< sizeof(ucred)）→ EINVAL      —— 参数校验不能丢
 *
 * 输出约定：每行 `[CRED] ...`，判定行 `[CRED] Tn ... PASS/FAIL`，
 *           末尾 `[RESULT] fail=N` + `[RESULT] ALL_PASS|HAD_FAILURE`。
 */

#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/uio.h>
#include <unistd.h>

#ifndef SCM_CREDENTIALS
#define SCM_CREDENTIALS 2
#endif
#ifndef SO_PASSCRED
#define SO_PASSCRED 16
#endif

static int fails;
static int passes;

static void verdict(int ok, const char *name)
{
	printf("[CRED] %-52s %s\n", name, ok ? "PASS" : "FAIL");
	if (ok)
		passes++;
	else
		fails++;
}

/* 组装一个携带给定 level/type 与 payload 的 cmsg 并 sendmsg 出去。
 * 返回 0 成功；失败返回 -1 并把 errno 留给调用者。 */
static int send_with_cmsg(int fd, int level, int type,
			  const void *payload, size_t plen,
			  const char *data)
{
	/* 足够容纳一个 ucred cmsg；本探针所有用例的 payload 都不超过它 */
	char cbuf[CMSG_SPACE(sizeof(struct ucred))];
	char buf[8];
	struct iovec iov;
	struct msghdr msg;
	struct cmsghdr *cm;

	memset(cbuf, 0, sizeof(cbuf));
	memset(&msg, 0, sizeof(msg));
	memset(buf, 0, sizeof(buf));

	memcpy(buf, data, strlen(data) < sizeof(buf) ? strlen(data) : sizeof(buf));
	iov.iov_base = buf;
	iov.iov_len = strlen(data) + 1;
	msg.msg_iov = &iov;
	msg.msg_iovlen = 1;
	msg.msg_control = cbuf;
	msg.msg_controllen = CMSG_SPACE(plen);

	cm = CMSG_FIRSTHDR(&msg);
	cm->cmsg_level = level;
	cm->cmsg_type = type;
	cm->cmsg_len = CMSG_LEN(plen);	/* ← 故意允许传一个"非法"长度做 T8 */
	if (payload && plen)
		memcpy(CMSG_DATA(cm), payload, plen);

	return sendmsg(fd, &msg, 0);
}

/* 在 SEQPACKET/DGRAM/STREAM 上各建一对 socketpair */
static int make_pair(int type, int sv[2])
{
	return socketpair(AF_UNIX, type, 0, sv);
}

int main(void)
{
	struct ucred me;
	int sv[2];
	int rc, err;
	int fd_ok = 0;

	printf("[CRED] pid=%d uid=%d gid=%d\n", (int)getpid(), (int)getuid(),
	       (int)getgid());

	me.pid = (int)getpid();
	me.uid = (int)getuid();
	me.gid = (int)getgid();

	/* ---------------- T1: SEQPACKET socketpair ---------------- */
	errno = 0;
	rc = make_pair(SOCK_SEQPACKET, sv);
	err = errno;
	printf("[CRED] T1 socketpair(AF_UNIX, SOCK_SEQPACKET) -> rc=%d errno=%d (%s)\n",
	       rc, err, strerror(err));
	verdict(rc == 0, "T1 SEQPACKET socketpair");
	if (rc != 0) {
		printf("[CRED] 无 SEQPACKET → 后续用例无法执行，直接汇总\n");
		goto summary;
	}
	fd_ok = 1;

	/* ---------------- T2: 核心判据 ----------------
	 * 注意：sendmsg 成功时返回**发送的字节数**（>0），失败才返回 -1 并置 errno。
	 * 早期版本误按 "== 0 才算成功" 判定，导致在原生 Linux 上也误报 FAIL。 */
	errno = 0;
	rc = send_with_cmsg(sv[0], SOL_SOCKET, SCM_CREDENTIALS,
			    &me, sizeof(me), "c2");
	err = errno;
	printf("[CRED] T2 sendmsg SEQPACKET + SCM_CREDENTIALS -> rc=%d errno=%d (%s)"
	       "   <== 核心判据：补丁前=-1/22(EINVAL)，Linux/补丁后=正数字节数\n",
	       rc, err, strerror(err));
	verdict(rc >= 0, "T2 SEQPACKET sendmsg SCM_CREDENTIALS");

	/* ---------------- T3: DGRAM / STREAM 一致性 ---------------- */
	{
		int t3_ok = 1;
		const struct {
			int type;
			const char *nm;
		} kinds[] = { { SOCK_DGRAM, "DGRAM" }, { SOCK_STREAM, "STREAM" } };
		size_t k;
		for (k = 0; k < sizeof(kinds) / sizeof(kinds[0]); k++) {
			int p[2];
			if (make_pair(kinds[k].type, p) != 0) {
				printf("[CRED] T3 %-6s socketpair 失败 errno=%d\n",
				       kinds[k].nm, errno);
				t3_ok = 0;
				continue;
			}
			errno = 0;
			rc = send_with_cmsg(p[0], SOL_SOCKET, SCM_CREDENTIALS,
					    &me, sizeof(me), "c3");
			err = errno;
			printf("[CRED] T3 %-6s sendmsg + SCM_CREDENTIALS -> rc=%d errno=%d (%s)\n",
			       kinds[k].nm, rc, err, strerror(err));
			if (rc < 0)
				t3_ok = 0;
			close(p[0]);
			close(p[1]);
		}
		verdict(t3_ok, "T3 DGRAM/STREAM sendmsg SCM_CREDENTIALS");
	}

	/* ---------------- T4: pid=0（非特权进程在 Linux 上是 EPERM） ---------------- */
	{
		struct ucred z;
		z.pid = 0;
		z.uid = 0;
		z.gid = 0;
		errno = 0;
		rc = send_with_cmsg(sv[0], SOL_SOCKET, SCM_CREDENTIALS,
				    &z, sizeof(z), "c4");
		err = errno;
		printf("[CRED] T4 sendmsg SCM_CREDENTIALS{pid=0} -> rc=%d errno=%d (%s)\n",
		       rc, err, strerror(err));
		printf("[CRED]    (Linux: pid!=自身 tgid 时需 CAP_SYS_ADMIN，"
		       "非特权 → EPERM=1；root → 0)\n");
		/* 0 与 EPERM 都是 Linux 的合法结果，取决于调用者是否具备 CAP_SYS_ADMIN */
		verdict((rc >= 0) || (err == EPERM),
			"T4 SCM_CREDENTIALS pid=0 -> 成功(特权) 或 EPERM(非特权)");
	}

	/* ---------------- T5: 接收侧 SO_PASSCRED ---------------- */
	{
		int on = 1;
		char rbuf[32];
		char rcbuf[256];
		struct iovec iov;
		struct msghdr msg;
		struct cmsghdr *cm;
		int got_cred = 0;
		int peer_pid = -1;

		if (setsockopt(sv[1], SOL_SOCKET, SO_PASSCRED, &on, sizeof(on)) != 0) {
			printf("[CRED] T5 setsockopt(SO_PASSCRED) 失败 errno=%d (%s)\n",
			       errno, strerror(errno));
			verdict(0, "T5 SO_PASSCRED delivers SCM_CREDENTIALS");
			goto t6;
		}
		errno = 0;
		rc = send_with_cmsg(sv[0], SOL_SOCKET, SCM_CREDENTIALS,
				    &me, sizeof(me), "c5");
		err = errno;
		if (rc < 0) {
			printf("[CRED] T5 发送失败 rc=%d errno=%d (%s)\n", rc, err,
			       strerror(err));
			verdict(0, "T5 SO_PASSCRED delivers SCM_CREDENTIALS");
			goto t6;
		}

		memset(rbuf, 0, sizeof(rbuf));
		memset(rcbuf, 0, sizeof(rcbuf));
		iov.iov_base = rbuf;
		iov.iov_len = sizeof(rbuf);
		memset(&msg, 0, sizeof(msg));
		msg.msg_iov = &iov;
		msg.msg_iovlen = 1;
		msg.msg_control = rcbuf;
		msg.msg_controllen = sizeof(rcbuf);

		errno = 0;
		rc = recvmsg(sv[1], &msg, 0);
		err = errno;
		printf("[CRED] T5 recvmsg -> rc=%d errno=%d controllen=%u data='%s'\n",
		       rc, err, (unsigned)msg.msg_controllen, rbuf);
		for (cm = CMSG_FIRSTHDR(&msg); cm; cm = CMSG_NXTHDR(&msg, cm)) {
			printf("[CRED] T5   cmsg level=%d type=%d len=%zu\n",
			       cm->cmsg_level, cm->cmsg_type, (size_t)cm->cmsg_len);
			if (cm->cmsg_level == SOL_SOCKET &&
			    cm->cmsg_type == SCM_CREDENTIALS &&
			    cm->cmsg_len >= CMSG_LEN(sizeof(struct ucred))) {
				struct ucred g;
				memcpy(&g, CMSG_DATA(cm), sizeof(g));
				got_cred = 1;
				peer_pid = g.pid;
				printf("[CRED] T5   ucred pid=%d uid=%d gid=%d\n",
				       g.pid, g.uid, g.gid);
			}
		}
		verdict(got_cred && peer_pid == (int)getpid(),
			"T5 SO_PASSCRED delivers SCM_CREDENTIALS");
	}

t6:
	/* ---------------- T6: SCM_RIGHTS 回归 ---------------- */
	{
		int fds[2];
		if (pipe(fds) != 0) {
			verdict(0, "T6 SCM_RIGHTS still works on SEQPACKET");
			goto t7;
		}
		errno = 0;
		rc = send_with_cmsg(sv[0], SOL_SOCKET, SCM_RIGHTS,
				    &fds[0], sizeof(int), "c6");
		err = errno;
		printf("[CRED] T6 sendmsg SEQPACKET + SCM_RIGHTS -> rc=%d errno=%d (%s)\n",
		       rc, err, strerror(err));
		verdict(rc >= 0, "T6 SCM_RIGHTS still works on SEQPACKET");
		close(fds[0]);
		close(fds[1]);
	}

t7:
	/* ---------------- T7: 非法 cmsg 长度仍应 EINVAL ---------------- */
	{
		int bogus = 0x1234;
		errno = 0;
		rc = send_with_cmsg(sv[0], SOL_SOCKET, SCM_CREDENTIALS,
				    &bogus, 4 /* < sizeof(struct ucred) */, "c7");
		err = errno;
		printf("[CRED] T7 sendmsg SCM_CREDENTIALS{len=4} -> rc=%d errno=%d (%s)"
		       "   (期望 EINVAL=22)\n", rc, err, strerror(err));
		verdict(rc != 0 && err == EINVAL, "T7 malformed cmsg len rejected");
	}

	if (fd_ok) {
		close(sv[0]);
		close(sv[1]);
	}

summary:
	printf("[CRED] ---- 语义对照 ----\n");
	printf("[CRED] Linux: 良构的 SCM_CREDENTIALS cmsg → sendmsg 返回正数字节数；\n");
	printf("[CRED]        长度 != sizeof(struct ucred)   → EINVAL(22)；\n");
	printf("[CRED]        凭证不属于自身且无 CAP_SYS_ADMIN → EPERM(1)；\n");
	printf("[CRED]        SO_PASSCRED=1 的接收端由**内核**自动附带 SCM_CREDENTIALS。\n");
	printf("[CRED] x-kernel 补丁前: 任何 SCM_CREDENTIALS → EINVAL(22)，\n");
	printf("[CRED]                   crashpad 因此报 'missing credentials'。\n");

	printf("\n[RESULT] pass=%d fail=%d\n", passes, fails);
	printf("[RESULT] %s\n", fails == 0 ? "ALL_PASS" : "HAD_FAILURE");
	return fails ? 1 : 0;
}
