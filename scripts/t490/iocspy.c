// BUILD: dynamic-so
/* iocspy.c — DRM ioctl 请求值观测器（LD_PRELOAD 替身，仅取证用）
 *
 * 为什么需要它
 * ------------
 * "libdrm 发的是 0xC02064B6 还是 0xC03064B6" 这件事，可以从源码推断，
 * 但更强的证据是**运行期直接看到它**。本文件在 `ioctl` 上做一层拦截，
 * 把每一个 DRM（type='d'）请求的 dir/size/nr 解码后打到 stderr。
 *
 * 它只做观测：不改参数、不改返回值、不改变任何语义。
 *   - 逐个字段解码：dir(2bit) | size(14bit) | type(8bit) | nr(8bit)
 *   - 保留原始 errno 并原样返回 rc
 *   - dlsym(RTLD_NEXT,"ioctl") 失败时退化为直接 syscall，保证不静默失效
 *
 * 用法：LD_PRELOAD=/iocspy.so /drmstdprobe
 * 判定：出现 `req=0xc02064b6 ... size=32 nr=0xb6` 即证明标准客户端发的是 32 字节请求；
 *       若内核只认 48 字节（0xc03064b6），该请求必然 rc=-1 errno=95(EOPNOTSUPP)。
 */
#define _GNU_SOURCE
#include <stdarg.h>
#include <stdio.h>
#include <dlfcn.h>
#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h>

typedef int (*ioctl_fn)(int, unsigned long, void *);
static ioctl_fn real_ioctl = 0;

/* ★ 在**构造函数**里解析真实 ioctl，而不是在被拦截的调用内部惰性解析：
 *   惰性 dlsym 有递归风险（dlsym 自身可能调用 ioctl ⇒ 再次进入本函数仍是 NULL ⇒ 无限递归）。
 *   2026-09-22 实测：带惰性解析的版本让 Weston 在 `libseat: session control granted`
 *   之后立刻死掉（就是这条递归）。构造函数里解析一次即可根除。 */
__attribute__((constructor))
static void iocspy_init(void)
{
    real_ioctl = (ioctl_fn)dlsym(RTLD_NEXT, "ioctl");
}

int ioctl(int fd, unsigned long req, ...)
{
    va_list ap;
    void *arg;
    va_start(ap, req);
    arg = va_arg(ap, void *);
    va_end(ap);

    errno = 0;
    int rc;
    if (real_ioctl)
        rc = real_ioctl(fd, req, arg);
    else
        rc = (int)syscall(SYS_ioctl, fd, req, arg);
    int e = errno;

    if (((req >> 8) & 0xff) == (unsigned long)'d') {
        fprintf(stderr,
                "[IOC] req=0x%08lx dir=%lu size=%u type=0x%02lx nr=0x%02lx -> rc=%d errno=%d(%s)\n",
                req,
                (req >> 30) & 0x3UL,
                (unsigned)((req >> 16) & 0x3fffUL),
                (req >> 8) & 0xffUL,
                req & 0xffUL,
                rc, e, rc < 0 ? strerror(e) : "ok");
    }

    errno = e;
    return rc;
}
