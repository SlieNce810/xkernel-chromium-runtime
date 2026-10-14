/*
 * Common user-space adapter for a controlled before/after experiment.
 * Both kernels use this same library. It selects normal mutexes when callers
 * request PI; this does not implement PI or repair the baseline kernel.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>

int pthread_mutexattr_setprotocol(pthread_mutexattr_t *attribute, int protocol)
{
    typedef int (*setter)(pthread_mutexattr_t *, int);
    setter real_setter = (setter)dlsym(RTLD_NEXT, "pthread_mutexattr_setprotocol");
    if (!real_setter) return ENOSYS;
    return real_setter(attribute, protocol == PTHREAD_PRIO_INHERIT ? PTHREAD_PRIO_NONE : protocol);
}
