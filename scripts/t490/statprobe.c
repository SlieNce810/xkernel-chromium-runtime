/* Inspect stat(2) rdev against the class-device major/minor attributes. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

static void print_attr(const char *path)
{
    char data[64] = {0};
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        printf("[STATPROBE] attr=%s open errno=%d (%s)\n", path, errno, strerror(errno));
        return;
    }
    ssize_t count = read(fd, data, sizeof(data) - 1);
    if (count < 0) {
        printf("[STATPROBE] attr=%s read errno=%d (%s)\n", path, errno, strerror(errno));
    } else {
        data[count] = '\0';
        printf("[STATPROBE] attr=%s value=%s", path, data);
        if (count == 0 || data[count - 1] != '\n') putchar('\n');
    }
    close(fd);
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    for (int index = 0; index < 2; index++) {
        char path[64];
        snprintf(path, sizeof(path), "/dev/input/event%d", index);
        struct stat st = {0};
        if (stat(path, &st) == 0) {
            printf("[STATPROBE] path=%s mode=%#o rdev=%u:%u\n", path, (unsigned)st.st_mode,
                   (unsigned)major(st.st_rdev), (unsigned)minor(st.st_rdev));
        } else {
            printf("[STATPROBE] path=%s stat errno=%d (%s)\n", path, errno, strerror(errno));
        }
        snprintf(path, sizeof(path), "/sys/class/input/event%d/dev", index);
        print_attr(path);
    }
    puts("[STATPROBE_EXIT] done");
    return 0;
}
