/* abi_probe.c — DRM uapi ABI 对照（宿主侧标准头文件基准）
 *
 * 目的（阶段1.1）：把「GETPLANE 的 ioctl 请求值到底是多少」从注释里的断言
 * 变成机器可复现的输出事实：
 *   A. 用**标准头文件** <drm/drm_mode.h> 输出 sizeof / 字段偏移 / DRM_IOCTL_MODE_GETPLANE
 *   B. 用 x-kernel io/drmdevice/src/consts.rs 的同一公式复算 32B 与 48B 两种布局
 *   C. 判定：标准编码与哪一种复算一致
 *
 * 背景：x-kernel 的 ioctl 分派是 `match cmd { <T as DrmIoctl>::CMD => ... }`
 *       精确匹配整数值，而 CMD = iowr::<T>(ty, nr) 把 size_of::<T>() 编进
 *       第 16–29 位 ⇒ 结构体尺寸不同 = 请求值不同 = 分派不命中（errno 95）。
 *
 * 编译（宿主侧，x86_64）：gcc -O0 -Wall -o abi_probe abi_probe.c
 * 运行：./abi_probe
 * 说明：uapi 结构体全为定宽整数（u32/u64），x86_64 与 aarch64 布局一致，
 *       故宿主侧 sizeof / 偏移可作为 AArch64 的对照基线。
 *       ★ 最终以 guest 实际 libdrm（2.124.0）的运行为准，本探针只提供基准值。
 */
#include <stdio.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/ioctl.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>

/* ---- x-kernel consts.rs 的同一公式（逐字复刻）----
 *   const fn ioc(dir, ty, nr, size) = (dir<<30)|(size<<16)|(ty<<8)|nr
 *   iowr<T>(ty, nr) = ioc(IOC_READ|IOC_WRITE, ty, nr, size_of::<T>() as u16)
 */
static unsigned long xk_iowr(unsigned long ty, unsigned long nr, unsigned long sz)
{
    return (3UL << 30) | (sz << 16) | (ty << 8) | nr;
}

/* 内核当前（p3 修改后）的 10 字段布局：fb_id 之后多了 crtc_x/crtc_y/x/y */
struct abi_get_plane_10f {
    uint32_t plane_id, crtc_id, fb_id;
    uint32_t crtc_x, crtc_y, x, y;
    uint32_t possible_crtcs, gamma_size, count_format_types;
    uint64_t format_type_ptr;
};

/* 内核原始（git HEAD）的 7 字段布局：与标准头文件同构 */
struct abi_get_plane_7f {
    uint32_t plane_id, crtc_id, fb_id;
    uint32_t possible_crtcs, gamma_size, count_format_types;
    uint64_t format_type_ptr;
};

/* ---- 编译期断言（阶段1.1 机器判据）----
 * 若某环境的头文件与 uapi 不符，编译即失败，不允许静默通过。
 * 这同时给出 aarch64 交叉工具链侧的尺寸证据（同一份源码交叉编译即验证）。 */
_Static_assert(sizeof(struct drm_mode_get_plane) == 32,
               "drm_mode_get_plane 必须是 32 字节");
_Static_assert(sizeof(struct drm_mode_get_plane_res) == 16,
               "drm_mode_get_plane_res 必须是 16 字节");
_Static_assert(sizeof(struct drm_mode_obj_get_properties) == 32,
               "drm_mode_obj_get_properties 必须是 32 字节");
_Static_assert(sizeof(struct drm_mode_get_property) == 64,
               "drm_mode_get_property 必须是 64 字节");

int main(void)
{
    printf("== A. 标准头文件事实 ==\n");
    printf("header                     : <drm/drm_mode.h>\n");
    printf("sizeof(drm_mode_get_plane) = %zu\n", sizeof(struct drm_mode_get_plane));
    printf("offsets: plane_id=%zu crtc_id=%zu fb_id=%zu possible_crtcs=%zu gamma_size=%zu count_format_types=%zu format_type_ptr=%zu\n",
           offsetof(struct drm_mode_get_plane, plane_id),
           offsetof(struct drm_mode_get_plane, crtc_id),
           offsetof(struct drm_mode_get_plane, fb_id),
           offsetof(struct drm_mode_get_plane, possible_crtcs),
           offsetof(struct drm_mode_get_plane, gamma_size),
           offsetof(struct drm_mode_get_plane, count_format_types),
           offsetof(struct drm_mode_get_plane, format_type_ptr));
    printf("DRM_IOCTL_MODE_GETPLANE    = 0x%08lX  (_IOC_DIR=%lu TYPE=0x%lX NR=0x%lX SIZE=%lu)\n",
           (unsigned long)DRM_IOCTL_MODE_GETPLANE,
           (unsigned long)_IOC_DIR(DRM_IOCTL_MODE_GETPLANE),
           (unsigned long)_IOC_TYPE(DRM_IOCTL_MODE_GETPLANE),
           (unsigned long)_IOC_NR(DRM_IOCTL_MODE_GETPLANE),
           (unsigned long)_IOC_SIZE(DRM_IOCTL_MODE_GETPLANE));

    printf("\n== B. 用 x-kernel 公式复算 ==\n");
    unsigned long std32 = xk_iowr('d', 0xB6, sizeof(struct drm_mode_get_plane));
    unsigned long head7 = xk_iowr('d', 0xB6, sizeof(struct abi_get_plane_7f));
    unsigned long bad10 = xk_iowr('d', 0xB6, sizeof(struct abi_get_plane_10f));
    printf("sizeof(标准 7 字段)        = %zu\n", sizeof(struct abi_get_plane_7f));
    printf("sizeof(内核 10 字段)       = %zu\n", sizeof(struct abi_get_plane_10f));
    printf("x-kernel iowr(标准 32B)    = 0x%08lX\n", std32);
    printf("x-kernel iowr(HEAD 7 字段) = 0x%08lX\n", head7);
    printf("x-kernel iowr(10 字段 48B) = 0x%08lX\n", bad10);

    printf("\n== C. 判定 ==\n");
    printf("标准头文件编码          = 0x%08lX\n", (unsigned long)DRM_IOCTL_MODE_GETPLANE);
    printf("  vs HEAD 32B 复算 : %s\n",
           (unsigned long)DRM_IOCTL_MODE_GETPLANE == head7
               ? "一致 ✓（HEAD 内核本可命中 libdrm 的请求）"
               : "不一致 ✗");
    printf("  vs 48B 复算      : %s\n",
           (unsigned long)DRM_IOCTL_MODE_GETPLANE == bad10
               ? "一致 ✓"
               : "不一致 ✗（当前内核即 48B 形态 ⇒ libdrm 请求落空 ⇒ errno=95）");
    printf("\n结论：%s\n",
           ((unsigned long)DRM_IOCTL_MODE_GETPLANE == head7) &&
                   ((unsigned long)DRM_IOCTL_MODE_GETPLANE != bad10)
               ? "原始 7 字段布局正确；p3 的 48B 扩展是回归"
               : "需人工复核");
    return 0;
}
