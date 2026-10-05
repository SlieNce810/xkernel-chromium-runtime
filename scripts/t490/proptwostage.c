// BUILD: dynamic
/* proptwostage.c —— 精确定位 `GETPROPERTY` 两段式在哪一段失败（阶段3 根因收敛）
 *
 * 背景（weston10 轮证据）
 * ----------------------
 * `weston_sim` 复现 Weston 的 plane 创建时发现：`drmModeObjectGetProperties` 成功返回 12 个
 * 属性，但**每一个** `drmModeGetProperty()` 都失败 ⇒ Weston 眼里没有 "type" 属性 ⇒
 * `plane->type == WDRM_PLANE_TYPE__COUNT` ⇒ `drm_plane_create()` 静默丢弃 plane ⇒
 * `Failed to find primary plane`。
 *
 * 而同一轮里 `drmplaneprobe`（**单段**手写 ioctl）读 12 个属性名全部成功 —— 差异只可能在
 * libdrm 的**两段式**上。libdrm 2.4.124 的 `drmModeGetProperty()` 原文（xf86drmMode.c:668）：
 *
 *     memclear(prop); prop.prop_id = id;
 *     if (drmIoctl(fd, GETPROPERTY, &prop)) return 0;        // ← call#1 取 flags/name/counts
 *     if (prop.count_values)      prop.values_ptr    = malloc(count_values * 8);
 *     if (prop.count_enum_blobs && flags&(ENUM|BITMASK))
 *                                 prop.enum_blob_ptr = malloc(count_enum_blobs * sizeof(struct drm_mode_property_enum));
 *     if (drmIoctl(fd, GETPROPERTY, &prop)) { r = NULL; goto err; }   // ← call#2 回填
 *
 * 本探针对每个属性把两段**分开执行并逐段判定**，同时对照真实 libdrm 的结果，
 * 把"哪一段、什么 errno、越界多少字节"变成事实。
 *
 * 已知可疑点：x-kernel 的 `DrmModePropertyEnum` 是 `{ u64 value; [u8;32] name }` = **40 字节**，
 * 而标准 uapi `struct drm_mode_property_enum` 是 `{ u32 value; char name[32] }` = **36 字节**。
 * 若内核按 40 字节写入 libdrm 按 36 字节分配的缓冲，就会越界（3 项时越 12 字节）。
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <sys/ioctl.h>

#define DEV0 "/dev/dri/card0"
#define DRM_PROP_NAME_LEN 32
#define DRM_MODE_OBJECT_PLANE 0xeeeeeeeeu

/* 标准 uapi 布局 */
struct std_get_property {
    uint64_t values_ptr, enum_blob_ptr;
    uint32_t prop_id, flags;
    char     name[DRM_PROP_NAME_LEN];
    uint32_t count_values, count_enum_blobs;
};
struct std_obj_get_props {
    uint64_t props_ptr, prop_values_ptr;
    uint32_t count_props, obj_id, obj_type, reserved;
};
struct std_property_enum { uint32_t value; char name[DRM_PROP_NAME_LEN]; };   /* 36 B */

#define IOC_NRBITS 8
#define IOC_TYPEBITS 8
#define IOC_SIZEBITS 14
#define IOC_NRSHIFT 0
#define IOC_TYPESHIFT (IOC_NRSHIFT + IOC_NRBITS)
#define IOC_SIZESHIFT (IOC_TYPESHIFT + IOC_TYPEBITS)
#define IOC_DIRSHIFT (IOC_SIZESHIFT + IOC_SIZEBITS)
#define IOC(dir,type,nr,size) (((dir) << IOC_DIRSHIFT) | ((type) << IOC_TYPESHIFT) | ((nr) << IOC_NRSHIFT) | ((size) << IOC_SIZESHIFT))
#define IOWR(type,nr,size) IOC(3, type, nr, sizeof(size))

static const unsigned long REQ_GETPROPERTY  = IOWR('d', 0xA8, struct std_get_property);
static const unsigned long REQ_OBJ_GETPROPS = IOWR('d', 0xB9, struct std_obj_get_props);

typedef int (*fn_get_property_fd)(int, uint32_t);
typedef void *(*fn_void)(void *);

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("==== proptwostage: GETPROPERTY 两段式逐段定位 ====\n");
    printf("[STAGE] sizeof(std drm_mode_get_property)=%zu  REQ_GETPROPERTY=0x%08lx\n",
           sizeof(struct std_get_property), REQ_GETPROPERTY);

    int fd = open(DEV0, O_RDWR | O_CLOEXEC);
    if (fd < 0) { printf("[STAGE] open FAILED errno=%d\n", errno); printf("[PROBE_EXIT] 2 verdict=OPEN_FAIL\n"); return 2; }

    /* 先用 OBJ_GETPROPERTIES 拿 plane 的属性 id 列表（标准两段式） */
    uint32_t ids[32] = {0}; uint64_t vals[32] = {0};
    {
        struct std_obj_get_props og; memset(&og, 0, sizeof og);
        og.obj_id = 64; og.obj_type = DRM_MODE_OBJECT_PLANE;
        int r1 = ioctl(fd, REQ_OBJ_GETPROPS, &og);
        og.props_ptr = (uint64_t)(uintptr_t)ids;
        og.prop_values_ptr = (uint64_t)(uintptr_t)vals;
        og.count_props = 32;
        int r2 = ioctl(fd, REQ_OBJ_GETPROPS, &og);
        printf("[STAGE] OBJ_GETPROPERTIES r1=%d r2=%d count_props=%u\n", r1, r2, og.count_props);
    }

    int fail1 = 0, fail2 = 0, n = 0;
    for (uint32_t i = 0; i < 12; i++) {
        uint32_t id = ids[i];
        if (id == 0) continue;
        n++;

        /* ---- call#1：只带 prop_id（与 libdrm 第一段完全一致）---- */
        struct std_get_property p1; memset(&p1, 0, sizeof p1);
        p1.prop_id = id;
        errno = 0;
        int rc1 = ioctl(fd, REQ_GETPROPERTY, &p1);
        int e1 = errno;
        printf("[STAGE] prop[%u] id=0x%03x call#1 rc=%d errno=%d name=\"%s\" flags=0x%x count_values=%u count_enum_blobs=%u\n",
               i, id, rc1, e1, rc1 == 0 ? p1.name : "?", p1.flags, p1.count_values, p1.count_enum_blobs);
        if (rc1 != 0) { fail1++; continue; }

        /* ---- call#2：按 libdrm 的方式分配缓冲后重发 ---- */
        if (p1.count_values || p1.count_enum_blobs) {
            void *vbuf = NULL, *ebuf = NULL;
            size_t vsz = 0, esz = 0;
            if (p1.count_values) {
                vsz = (size_t)p1.count_values * sizeof(uint64_t);         /* libdrm 用 8 字节/项 */
                vbuf = malloc(vsz);
                if (vbuf) memset(vbuf, 0xAA, vsz);
            }
            if (p1.count_enum_blobs) {
                esz = (size_t)p1.count_enum_blobs * sizeof(struct std_property_enum);  /* 36 字节/项 */
                ebuf = malloc(esz);
                if (ebuf) memset(ebuf, 0xBB, esz);
            }
            struct std_get_property p2 = p1;      /* 保留 name/flags/counts */
            p2.values_ptr = (uint64_t)(uintptr_t)vbuf;
            p2.enum_blob_ptr = (uint64_t)(uintptr_t)ebuf;
            errno = 0;
            int rc2 = ioctl(fd, REQ_GETPROPERTY, &p2);
            int e2 = errno;
            printf("[STAGE]   call#2 rc=%d errno=%d(%s)  [values buf=%zuB enum buf=%zuB]\n",
                   rc2, e2, strerror(e2), vsz, esz);
            if (rc2 != 0) fail2++;
            else if (ebuf && esz >= 36) {
                /* 标准 36 字节布局下：前 2 项的 value/name */
                struct std_property_enum *se = (struct std_property_enum *)ebuf;
                printf("[STAGE]   enum[0]: value=%u name=\"%.*s\"\n", se[0].value, 32, se[0].name);
                if (p1.count_enum_blobs > 1)
                    printf("[STAGE]   enum[1]: value=%u name=\"%.*s\"\n", se[1].value, 32, se[1].name);
                /* 越界探测：若内核按 40 字节写入，第 3 项会落在 36*2=72 之后 */
                if (vsz) {
                    uint64_t *sv = (uint64_t *)vbuf;
                    printf("[STAGE]   values[0..%u]:", p1.count_values < 4 ? p1.count_values : 4);
                    for (uint32_t k = 0; k < p1.count_values && k < 4; k++)
                        printf(" %llu", (unsigned long long)sv[k]);
                    printf("\n");
                }
            }
            if (vbuf) free(vbuf);
            if (ebuf) free(ebuf);
        }
    }

    /* ---- 对照：真实 libdrm 的 drmModeGetProperty ---- */
    void *h = dlopen("libdrm.so.2", RTLD_NOW | RTLD_GLOBAL);
    if (h) {
        fn_get_property_fd p_lib = (fn_get_property_fd)dlsym(h, "drmModeGetProperty");
        printf("\n[STAGE] ==== 对照：真实 libdrm drmModeGetProperty ====\n");
        if (p_lib) {
            int ok = 0, bad = 0;
            for (uint32_t i = 0; i < n; i++) {
                void *pr = (void *)p_lib(fd, ids[i]);
                if (pr) { ok++; if (i < 3) printf("[STAGE]   libdrm prop 0x%03x OK\n", ids[i]); }
                else    { bad++; if (bad <= 3) printf("[STAGE]   libdrm prop 0x%03x FAILED errno=%d\n", ids[i], errno); }
            }
            printf("[STAGE] libdrm 结果：OK=%d FAILED=%d（共 %d 个属性）\n", ok, bad, n);
        }
    }

    printf("\n[STAGE_SUM] props=%d call1_fail=%d call2_fail=%d verdict=%s\n",
           n, fail1, fail2,
           (fail1 == 0 && fail2 == 0) ? "TWOSTAGE_OK" : (fail1 ? "CALL1_FAIL" : "CALL2_FAIL"));
    printf("[PROBE_EXIT] %d verdict=%s\n",
           (fail1 == 0 && fail2 == 0) ? 0 : 3,
           (fail1 == 0 && fail2 == 0) ? "TWOSTAGE_OK" : (fail1 ? "CALL1_FAIL" : "CALL2_FAIL"));
    close(fd);
    printf("==== proptwostage done ====\n");
    return (fail1 == 0 && fail2 == 0) ? 0 : 3;
}
