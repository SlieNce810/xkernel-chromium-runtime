/* drmplaneprobe.c — plane 属性面探针：定位 Weston "Failed to find primary plane" 的根因
 *
 * ★★ 2026-09-22 阶段0.4/1.3 结构性修正（本文件此前误导过一轮，务必读这段）★★
 *
 * 历史事故：本探针原先把 `struct drm_mode_get_plane` 写成了 **10 字段 48 字节**
 *   （在 fb_id 之后插了 crtc_x / crtc_y / x / y），并且内核侧也被改成同样的 48B。
 *   两者"自洽"⇒ 探针变绿；但**标准 libdrm 的 32 字节请求反而失配** ——
 *   因为 x-kernel 的 `iowr::<T>()` 把 size_of::<T>() 编进 ioctl 号第 16–29 位，
 *   分派是 `match cmd { <T as DrmIoctl>::CMD => ... }` 精确匹配。
 *   所以：**探针与内核自洽 ≠ 标准客户端可用**。本轮把探针回退为标准布局，
 *   并加 `_Static_assert` + `[PROBE_ABI]` 运行期自检，杜绝同类误判再次发生。
 *
 *   uapi 事实（已与 /usr/include/drm/drm_mode.h 及 aarch64 musl 工具链头对照）：
 *     struct drm_mode_get_plane = 6×u32 + u64 = **32 B**，无坐标字段；
 *     crtc_x/crtc_y/x/y 属于 `drm_mode_set_plane`，GETPLANE 里从来没有它们。
 *
 * 背景（weston6 轮的结论）
 * ------------------------
 * 双 shim 把 Weston 推进到了**有史以来最远的一步**：
 *     [12:48:44.621] using /dev/dri/card0
 *     [12:48:44.624] DRM: supports GBM modifiers
 *     [12:48:44.846] DRM: head 'Virtual-1' found, connector 48 is connected
 *     [12:48:44.873] Failed to find primary plane for output Virtual-1     ← 卡在这
 *     [12:48:44.876] Error: cannot enable output 'Virtual-1' without heads.
 *
 * 读 Weston 14 源码（libweston/backend-drm/drm.c）得到的候选失败点，共 4 条：
 *
 *   (a) drm.c:1174  plane->type = drm_property_get_value(&plane->props[WDRM_PLANE_TYPE], props,
 *                                                        WDRM_PLANE_TYPE__COUNT);
 *       —— 若属性名匹配不上 "type"，type 保持 COUNT ⇒ drm.c:1207 直接 `goto err_props`
 *          ⇒ plane 创建失败 ⇒ plane_list 为空 ⇒ find_special_plane 返回 NULL。
 *       属性名匹配依赖：drm_property_get_name() → drmModeGetProperty() → 内嵌 name 字段。
 *
 *   (b) drm.c:1200  drm_plane_populate_formats(..., device->fb_modifiers) < 0 ⇒ goto err
 *       日志已显示 "DRM: supports GBM modifiers" ⇒ 走 modifiers 路径 ⇒ 会解析 IN_FORMATS blob。
 *       （该函数在 blob 读不到时会安全 fallback，所以只有"读到但解析失败"才致命。）
 *
 *   (c) drm_plane_is_available(): `possible_crtcs & (1 << output->crtc->pipe)` 与
 *       `plane->crtc_id != 0 && != output->crtc->crtc_id` 两道闸。
 *
 *   (d) OBJ_GETPROPERTIES / GETPROPERTY / GETPROPBLOB 任一环节的返回值不对。
 *
 * 本探针按 libdrm 的真实两段式调用逐个复现，把 (a)(b)(d) 一次性变成可判读的事实：
 *   1. 自证 VERSION
 *   2. 【新增】[PROBE_ABI] 结构体尺寸自检（必须与标准 uapi 一致）
 *   3. GETPLANERESOURCES 两段式 → plane_id 列表
 *   4. GETPLANE → crtc_id / possible_crtcs / formats（★ rc 折进最终 verdict）
 *   5. OBJ_GETPROPERTIES(plane) 两段式 → prop_ids[] + values[]
 *   6. ★ 对每个 prop_id 调 GETPROPERTY@0xA8 → name（这就是 Weston 的 populate 动作）
 *      → 判定：能否找到 name=="type" 的属性、其 value 是否 == 1（PRIMARY）
 *   7. GETCAP(ADDFB2_MODIFIERS) —— 复现 Weston 的 use_modifiers 判据
 *   8. 若存在 IN_FORMATS blob → GETPROPBLOB 读出并 dump 头部，核对字段布局
 *
 * 退出码（阶段0.4 分层判据）：
 *   0 = 全部关键 ioctl 成功（verdict 可能是 TYPE_ATTR_MISSING / TYPE_NOT_PRIMARY
 *       —— 那是"接口正常、语义结论为否"，属有效发现）
 *   2 = 探针自身不可信（VERSION 失败）
 *   3 = 关键 ioctl 失败（探针可信、接口有问题）→ 调用方必须按失败处理
 *   4 = 结构体尺寸偏离标准 uapi → 探针结论不可用
 *   末尾固定打一行机器可读的 `[PROBE_EXIT] <code> verdict=<V>` 供轮后判据抓取。
 *
 * 编译：aarch64-linux-musl-gcc -static -O2 -o drmplaneprobe drmplaneprobe.c
 * 判定行前缀：[PROBE_ABI] / [SELF] / [CAP] / [PRES] / [PLANE] / [PROP] / [BLOB] / [ITER] / [PLANESUM] / [PROBE_EXIT]
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <sys/ioctl.h>

#define DEV0 "/dev/dri/card0"

#define IOC_NRBITS      8
#define IOC_TYPEBITS    8
#define IOC_SIZEBITS    14
#define IOC_DIRBITS     2
#define IOC_NRSHIFT     0
#define IOC_TYPESHIFT   (IOC_NRSHIFT + IOC_NRBITS)
#define IOC_SIZESHIFT   (IOC_TYPESHIFT + IOC_TYPEBITS)
#define IOC_DIRSHIFT    (IOC_SIZESHIFT + IOC_SIZEBITS)
#define IOC_WRITE       1U
#define IOC_READ        2U
#define IOC(dir,type,nr,size) \
    (((dir) << IOC_DIRSHIFT) | ((type) << IOC_TYPESHIFT) | \
     ((nr) << IOC_NRSHIFT) | ((size) << IOC_SIZESHIFT))
#define IOWR(type,nr,size)  IOC(IOC_READ|IOC_WRITE, type, nr, sizeof(size))
#define IOW(type,nr,size)   IOC(IOC_WRITE, type, nr, sizeof(size))

#define DRM_TYPE              'd'
#define DRM_PROP_NAME_LEN     32
#define DRM_MODE_OBJECT_PLANE 0xeeeeeeeeu
#define DRM_PLANE_TYPE_PRIMARY 1

struct drm_version {
    int version_major, version_minor, version_patchlevel;
    size_t name_len; char *name;
    size_t date_len; char *date;
    size_t desc_len; char *desc;
};

struct drm_mode_get_plane_res {
    uint64_t plane_id_ptr;
    uint32_t count_planes;
};

/* ★ 标准 uapi 布局：6×u32 + 1×u64 = 32 B（无 crtc_x/crtc_y/x/y —— 那是 set_plane 的字段） */
struct drm_mode_get_plane {
    uint32_t plane_id;
    uint32_t crtc_id;
    uint32_t fb_id;
    uint32_t possible_crtcs;
    uint32_t gamma_size;
    uint32_t count_format_types;
    uint64_t format_type_ptr;
};

struct drm_mode_obj_get_properties {
    uint64_t props_ptr, prop_values_ptr;
    uint32_t count_props, obj_id, obj_type, reserved;
};

struct drm_mode_get_property {
    uint64_t values_ptr, enum_blob_ptr;
    uint32_t prop_id, flags;
    char     name[DRM_PROP_NAME_LEN];
    uint32_t count_values, count_enum_blobs;
};

struct drm_mode_get_blob {
    uint32_t blob_id, length;
    uint64_t data;
};

struct drm_get_cap {
    uint64_t capability;
    uint64_t value;
};

/* 编译期硬断言：结构体一旦偏离标准 uapi，本文件直接编译失败（不给"自洽但错"留口子） */
_Static_assert(sizeof(struct drm_mode_get_plane) == 32,
               "drm_mode_get_plane 必须与标准 uapi 一致：32 字节");
_Static_assert(sizeof(struct drm_mode_get_plane_res) == 16,
               "drm_mode_get_plane_res 必须与标准 uapi 一致：16 字节");
_Static_assert(sizeof(struct drm_mode_get_property) == 64,
               "drm_mode_get_property 必须与标准 uapi 一致：64 字节");
_Static_assert(sizeof(struct drm_mode_obj_get_properties) == 32,
               "drm_mode_obj_get_properties 必须与标准 uapi 一致：32 字节");

static const unsigned long IOCTL_VERSION      = IOWR(DRM_TYPE, 0x00, struct drm_version);
static const unsigned long IOCTL_GET_CAP      = IOWR(DRM_TYPE, 0x0c, struct drm_get_cap);
static const unsigned long IOCTL_GETPLANERES  = IOWR(DRM_TYPE, 0xB5, struct drm_mode_get_plane_res);
static const unsigned long IOCTL_GETPLANE     = IOWR(DRM_TYPE, 0xB6, struct drm_mode_get_plane);
static const unsigned long IOCTL_OBJ_GETPROPS = IOWR(DRM_TYPE, 0xB9, struct drm_mode_obj_get_properties);
static const unsigned long IOCTL_GETPROPERTY  = IOWR(DRM_TYPE, 0xA8, struct drm_mode_get_property);
static const unsigned long IOCTL_GETPROPBLOB  = IOWR(DRM_TYPE, 0xAA, struct drm_mode_get_blob);

#define DRM_CAP_ADDFB2_MODIFIERS 0x10

static void decode_flags(uint32_t f, char *out, size_t n)
{
    static const struct { uint32_t bit; const char *name; } tbl[] = {
        { 1u << 0,  "PENDING" }, { 1u << 1,  "RANGE" },   { 1u << 2,  "IMMUTABLE" },
        { 1u << 3,  "ENUM" },    { 1u << 4,  "BLOB" },    { 1u << 5,  "BITMASK" },
        { 1u << 6,  "OBJECT" },  { 1u << 7,  "SIGNED_RANGE" }, { 1u << 31, "ATOMIC" },
    };
    size_t i, used = 0;
    out[0] = '\0';
    for (i = 0; i < sizeof tbl / sizeof tbl[0]; i++) {
        if (f & tbl[i].bit) {
            int w = snprintf(out + used, n - used, "%s%s", used ? "|" : "", tbl[i].name);
            if (w < 0 || (size_t)w >= n - used) break;
            used += (size_t)w;
        }
    }
    if (!used) snprintf(out, n, "0");
}

int main(void)
{
    setvbuf(stdout, NULL, _IONBF, 0);

    printf("==== drmplaneprobe: plane 属性面（Weston 'Failed to find primary plane' 根因定位）====\n");
    printf("sizeof: plane_res=%zu plane=%zu obj_props=%zu get_property=%zu get_blob=%zu\n",
           sizeof(struct drm_mode_get_plane_res), sizeof(struct drm_mode_get_plane),
           sizeof(struct drm_mode_obj_get_properties), sizeof(struct drm_mode_get_property),
           sizeof(struct drm_mode_get_blob));

    /* ★ 探针自检：结构体必须与标准 uapi 一致。
     *   历史事故：探针与内核共用同一个错误布局（48B），两者自洽 ⇒ 探针变绿，
     *   却掩盖了内核的 ABI 回归。这里把标准尺寸写成运行期硬判据。 */
    printf("[PROBE_ABI] plane=%zu(ex 32) plane_res=%zu(ex 16) get_property=%zu(ex 64) obj_props=%zu(ex 32)\n",
           sizeof(struct drm_mode_get_plane), sizeof(struct drm_mode_get_plane_res),
           sizeof(struct drm_mode_get_property), sizeof(struct drm_mode_obj_get_properties));
    if (sizeof(struct drm_mode_get_plane) != 32 ||
        sizeof(struct drm_mode_get_plane_res) != 16 ||
        sizeof(struct drm_mode_get_property) != 64 ||
        sizeof(struct drm_mode_obj_get_properties) != 32) {
        printf("[PROBE_ABI] !! 本探针结构体尺寸偏离标准 uapi —— 探针结论不可用\n");
        printf("[PROBE_EXIT] 4 verdict=PROBE_ABI_MISMATCH\n");
        return 4;
    }
    printf("[PROBE_ABI] OK —— 与标准 uapi 一致（GETPLANE 请求值应为 0xC02064B6）\n");

    int fd = open(DEV0, O_RDWR | O_CLOEXEC);
    if (fd < 0) { printf("open(%s) FAILED errno=%d\n", DEV0, errno); return 1; }

    /* ---- 自证 ---- */
    {
        char nm[64] = {0}, dt[64] = {0}, ds[128] = {0};
        struct drm_version v; memset(&v, 0, sizeof v);
        v.name = nm; v.name_len = sizeof nm; v.date = dt; v.date_len = sizeof dt;
        v.desc = ds; v.desc_len = sizeof ds;
        int r = ioctl(fd, IOCTL_VERSION, &v);
        printf("[SELF] VERSION rc=%d errno=%d driver='%s' %d.%d.%d\n",
               r, errno, nm, v.version_major, v.version_minor, v.version_patchlevel);
        if (r != 0) {
            printf("[SELF] !! 探针自身编码有误，后续结论不可用\n");
            printf("[PROBE_EXIT] 2 verdict=SELF_FAIL\n");
            close(fd);
            return 2;
        }
    }

    /* ---- 汇总用计数器（关键步骤的返回码都必须折进 verdict）---- */
    int      pres_ok = 0;
    unsigned n_getplane_ok = 0, n_getplane_fail = 0;
    unsigned n_objprops_fail = 0, n_getprop_fail = 0;

    /* ---- CAP: ADDFB2_MODIFIERS（决定 Weston 走不走 modifiers 路径）---- */
    {
        struct drm_get_cap cap; memset(&cap, 0, sizeof cap);
        cap.capability = DRM_CAP_ADDFB2_MODIFIERS;
        errno = 0;
        int r = ioctl(fd, IOCTL_GET_CAP, &cap);
        printf("[CAP] ADDFB2_MODIFIERS rc=%d errno=%d value=%llu  %s\n",
               r, errno, (unsigned long long)cap.value,
               cap.value ? "=> Weston 会解析 IN_FORMATS blob" : "=> Weston 走 fallback(format_types)");
    }

    /* ---- GETPLANERESOURCES 两段式 ---- */
    uint32_t plane_ids[8] = {0};
    uint32_t n_planes = 0;
    {
        struct drm_mode_get_plane_res pr; memset(&pr, 0, sizeof pr);
        errno = 0;
        int r1 = ioctl(fd, IOCTL_GETPLANERES, &pr);
        printf("[PRES] 第一段 count_planes=%u rc=%d errno=%d\n", pr.count_planes, r1, errno);
        n_planes = pr.count_planes > 8 ? 8 : pr.count_planes;

        memset(&pr, 0, sizeof pr);
        pr.plane_id_ptr = (uint64_t)(uintptr_t)plane_ids;
        pr.count_planes = 8;
        errno = 0;
        int r2 = ioctl(fd, IOCTL_GETPLANERES, &pr);
        printf("[PRES] 第二段 rc=%d errno=%d count_planes=%u ids=", r2, errno, pr.count_planes);
        for (uint32_t i = 0; i < n_planes; i++) printf("%u ", plane_ids[i]);
        printf("\n");
        pres_ok = (r1 == 0 && r2 == 0);
        printf("[PRES] 两段式判定: %s\n", pres_ok ? "OK" : "FAIL（GETPLANERESOURCES 关键步骤失败）");
    }

    int found_type_attr = 0, type_is_primary = 0;
    uint32_t in_formats_blob = 0;

    for (uint32_t pi = 0; pi < n_planes; pi++) {
        uint32_t pid = plane_ids[pi];
        printf("\n---- plane[%u] id=%u ----\n", pi, pid);

        /* GETPLANE：crtc_id / possible_crtcs / formats */
        {
            uint32_t fmts[16] = {0};
            struct drm_mode_get_plane pl; memset(&pl, 0, sizeof pl);
            pl.plane_id = pid;
            pl.format_type_ptr = (uint64_t)(uintptr_t)fmts;
            pl.count_format_types = 16;
            errno = 0;
            int r = ioctl(fd, IOCTL_GETPLANE, &pl);
            printf("[PLANE] GETPLANE rc=%d errno=%d crtc_id=%u fb_id=%u possible_crtcs=0x%x gamma_size=%u count_formats=%u\n",
                   r, errno, pl.crtc_id, pl.fb_id, pl.possible_crtcs, pl.gamma_size, pl.count_format_types);
            if (r == 0) n_getplane_ok++; else n_getplane_fail++;
            printf("[PLANE] formats:");
            for (uint32_t i = 0; i < pl.count_format_types && i < 16; i++)
                printf(" 0x%08x('%c%c%c%c')", fmts[i],
                       (char)(fmts[i] & 0xff), (char)((fmts[i] >> 8) & 0xff),
                       (char)((fmts[i] >> 16) & 0xff), (char)((fmts[i] >> 24) & 0xff));
            printf("\n");
            /* Weston 的 drm_plane_is_available 判据：crtc_id != 0 且 == output crtc_id */
            printf("[PLANE] weston 判据复现: possible_crtcs&1=%u  crtc_id(非0)=%u\n",
                   pl.possible_crtcs & 1, pl.crtc_id);
        }

        /* OBJ_GETPROPERTIES 两段式 */
        uint32_t prop_ids[32] = {0};
        uint64_t prop_vals[32] = {0};
        uint32_t n_props = 0;
        {
            struct drm_mode_obj_get_properties og; memset(&og, 0, sizeof og);
            og.obj_id = pid; og.obj_type = DRM_MODE_OBJECT_PLANE;
            errno = 0;
            int r1 = ioctl(fd, IOCTL_OBJ_GETPROPS, &og);
            printf("[PLANE] OBJ_GETPROPERTIES 第一段 count_props=%u rc=%d errno=%d\n",
                   og.count_props, r1, errno);
            n_props = og.count_props > 32 ? 32 : og.count_props;

            memset(&og, 0, sizeof og);
            og.obj_id = pid; og.obj_type = DRM_MODE_OBJECT_PLANE;
            og.props_ptr = (uint64_t)(uintptr_t)prop_ids;
            og.prop_values_ptr = (uint64_t)(uintptr_t)prop_vals;
            og.count_props = 32;
            errno = 0;
            int r2 = ioctl(fd, IOCTL_OBJ_GETPROPS, &og);
            printf("[PLANE] OBJ_GETPROPERTIES 第二段 rc=%d errno=%d count_props=%u\n",
                   r2, errno, og.count_props);
            if (r1 != 0 || r2 != 0) n_objprops_fail++;
            n_props = og.count_props > 32 ? 32 : og.count_props;
        }

        /* ★ 核心：对每个 prop_id 解析名字（复现 Weston 的 drm_property_info_populate）*/
        printf("[PLANE] ---- 逐属性解析（Weston 就是靠 name 匹配 'type'）----\n");
        for (uint32_t i = 0; i < n_props; i++) {
            char flagstr[128];
            struct drm_mode_get_property gp; memset(&gp, 0, sizeof gp);
            gp.prop_id = prop_ids[i];
            errno = 0;
            int r = ioctl(fd, IOCTL_GETPROPERTY, &gp);
            decode_flags(gp.flags, flagstr, sizeof flagstr);
            if (r != 0) n_getprop_fail++;
            printf("[PROP] i=%2u prop_id=0x%03x val=%-4llu rc=%d errno=%d name=\"%s\" flags=0x%x[%s]\n",
                   i, prop_ids[i], (unsigned long long)prop_vals[i], r, errno,
                   r == 0 ? gp.name : "(解析失败)", gp.flags, flagstr);

            if (r == 0 && strcmp(gp.name, "type") == 0) {
                found_type_attr = 1;
                if (prop_vals[i] == DRM_PLANE_TYPE_PRIMARY) type_is_primary = 1;
            }
            if (r == 0 && strcmp(gp.name, "IN_FORMATS") == 0) {
                in_formats_blob = (uint32_t)prop_vals[i];
            }
        }
    }

    /* ---- IN_FORMATS blob 布局核对 ---- */
    if (in_formats_blob) {
        uint8_t buf[256] = {0};
        struct drm_mode_get_blob gb; memset(&gb, 0, sizeof gb);
        gb.blob_id = in_formats_blob;
        gb.length = sizeof buf;
        gb.data = (uint64_t)(uintptr_t)buf;
        errno = 0;
        int r = ioctl(fd, IOCTL_GETPROPBLOB, &gb);
        printf("\n[BLOB] IN_FORMATS blob_id=%u rc=%d errno=%d length=%u\n",
               in_formats_blob, r, errno, gb.length);
        if (r == 0) {
            /* mainline 头：version, flags, count_formats, formats_offset,
             *              count_modifiers, modifiers_offset（各 u32） */
            uint32_t *h = (uint32_t *)buf;
            printf("[BLOB] header: version=%u flags=%u count_formats=%u formats_off=%u count_mods=%u mods_off=%u\n",
                   h[0], h[1], h[2], h[3], h[4], h[5]);
            printf("[BLOB] formats 区: ");
            for (uint32_t i = 0; i < h[2] && (h[3] + i * 4 + 4) <= sizeof buf; i++) {
                uint32_t f;
                memcpy(&f, buf + h[3] + i * 4, 4);
                printf("0x%08x ", f);
            }
            printf("\n[BLOB] modifier 区前 24 字节（mainline: formats u64, modifier u64, offset u32, pad u32）:\n        ");
            for (uint32_t i = 0; i < 24 && (h[5] + i) < sizeof buf; i++)
                printf("%02x ", buf[h[5] + i]);
            printf("\n");

            /* ---- 精确复现 libdrm 的 drmModeFormatModifierBlobIterNext ----
             * Weston 用这个迭代器遍历 (format, modifier) 组合，再逐个
             * weston_drm_format_add_modifier()；后者对**重复的 modifier** 返回 -1
             * ⇒ drm_plane_populate_formats 返回负值 ⇒ plane 创建静默失败。
             * 这里把迭代器会产出的组合原样打印出来，用于判定"Weston 看到的到底是什么"。 */
            printf("[ITER] ---- 复现 libdrm 迭代器输出（fmt × modifier 组合）----\n");
            uint32_t count_f = h[2], off_f = h[3], count_m = h[4], off_m = h[5];
            for (uint32_t fi = 0; fi < count_f && fi < 8; fi++) {
                for (uint32_t mi = 0; mi < count_m && mi < 8; mi++) {
                    uint32_t  fmt_v = 0;
                    uint64_t  mod_mask = 0, mod_val = 0;
                    size_t base_f = off_f + fi * 4;
                    size_t base_m = off_m + mi * 24;
                    if (base_f + 4 > sizeof buf || base_m + 24 > sizeof buf) continue;
                    memcpy(&fmt_v, buf + base_f, 4);
                    memcpy(&mod_mask, buf + base_m, 8);          /* mainline: formats 位掩码 */
                    memcpy(&mod_val,  buf + base_m + 8, 8);      /* mainline: modifier */
                    printf("[ITER] fmt_idx=%u fmt=0x%08x('%c%c%c%c') | mod_idx=%u mask=0x%llx hit=%u mod=0x%llx\n",
                           fi, fmt_v, (char)(fmt_v & 0xff), (char)((fmt_v >> 8) & 0xff),
                           (char)((fmt_v >> 16) & 0xff), (char)((fmt_v >> 24) & 0xff),
                           mi, (unsigned long long)mod_mask,
                           (unsigned)((mod_mask >> fi) & 1ULL),
                           (unsigned long long)mod_val);
                }
            }
            printf("[ITER] 判定：若某个 (fmt) 的 mod 值重复出现，libdrm 侧会把它当作重复 modifier"
                   " ⇒ Weston 的 add_modifier 返回 -1 ⇒ plane 创建失败\n");
        }
    } else {
        printf("\n[BLOB] 未发现 IN_FORMATS 属性（Weston 会走 format_types fallback）\n");
    }

    /* ---- 汇总（关键 ioctl 的返回码必须折进 verdict，否则会产生假绿）---- */
    const char *verdict;
    if (!pres_ok)                       verdict = "PRES_FAIL";
    else if (!n_planes)                 verdict = "NO_PLANE";
    else if (n_getplane_fail > 0)       verdict = "GETPLANE_FAIL";
    else if (n_objprops_fail > 0)       verdict = "OBJPROPS_FAIL";
    else if (n_getprop_fail > 0)        verdict = "GETPROPERTY_FAIL";
    else if (!found_type_attr)          verdict = "TYPE_ATTR_MISSING";
    else if (!type_is_primary)          verdict = "TYPE_NOT_PRIMARY";
    else                                verdict = "PLANE_OK";

    printf("\n[PLANESUM] planes=%u pres_ok=%d getplane_ok=%u getplane_fail=%u objprops_fail=%u getprop_fail=%u type_attr=%s type_is_primary=%s in_formats_blob=%u verdict=%s\n",
           n_planes, pres_ok, n_getplane_ok, n_getplane_fail, n_objprops_fail, n_getprop_fail,
           found_type_attr ? "FOUND" : "MISSING",
           type_is_primary ? "YES" : "NO",
           in_formats_blob,
           verdict);

    int exit_code = 0;
    if (strcmp(verdict, "PLANE_OK") != 0 &&
        strcmp(verdict, "TYPE_ATTR_MISSING") != 0 &&
        strcmp(verdict, "TYPE_NOT_PRIMARY") != 0) {
        exit_code = 3;      /* 关键 ioctl 失败：接口有问题，调用方必须按失败处理 */
    }
    printf("[PROBE_EXIT] %d verdict=%s\n", exit_code, verdict);
    printf("==== drmplaneprobe done ====\n");
    close(fd);
    return exit_code;
}
