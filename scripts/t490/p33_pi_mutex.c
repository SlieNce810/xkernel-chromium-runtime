#define _GNU_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <pthread.h>
#include <stdio.h>

int main(void) {
    pthread_mutexattr_t attr;
    pthread_mutex_t mutex;
    int init_rc = pthread_mutexattr_init(&attr);
    if (init_rc != 0) {
        printf("[PI_MUTEX_PROBE] attr_init=%d verdict=FAIL\n", init_rc);
        return 1;
    }

    int protocol_rc = pthread_mutexattr_setprotocol(&attr, PTHREAD_PRIO_INHERIT);
    int mutex_init_rc = pthread_mutex_init(&mutex, &attr);
    int lock_rc = mutex_init_rc == 0 ? pthread_mutex_lock(&mutex) : mutex_init_rc;
    int unlock_rc = lock_rc == 0 ? pthread_mutex_unlock(&mutex) : lock_rc;
    pthread_mutexattr_destroy(&attr);
    if (mutex_init_rc == 0)
        pthread_mutex_destroy(&mutex);

    int expected_protocol_rc = protocol_rc == 0 || protocol_rc == ENOTSUP;
    int ok = expected_protocol_rc && mutex_init_rc == 0 && lock_rc == 0 && unlock_rc == 0;
    printf("[PI_MUTEX_PROBE] protocol_rc=%d enotsup=%d mutex_init=%d lock=%d unlock=%d verdict=%s\n",
           protocol_rc, ENOTSUP, mutex_init_rc, lock_rc, unlock_rc, ok ? "OK" : "FAIL");
    return ok ? 0 : 1;
}
