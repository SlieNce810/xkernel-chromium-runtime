// BUILD: dynamic
/* drmstdprobe.c — 标准 libdrm 客户端探针（阶段 1.2 的核心证据工具）
 *
 * 为什么必须有它（而不是只有 drmplaneprobe）
 * ------------------------------------------
 * drmplaneprobe 是**手写 ioctl** 的探针，它只能证明"内核接受什么编码"。
 * 历史事故（report/31 → report/32）：手写探针与内核用了同一个**错误**布局（48 字节），
 * 二者自洽 ⇒ 探针变绿，但标准 libdrm（32 字节请求）反而失败 —— 假绿由此产生。
 * 所以"内核 ABI 对真实客户端是否可用"必须由**真实客户端**来回答，这就是本探针。
 *
 * 为什么用 dlopen，而不是链接期 -ldrm
 * ----------------------------------
 * guest 的 libdrm.so.2 是 Alpine 用较新 binutils 构建的，含 `.relr.dyn`（DT_RELR）段；
 * 本项目交叉工具链的 ld（binutils 2.36）不认识该段，直接 `-l:libdrm.so.2` 会报
 *   "unknown type [0x13] section `.relr.dyn` / skipping incompatible ... cannot find"
 * 改为**运行期 dlopen**：链接期完全不碰 libdrm，运行期加载 guest 的**真实**库 ——
 * 证据强度不变；而"实际加载了哪个文件"由 dladdr 直接给出，比链接期路径更硬。
 * （musl 动态链接才支持 dlopen：不能 -static。）
 *
 * 它做的事（与 Weston 的调用形态一致）
 * ------------------------------------
 *   1. dlopen/dlsym 解析 guest 的 libdrm，并报告实际加载路径 + 文件尺寸
 *   2. drmGetVersion（驱动自证：证明 fd 上的 DRM 是活的）
 *   3. drmModeGetResources（crtc/connector/encoder 枚举）
 *   4. drmModeGetPlaneResources（数量查询 + 二次取数两段式）
 *   5. 对每个 plane_id：drmModeGetPlane（★ Weston 就是这个动作逐个失败）
 *
 * 构建：`// BUILD: dynamic`（t490_round.sh 解析）→ 不加 -static，无额外库
 * 运行前提（guest）：/lib/ld-musl-aarch64.so.1 与 /usr/lib/libdrm.so.2 存在
 *
 * 输出（机器行，供 round_assert ③.5 抓取）
 *   [STD] ...       逐步事实
 *   [STD_EXIT] <code> verdict=<STD_OK|STD_FAIL|OPEN_FAIL|LIB_FAIL>
 *   [PROBE_EXIT] <code> verdict=<...>   ← 与其它探针统一的必验项格式
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <dlfcn.h>

#include <xf86drm.h>
#include <xf86drmMode.h>

#define DEV0 "/dev/dri/card0"

typedef drmVersionPtr     (*fn_get_version)(int fd);
typedef void              (*fn_free_version)(drmVersionPtr);
typedef drmModeResPtr     (*fn_get_resources)(int fd);
typedef void              (*fn_free_resources)(drmModeResPtr);
typedef drmModePlaneResPtr (*fn_get_plane_res)(int fd);
typedef void              (*fn_free_plane_res)(drmModePlaneResPtr);
typedef drmModePlanePtr   (*fn_get_plane)(int fd, uint32_t plane_id);
typedef void              (*fn_free_plane)(drmModePlanePtr);

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);

    printf("==== drmstdprobe: 标准 libdrm 客户端（阶段1.2）====\n");
    printf("[STD] 头文件侧: sizeof(drm_mode_get_plane)=%zu  DRM_IOCTL_MODE_GETPLANE=0x%08lx\n",
           sizeof(struct drm_mode_get_plane), (unsigned long)DRM_IOCTL_MODE_GETPLANE);

    /* ---- 0) dlopen guest 的真实 libdrm ---- */
    void *h = dlopen("libdrm.so.2", RTLD_NOW | RTLD_GLOBAL);
    if (!h)
        h = dlopen("/usr/lib/libdrm.so.2", RTLD_NOW | RTLD_GLOBAL);
    if (!h) {
        printf("[STD] dlopen(libdrm.so.2) FAILED: %s\n", dlerror());
        printf("[STD_EXIT] 5 verdict=LIB_FAIL\n");
        printf("[PROBE_EXIT] 5 verdict=LIB_FAIL\n");
        return 5;
    }
    fn_get_version     p_getver    = (fn_get_version)    dlsym(h, "drmGetVersion");
    fn_free_version    p_freever   = (fn_free_version)   dlsym(h, "drmFreeVersion");
    fn_get_resources   p_getres    = (fn_get_resources)  dlsym(h, "drmModeGetResources");
    fn_free_resources  p_freeres   = (fn_free_resources) dlsym(h, "drmModeFreeResources");
    fn_get_plane_res   p_getpres   = (fn_get_plane_res)  dlsym(h, "drmModeGetPlaneResources");
    fn_free_plane_res  p_freepres  = (fn_free_plane_res) dlsym(h, "drmModeFreePlaneResources");
    fn_get_plane       p_getplane  = (fn_get_plane)      dlsym(h, "drmModeGetPlane");
    fn_free_plane      p_freeplane = (fn_free_plane)     dlsym(h, "drmModeFreePlane");

    if (!p_getver || !p_getres || !p_getpres || !p_getplane) {
        printf("[STD] dlsym 关键符号缺失: getver=%p getres=%p getpres=%p getplane=%p\n",
               (void *)p_getver, (void *)p_getres, (void *)p_getpres, (void *)p_getplane);
        printf("[STD_EXIT] 5 verdict=LIB_FAIL\n");
        printf("[PROBE_EXIT] 5 verdict=LIB_FAIL\n");
        return 5;
    }
    {
        Dl_info dli;
        if (dladdr((void *)p_getplane, &dli) && dli.dli_fname)
            printf("[STD] libdrm 实际加载: %s\n", dli.dli_fname);
        else
            printf("[STD] libdrm 实际加载: (dladdr 不可用)\n");
    }

    int fd = open(DEV0, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        printf("[STD] open(%s) FAILED errno=%d\n", DEV0, errno);
        printf("[STD_EXIT] 2 verdict=OPEN_FAIL\n");
        printf("[PROBE_EXIT] 2 verdict=OPEN_FAIL\n");
        return 2;
    }
    printf("[STD] open(%s) ok fd=%d\n", DEV0, fd);

    /* ---- 1) 驱动自证 ---- */
    {
        drmVersionPtr v = p_getver(fd);
        if (v) {
            char nm[64] = {0};
            int nl = v->name_len;
            size_t n = (nl > 0 && (size_t)nl < sizeof nm) ? (size_t)nl : 0;
            if (n > 0) memcpy(nm, v->name, n);
            printf("[STD] drmGetVersion OK driver='%s' %d.%d.%d\n",
                   nm, v->version_major, v->version_minor, v->version_patchlevel);
            if (p_freever) p_freever(v);
        } else {
            printf("[STD] drmGetVersion FAILED errno=%d\n", errno);
        }
    }

    int exit_code = 0;

    /* ---- 2) drmModeGetResources ---- */
    errno = 0;
    drmModeResPtr res = p_getres(fd);
    if (res) {
        printf("[STD] drmModeGetResources OK: crtcs=%d connectors=%d encoders=%d fbs=%d\n",
               res->count_crtcs, res->count_connectors, res->count_encoders, res->count_fbs);
        for (int i = 0; i < res->count_crtcs && i < 4; i++)
            printf("[STD]   crtc[%d]=%u\n", i, res->crtcs[i]);
        for (int i = 0; i < res->count_connectors && i < 4; i++)
            printf("[STD]   connector[%d]=%u\n", i, res->connectors[i]);
        if (p_freeres) p_freeres(res);
    } else {
        printf("[STD] drmModeGetResources FAILED errno=%d\n", errno);
    }

    /* ---- 3) drmModeGetPlaneResources（两段式，正是 Weston 的调用形态）---- */
    errno = 0;
    drmModePlaneResPtr pres = p_getpres(fd);
    if (!pres) {
        printf("[STD] drmModeGetPlaneResources FAILED errno=%d  ← 标准客户端在第一段就失败\n", errno);
        exit_code = 3;
    } else {
        printf("[STD] drmModeGetPlaneResources OK: count_planes=%u\n", pres->count_planes);
        for (uint32_t i = 0; i < pres->count_planes; i++) {
            uint32_t pid = pres->planes[i];
            errno = 0;
            drmModePlanePtr pl = p_getplane(fd, pid);
            if (!pl) {
                printf("[STD] drmModeGetPlane(plane_id=%u) FAILED errno=%d(%s)"
                       "  ← ★ 标准客户端失败点\n",
                       pid, errno, strerror(errno));
                exit_code = 3;
                continue;
            }
            printf("[STD] drmModeGetPlane(plane_id=%u) OK: crtc_id=%u fb_id=%u"
                   " possible_crtcs=0x%x gamma_size=%u count_formats=%u\n",
                   pid, pl->crtc_id, pl->fb_id, pl->possible_crtcs, pl->gamma_size, pl->count_formats);
            printf("[STD]   formats:");
            for (uint32_t f = 0; f < pl->count_formats && f < 8; f++)
                printf(" 0x%08x", pl->formats ? pl->formats[f] : 0);
            printf("\n");
            if (p_freeplane) p_freeplane(pl);
        }
        if (p_freepres) p_freepres(pres);
    }

    printf("[STD_EXIT] %d verdict=%s\n", exit_code, exit_code == 0 ? "STD_OK" : "STD_FAIL");
    printf("[PROBE_EXIT] %d verdict=%s\n", exit_code, exit_code == 0 ? "STD_OK" : "STD_FAIL");
    close(fd);
    printf("==== drmstdprobe done ====\n");
    return exit_code;
}
