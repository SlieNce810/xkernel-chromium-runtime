// BUILD: dynamic
/* weston_sim.c —— 用**真实 libdrm** 逐行复现 Weston 14 的 plane 创建逻辑
 *
 * 为什么需要它
 * ------------
 * Weston 在 plane 创建失败时**静默跳过**（`create_sprites()` 里两处裸 `continue`，
 * `drm_plane_create()` 里还有两条不打日志的 `goto`），所以日志只会给出最后那句
 * `Failed to find primary plane for output ...`，看不到"在哪一步被丢弃"。
 *
 * 本探针在 Weston 的位置上把它的每一步**原样执行一遍**（同一 fd、同一 libdrm、
 * 同一调用顺序），并把每一步的判读打印出来。它调用的 libdrm 函数与 Weston 完全相同：
 *     drmModeGetPlaneResources / drmModeGetPlane
 *     drmModeObjectGetProperties / drmModeGetProperty（★ 枚举值在这里）
 *     drmModeGetPropertyBlob / drmModeFormatModifierBlobIterNext
 * 复刻的 Weston 逻辑（源码行号按 weston-14.0.2）：
 *     drm.c:1137 drm_plane_create()
 *       ├─ drmModeObjectGetProperties() 失败 → "couldn't get plane properties" → 丢弃
 *       ├─ drm_property_info_populate()  按**名字**匹配属性（含枚举值匹配）
 *       ├─ plane->type = <"type" 属性的值>；== WDRM_PLANE_TYPE__COUNT(4) → 静默丢弃
 *       ├─ drm_plane_populate_formats()  → <0 静默丢弃
 *       │   └─ kms.c:569：IN_FORMATS blob → drmModeFormatModifierBlobIterNext 迭代
 *       │        → weston_drm_format_add_modifier()：**同一 (fmt,modifier) 出现两次会返回 -1**
 *       └─ 成功后挂入 device->plane_list
 *     drm.c:1325 create_sprites() 里两处 `continue` 就是"静默丢弃"
 *
 * 输出：每步一行 [SIM] ...，最后 [SIM_SUM] 给结论；[PROBE_EXIT] 机读行。
 */
#define _GNU_SOURCE
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

/* Weston 14 的 plane 类型枚举（drm-internal.h） */
enum { WDRM_TYPE_PRIMARY = 1, WDRM_TYPE_CURSOR = 2, WDRM_TYPE_OVERLAY = 3, WDRM_TYPE_COUNT = 4 };

typedef drmModePlaneResPtr (*fn_get_plane_res)(int);
typedef drmModePlanePtr    (*fn_get_plane)(int, uint32_t);
typedef drmModeObjectPropertiesPtr (*fn_obj_props)(int, uint32_t, uint32_t);
typedef drmModePropertyPtr (*fn_get_prop)(int, uint32_t);
typedef drmModePropertyBlobPtr (*fn_get_blob)(int, uint32_t);
typedef void (*fn_free_plane_res)(drmModePlaneResPtr);
typedef void (*fn_free_plane)(drmModePlanePtr);
typedef void (*fn_free_obj_props)(drmModeObjectPropertiesPtr);
typedef void (*fn_free_prop)(drmModePropertyPtr);
typedef void (*fn_free_blob)(drmModePropertyBlobPtr);
typedef void (*fn_free_version)(drmVersionPtr);
typedef drmVersionPtr (*fn_get_version)(int);
/* ★ 注意：本探针用 dlopen，不链接 libdrm ⇒ **每一个** libdrm 函数都必须经 dlsym，
 *   直接调用会在链接期报 undefined reference（哪怕 guest 库里确实导出了该符号）。 */
typedef bool (*fn_iter_next)(const drmModePropertyBlobRes *, drmModeFormatModifierIterator *);

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("==== weston_sim: 复现 Weston 14 的 plane 创建逻辑（真实 libdrm）====\n");

    void *h = dlopen("libdrm.so.2", RTLD_NOW | RTLD_GLOBAL);
    if (!h) { printf("[SIM] dlopen(libdrm.so.2) FAILED: %s\n", dlerror());
              printf("[PROBE_EXIT] 5 verdict=LIB_FAIL\n"); return 5; }

    fn_get_plane_res  p_pres   = (fn_get_plane_res)  dlsym(h, "drmModeGetPlaneResources");
    fn_get_plane      p_plane  = (fn_get_plane)      dlsym(h, "drmModeGetPlane");
    fn_obj_props      p_ops    = (fn_obj_props)      dlsym(h, "drmModeObjectGetProperties");
    fn_get_prop       p_prop   = (fn_get_prop)       dlsym(h, "drmModeGetProperty");
    fn_get_blob       p_blob   = (fn_get_blob)       dlsym(h, "drmModeGetPropertyBlob");
    fn_free_plane_res p_fpres  = (fn_free_plane_res) dlsym(h, "drmModeFreePlaneResources");
    fn_free_plane     p_fpl    = (fn_free_plane)     dlsym(h, "drmModeFreePlane");
    fn_free_obj_props p_fops   = (fn_free_obj_props) dlsym(h, "drmModeFreeObjectProperties");
    fn_free_prop      p_fprop  = (fn_free_prop)      dlsym(h, "drmModeFreeProperty");
    fn_free_blob      p_fblob  = (fn_free_blob)      dlsym(h, "drmModeFreePropertyBlob");
    fn_get_version    p_ver    = (fn_get_version)    dlsym(h, "drmGetVersion");
    fn_free_version   p_fver   = (fn_free_version)   dlsym(h, "drmFreeVersion");
    fn_iter_next      p_iter   = (fn_iter_next)      dlsym(h, "drmModeFormatModifierBlobIterNext");

    if (!p_iter) {
        printf("[SIM] !! dlsym(drmModeFormatModifierBlobIterNext) 失败 —— 无法复现 Weston 的格式迭代\n");
        printf("[PROBE_EXIT] 5 verdict=LIB_FAIL\n");
        return 5;
    }

    if (!p_pres || !p_plane || !p_ops || !p_prop || !p_blob) {
        printf("[SIM] 关键符号缺失\n");
        printf("[PROBE_EXIT] 5 verdict=LIB_FAIL\n");
        return 5;
    }

    int fd = open(DEV0, O_RDWR | O_CLOEXEC);
    if (fd < 0) { printf("[SIM] open(%s) FAILED errno=%d\n", DEV0, errno);
                  printf("[PROBE_EXIT] 2 verdict=OPEN_FAIL\n"); return 2; }
    if (p_ver) {
        drmVersionPtr v = p_ver(fd);
        if (v) { printf("[SIM] driver='%.*s' %d.%d.%d\n", (int)v->name_len, v->name,
                        v->version_major, v->version_minor, v->version_patchlevel);
                 if (p_fver) p_fver(v); }
    }

    int planefail = 0;          /* 有多少个 plane 会被 Weston 静默丢弃 */
    int nplanes = 0;

    drmModePlaneResPtr pres = p_pres(fd);
    if (!pres) {
        printf("[SIM] drmModeGetPlaneResources FAILED errno=%d\n", errno);
        printf("[SIM_SUM] plane_res=FAIL planefail=0 verdict=SIM_FAIL\n");
        printf("[PROBE_EXIT] 3 verdict=SIM_FAIL\n");
        close(fd);
        return 3;
    }
    printf("[SIM] drmModeGetPlaneResources OK count_planes=%u\n", pres->count_planes);

    for (uint32_t i = 0; i < pres->count_planes; i++) {
        uint32_t pid = pres->planes[i];
        nplanes++;
        printf("\n[SIM] ===== plane id=%u =====\n", pid);

        /* --- 1) create_sprites(): drmModeGetPlane --- */
        errno = 0;
        drmModePlanePtr kp = p_plane(fd, pid);
        if (!kp) {
            printf("[SIM] drmModeGetPlane FAILED errno=%d(%s)  ⇒ Weston `continue`（静默丢弃）\n",
                   errno, strerror(errno));
            planefail++;
            continue;
        }
        printf("[SIM] drmModeGetPlane OK: crtc_id=%u possible_crtcs=0x%x count_formats=%u\n",
               kp->crtc_id, kp->possible_crtcs, kp->count_formats);
        printf("[SIM]   formats:");
        for (uint32_t f = 0; f < kp->count_formats && f < 8; f++) {
            uint32_t x = kp->formats[f];
            printf(" 0x%08x('%c%c%c%c')", x, x & 0xff, (x >> 8) & 0xff, (x >> 16) & 0xff, (x >> 24) & 0xff);
        }
        printf("\n");

        /* --- 2) drm_plane_create(): drmModeObjectGetProperties --- */
        errno = 0;
        drmModeObjectPropertiesPtr props = p_ops(fd, pid, DRM_MODE_OBJECT_PLANE);
        if (!props) {
            printf("[SIM] drmModeObjectGetProperties FAILED errno=%d(%s)\n", errno, strerror(errno));
            printf("[SIM]   ⇒ Weston 会打 \"couldn't get plane properties\" 并丢弃该 plane\n");
            planefail++;
            if (p_fpl) p_fpl(kp);
            continue;
        }
        printf("[SIM] drmModeObjectGetProperties OK count_props=%u\n", props->count_props);

        /* --- 3) drm_property_info_populate(): 按名字匹配 + 枚举值匹配 --- */
        int type_prop_index = -1;
        uint64_t type_value_raw = 0;
        int primary_enum_valid = 0;
        uint64_t primary_enum_value = 0;
        uint32_t in_formats_blob_id = 0;

        for (uint32_t j = 0; j < props->count_props; j++) {
            drmModePropertyPtr pr = p_prop(fd, props->props[j]);
            if (!pr) { printf("[SIM]   [prop %u] drmModeGetProperty FAILED（Weston 遇到会 continue）\n", j); continue; }
            printf("[SIM]   [prop %2u] id=0x%03x val=%-6llu flags=0x%x enums=%d name=\"%s\"",
                   j, pr->prop_id, (unsigned long long)props->prop_values[j], pr->flags,
                   pr->count_enums, pr->name);
            if (pr->count_enums > 0 && pr->count_enums <= 6) {
                printf(" {");
                for (int e = 0; e < pr->count_enums; e++)
                    printf("%s=%llu%s", pr->enums[e].name,
                           (unsigned long long)pr->enums[e].value,
                           e + 1 < pr->count_enums ? "," : "");
                printf("}");
            }
            printf("\n");

            if (strcmp(pr->name, "type") == 0) {
                type_prop_index = (int)j;
                type_value_raw = props->prop_values[j];
                /* Weston: 若声明为 enum 的属性其 flags 不含 ENUM/BITMASK ⇒ prop_id 清零（并打日志） */
                if (!(pr->flags & DRM_MODE_PROP_ENUM) && !(pr->flags & DRM_MODE_PROP_BITMASK)) {
                    printf("[SIM]   !! \"type\" 不是 ENUM/BITMASK ⇒ Weston 会打 'expected property type to be an enum' 并清零 prop_id\n");
                }
                for (int e = 0; e < pr->count_enums; e++) {
                    if (strcmp(pr->enums[e].name, "Primary") == 0) {
                        primary_enum_valid = 1;
                        primary_enum_value = pr->enums[e].value;
                    }
                }
            }
            if (strcmp(pr->name, "IN_FORMATS") == 0) {
                in_formats_blob_id = (uint32_t)props->prop_values[j];
            }
            if (p_fprop) p_fprop(pr);
        }

        /* 判定：Weston 视角的 plane->type */
        if (type_prop_index < 0) {
            printf("[SIM] ★ \"type\" 属性不存在 ⇒ plane->type 取默认值 %d(COUNT) ⇒ 静默丢弃\n", WDRM_TYPE_COUNT);
            planefail++;
        } else {
            printf("[SIM] type 属性: raw_value=%llu；Primary 枚举%s（值=%llu）\n",
                   (unsigned long long)type_value_raw,
                   primary_enum_valid ? "存在" : "**缺失**",
                   (unsigned long long)primary_enum_value);
            if (type_value_raw != WDRM_TYPE_PRIMARY) {
                printf("[SIM] ★ raw 值 != PRIMARY(1) ⇒ Weston 认为它不是主 plane ⇒ 丢弃\n");
                planefail++;
            } else if (!primary_enum_valid) {
                printf("[SIM] 注意: raw 值=1(PRIMARY)，但枚举名 'Primary' 缺失 ——"
                       " Weston 的 drm_property_get_value 用的是 raw 值，通常仍判定为 PRIMARY；\n");
                printf("[SIM]       但任何依赖枚举名解析的路径（如 drm_property_get_value_from_name）会失败\n");
            } else {
                printf("[SIM] ✓ Weston 视角 plane->type = PRIMARY\n");
            }
        }

        /* --- 4) drm_plane_populate_formats(): IN_FORMATS blob + 迭代器 + 去重判定 --- */
        if (in_formats_blob_id == 0) {
            printf("[SIM]   IN_FORMATS 属性值=0 ⇒ 走 fallback（用 kplane->formats，不致命）\n");
        } else {
            errno = 0;
            drmModePropertyBlobPtr blob = p_blob(fd, in_formats_blob_id);
            if (!blob) {
                printf("[SIM]   drmModeGetPropertyBlob(%u) FAILED errno=%d ⇒ Weston 走 fallback（不致命）\n",
                       in_formats_blob_id, errno);
            } else {
                printf("[SIM]   blob OK: length=%u\n", blob->length);
                {
                    const unsigned char *raw = (const unsigned char *)blob->data;
                    unsigned n = blob->length < 64 ? blob->length : 64;
                    printf("[SIM]   blob raw[%u]:", n);
                    for (unsigned b = 0; b < n; b++) printf(" %02x", raw[b]);
                    printf("\n");
                }
                drmModeFormatModifierIterator it = {0};
                uint32_t fmt_prev = 0xFFFFFFFFu;
                uint32_t f_seen[64]; uint64_t m_seen[64]; int n_seen = 0, dup = 0, n_iter = 0;
                while (p_iter(blob, &it)) {
                    n_iter++;
                    printf("[SIM]   iter[%d]: fmt=0x%08x mod=0x%llx\n", n_iter - 1,
                           it.fmt, (unsigned long long)it.mod);
                    for (int s = 0; s < n_seen; s++) {
                        if (f_seen[s] == it.fmt && m_seen[s] == it.mod) dup++;
                    }
                    if (n_seen < 64) { f_seen[n_seen] = it.fmt; m_seen[n_seen] = (uint64_t)it.mod; n_seen++; }
                    if (it.fmt != fmt_prev) fmt_prev = it.fmt;
                }
                printf("[SIM]   迭代器产出 %d 组 (fmt,modifier)；**重复组合 = %d**\n", n_iter, dup);
                if (dup > 0) {
                    printf("[SIM] ★ 有重复 ⇒ Weston 的 weston_drm_format_add_modifier() 返回 -1\n");
                    printf("[SIM]   ⇒ drm_plane_populate_formats()<0 ⇒ drm_plane_create() 静默丢弃该 plane\n");
                    planefail++;
                } else if (n_iter == 0) {
                    printf("[SIM] ★ 迭代器产出 0 组 ⇒ Weston 的 formats 数组为空（后续校验会失败）\n");
                } else {
                    printf("[SIM] ✓ 无重复修饰符，格式路径正常\n");
                }
                if (p_fblob) p_fblob(blob);
            }
        }

        if (p_fops) p_fops(props);
        if (p_fpl) p_fpl(kp);
    }

    if (p_fpres) p_fpres(pres);
    close(fd);

    const char *verdict = "SIM_OK";
    if (nplanes == 0) verdict = "SIM_NO_PLANE";
    else if (planefail > 0) verdict = "SIM_PLANE_DROPPED";
    printf("\n[SIM_SUM] planes=%d dropped_by_weston=%d verdict=%s\n", nplanes, planefail, verdict);
    printf("[PROBE_EXIT] %d verdict=%s\n", planefail > 0 ? 3 : 0, verdict);
    printf("==== weston_sim done ====\n");
    return planefail > 0 ? 3 : 0;
}
