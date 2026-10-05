/* drmdumbprobe.c — 单点证据：DRM_IOCTL_MODE_CREATE_DUMB 对各 bpp 的接受度
 *
 * 为什么需要它
 *   report/27 的定位链是：
 *     Xorg 日志 `(II) modeset(0): Using 24bpp hw front buffer with 32bpp shadow`
 *     → modesetting 在 ShadowFB 强制开启时把**硬件前缓冲**切成 24bpp packed
 *       (DRM_FORMAT_RGB888)，即调用 drmModeCreateDumbBuffer(..., bpp=24)
 *     → 内核 io/drmdevice/src/card0.rs 的 DrmModeCreateDumb(0xB2) 只接受 bpp==32
 *       (`if c.bpp != 32 → Err(InvalidInput)`)
 *     → ScreenInit 拿不到前缓冲 → `(EE) AddScreen/ScreenInit failed for driver 0`
 *
 *   上面最后一步此前只是**代码阅读推论**。本探针把它降成 errno 级实测：
 *   同一次开机里，对同一设备分别用 bpp=32 / 24 / 16 调 CREATE_DUMB，
 *   把"哪个 bpp 被拒、返回什么 errno"直接打出来。
 *   这样"内核 CreateDumb 的 bpp 约束"就是被测量的事实，而不是推断。
 *
 * 自证（M2：未验证的门禁比没门禁更危险）
 *   先打自己的 ioctl 编码值，并用 DRM_IOCTL_VERSION 做一次"已知能通"的对照。
 *   若 VERSION 也不通，说明本探针的 _IOWR 编码与内核不匹配，
 *   此时 CREATE_DUMB 的失败**不能**被解读成内核拒绝 bpp —— 必须先修探针。
 *
 * 编译：aarch64-linux-musl-gcc -static -O2 -o drmdumbprobe drmdumbprobe.c
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <sys/ioctl.h>

#define DEV0 "/dev/dri/card0"

/* ---- Linux uapi 的 _IOC 编码（必须与内核 iowr 完全一致，否则匹配不上）---- */
#define IOC_NRBITS      8
#define IOC_TYPEBITS    8
#define IOC_SIZEBITS    14
#define IOC_DIRBITS     2
#define IOC_NRSHIFT     0
#define IOC_TYPESHIFT   (IOC_NRSHIFT + IOC_NRBITS)
#define IOC_SIZESHIFT   (IOC_TYPESHIFT + IOC_TYPEBITS)
#define IOC_DIRSHIFT    (IOC_SIZESHIFT + IOC_SIZEBITS)
#define IOC_NONE        0U
#define IOC_WRITE       1U
#define IOC_READ        2U
#define IOC(dir,type,nr,size) \
    (((dir) << IOC_DIRSHIFT) | ((type) << IOC_TYPESHIFT) | \
     ((nr) << IOC_NRSHIFT) | ((size) << IOC_SIZESHIFT))
#define IOWR(type,nr,size)  IOC(IOC_READ|IOC_WRITE, type, nr, sizeof(size))

#define DRM_TYPE 'd'            /* 0x64 */

/* ---- 需要的三个 uapi 结构（大小必须与内核侧一致）---- */
struct drm_version {
    int    version_major, version_minor, version_patchlevel;
    size_t name_len;  char *name;
    size_t date_len;  char *date;
    size_t desc_len;  char *desc;
};

struct drm_mode_card_res {
    uint64_t fb_id_ptr, crtc_id_ptr, connector_id_ptr, encoder_id_ptr;
    uint32_t count_fbs, count_crtcs, count_connectors, count_encoders;
    uint32_t min_width, max_width, min_height, max_height;
};

struct drm_mode_create_dumb {
    uint32_t height, width, bpp, flags;
    uint32_t handle, pitch;
    uint64_t size;
};

static const unsigned long IOCTL_VERSION     = IOWR(DRM_TYPE, 0x00, struct drm_version);
static const unsigned long IOCTL_GETRES      = IOWR(DRM_TYPE, 0xA0, struct drm_mode_card_res);
static const unsigned long IOCTL_CREATE_DUMB = IOWR(DRM_TYPE, 0xB2, struct drm_mode_create_dumb);

static void try_dumb(int fd, uint32_t w, uint32_t h, uint32_t bpp, const char *tag)
{
    struct drm_mode_create_dumb c;
    memset(&c, 0, sizeof c);
    c.width = w; c.height = h; c.bpp = bpp; c.flags = 0;
    errno = 0;
    int r = ioctl(fd, IOCTL_CREATE_DUMB, &c);
    printf("CREATE_DUMB %-22s %ux%u bpp=%-2u -> rc=%d errno=%d (%s)",
           tag, w, h, bpp, r, errno, strerror(errno));
    if (r == 0)
        printf("  handle=%u pitch=%u size=%llu",
               c.handle, c.pitch, (unsigned long long)c.size);
    printf("\n");
    if (r == 0) {
        /* 顺手把内核真的建出来的 scanout 资源尺寸也记下来：pitch 必须是 w*4 */
        if (c.pitch != w * 4)
            printf("   !! pitch 异常：期望 %u，实得 %u\n", w * 4, c.pitch);
    }
}

int main(void)
{
    printf("==== drmdumbprobe: CREATE_DUMB bpp 接受度 ====\n");
    printf("ioctl 编码自证（十六进制，应与 libdrm 编译期常量一致）:\n");
    printf("  VERSION     = 0x%08lx\n", IOCTL_VERSION);
    printf("  GETRESOURCES= 0x%08lx\n", IOCTL_GETRES);
    printf("  CREATE_DUMB = 0x%08lx\n", IOCTL_CREATE_DUMB);
    printf("sizeof: version=%zu card_res=%zu create_dumb=%zu\n",
           sizeof(struct drm_version),
           sizeof(struct drm_mode_card_res),
           sizeof(struct drm_mode_create_dumb));

    errno = 0;
    int fd = open(DEV0, O_RDWR | O_CLOEXEC);
    printf("\nopen(%s, O_RDWR) -> %d errno=%d (%s)\n", DEV0, fd, errno, strerror(errno));
    if (fd < 0) return 1;

    /* --- 对照 1：VERSION（已知 P0 修好后可通，作为编码正确性的自证）--- */
    {
        char name[64] = {0}, date[64] = {0}, desc[128] = {0};
        struct drm_version v;
        memset(&v, 0, sizeof v);
        v.name = name; v.name_len = sizeof name;
        v.date = date; v.date_len = sizeof date;
        v.desc = desc; v.desc_len = sizeof desc;
        errno = 0;
        int r = ioctl(fd, IOCTL_VERSION, &v);
        printf("对照1 VERSION -> rc=%d errno=%d (%s)", r, errno, strerror(errno));
        if (r == 0) printf("  driver='%s' %d.%d.%d", name,
                           v.version_major, v.version_minor, v.version_patchlevel);
        printf("\n");
        if (r != 0) {
            printf("!! VERSION 都不通 ⇒ 本探针的 _IOWR 编码与内核不匹配，\n");
            printf("!! 下面的 CREATE_DUMB 结果**不能**解释为'内核拒绝该 bpp'。\n");
        }
    }

    /* --- 对照 2：GETRESOURCES（把内核侧资源数记下来，佐证 modeset 面已实现）--- */
    {
        struct drm_mode_card_res cr;
        memset(&cr, 0, sizeof cr);
        errno = 0;
        int r = ioctl(fd, IOCTL_GETRES, &cr);
        printf("对照2 GETRESOURCES -> rc=%d errno=%d (%s)  fbs=%u crtcs=%u conns=%u encs=%u\n",
               r, errno, strerror(errno),
               cr.count_fbs, cr.count_crtcs, cr.count_connectors, cr.count_encoders);
    }

    /* --- 主角：同一设备、同一尺寸，只变 bpp ---
     * 1280x800 取自 Xorg 从 EDID 探到的 Virtual-1 当前模式
     *  （`Modeline "current"x60.0 ... 1280 1328 1360 1440 800 803 811 817`）,
     *   即 modesetting 真正会去申请的尺寸，不是随手取的数。 */
    printf("\n---- CREATE_DUMB 矩阵（尺寸取 Xorg 实测 Virtual-1 模式 1280x800）----\n");
    try_dumb(fd, 1280, 800, 32, "32bpp (XRGB8888)");
    try_dumb(fd, 1280, 800, 24, "24bpp (RGB888 前缓冲)");
    try_dumb(fd, 1280, 800, 16, "16bpp (对照)");
    printf("\n---- 边界对照（用于确认 EINVAL 语义一致，非 bpp 专有）----\n");
    try_dumb(fd, 0,    800, 32, "width=0");
    try_dumb(fd, 1280, 0,   32, "height=0");

    close(fd);
    printf("\n==== drmdumbprobe done ====\n");
    return 0;
}
