/* Read-only file metadata and mapping probe for Chromium FileURLLoader prerequisites. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/stat.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <unistd.h>

int main(void) {
    const char *p = "/usr/share/html-test/index.html";
    struct stat st;
    printf("[FILEPROBE] stat rc=%d errno=%d size=%lld mode=%o nlink=%lu\\n", stat(p,&st), errno,(long long)st.st_size,(unsigned)st.st_mode,(unsigned long)st.st_nlink);
    int fd=open(p,O_RDONLY|O_CLOEXEC);
    printf("[FILEPROBE] open fd=%d errno=%d\\n",fd,errno);
    if(fd<0) return 2;
    struct stat fs;
    memset(&fs,0,sizeof(fs));
    int frc=fstat(fd,&fs);
    printf("[FILEPROBE] fstat rc=%d errno=%d size=%lld mode=%o nlink=%lu\\n",frc,errno,(long long)fs.st_size,(unsigned)fs.st_mode,(unsigned long)fs.st_nlink);
    char buf[64]={0}; ssize_t n=read(fd,buf,sizeof(buf));
    printf("[FILEPROBE] read n=%ld errno=%d prefix=%02x%02x%02x%02x\\n",(long)n,errno,(unsigned char)buf[0],(unsigned char)buf[1],(unsigned char)buf[2],(unsigned char)buf[3]);
    void *m=mmap(NULL,4096,PROT_READ,MAP_PRIVATE,fd,0);
    printf("[FILEPROBE] mmap ptr=%p errno=%d\\n",m,errno);
    if(m!=MAP_FAILED) { printf("[FILEPROBE] map prefix=%02x%02x%02x%02x\\n",((unsigned char*)m)[0],((unsigned char*)m)[1],((unsigned char*)m)[2],((unsigned char*)m)[3]); munmap(m,4096); }
    struct statx sx; memset(&sx,0,sizeof(sx));
    long xr=syscall(SYS_statx,AT_FDCWD,p,AT_STATX_SYNC_AS_STAT,STATX_BASIC_STATS,&sx);
    printf("[FILEPROBE] statx rc=%ld errno=%d mask=%x size=%lld mode=%o nlink=%u\\n",xr,errno,sx.stx_mask,(long long)sx.stx_size,sx.stx_mode,sx.stx_nlink);
    close(fd); puts("[FILEPROBE_EXIT] 0"); return 0;
}
