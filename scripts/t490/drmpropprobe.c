/* drmpropprobe.c — 缺口 A 的 errno 级复现探针：KMS 属性面 ioctl 编号（uapi 契约）错位
 *
 * 为什么需要它
 *   report/28 §4.1 的结论此前是「读源码 + 对齐 Linux uapi 表」得到的推论：
 *     - mainline 0xA8 = DRM_IOCTL_MODE_GETPROPERTY（drm_mode_get_property，64 B）
 *       → x-kernel **完全缺失**
 *     - mainline 0xAA = DRM_IOCTL_MODE_GETPROPBLOB（drm_mode_get_blob，16 B）
 *       → x-kernel 把 **64 B 的属性结构**挂在这个编号上
 *     - mainline 未分配的 0xAC → x-kernel 把 blob 处理器挂在这里
 *   且 io/drmdevice/src/consts.rs:17 的 `iowr<T>()` 把 `size_of::<T>()` 编进 ioctl 号
 *   ⇒ 编号与结构大小**双重**错配 ⇒ 标准 Linux 客户端（libdrm/Weston/Xorg）发来的
 *     属性查询落不到任何 match 分支，最终命中分派表末尾的
 *         _ => Err(kvfs::VfsError::OperationNotSupported)
 *   ⇒ errno = 95 (ENOTSUP/EOPNOTSUPP)。
 *
 *   本探针把这个推论降成**可复核的 errno 事实**。判据的关键在于区分两类失败：
 *       errno == 95 (ENOTSUP)  → **没有命中分派表**（落到默认分支）＝ 编号对不上
 *       其他 errno（EINVAL/ENOENT/…）→ 命中了处理器，只是参数/对象无效 ＝ 编号对得上
 *   所以「95 vs 非 95」本身就是「编号是否正确」的判据，与属性内容无关。
 *
 * 探针设计：双向对照，一次开机同时证明两件事
 *   自证  VERSION@0x00（已知可通；若它也不通，说明探针自身 _IOWR 编码有误，
 *                      此时其余结果**不得**解读为内核缺陷）
 *   A 组  mainline 编号：GETPROPERTY@0xA8/64B、GETPROPBLOB@0xAA/16B
 *   B 组  x-kernel 现用编号：GETPROPERTY@0xAA/64B、GETPROPBLOB@0xAC/16B
 *         为什么要 B 组：它能证明「处理器**存在**、只是挂错编号」，
 *         而不是「内核根本没实现属性面」——两者是完全不同的缺口定性。
 *   链式  GETRESOURCES → GETCONNECTOR → OBJ_GETPROPERTIES → GETPROPERTY(真实 prop_id)
 *         这条链 = libdrm `drmModeGetConnector` + `drmModeObjectGetProperties` +
 *         `drmModeGetProperty` 的真实调用序列，也是 Weston DRM backend
 *         建立 output 时必经的路径。断在哪一环，就是用户态起不来的那一环。
 *
 * 修复前预期：A 组 NOT-DISPATCHED、B 组 HIT、链式断在 GETPROPERTY
 * 修复后预期：A 组 HIT、B 组 NOT-DISPATCHED（旧编号失效=修复生效的直接反证）、链式全通
 *
 * 编译：aarch64-linux-musl-gcc -static -O2 -o drmpropprobe drmpropprobe.c
 *       （t490_round.sh 会自动按此规格交叉编译并注入为 /drmpropprobe）
 *
 * 输出：判定行前缀 [PROP] / [CHAIN] / [PROPSUM]，供宿主侧 grep 汇总。
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <sys/ioctl.h>

#define DEV0 "/dev/dri/card0"

/* ---- Linux uapi 的 _IOC 编码（必须与内核 iowr 完全一致，否则一切免谈）---- */
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

#define DRM_TYPE        'd'                     /* 0x64 */
#define DRM_PROP_NAME_LEN 32
#define DRM_MODE_OBJECT_CONNECTOR 0xc0c0c0c0u   /* 与内核 consts.rs:73 一致 */

/* ---- mainline uapi 结构（大小必须与内核侧一致，否则编码对不上）---- */
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

struct drm_mode_get_connector {
    uint64_t encoders_ptr, modes_ptr, props_ptr, prop_values_ptr;
    uint32_t count_modes, count_props, count_encoders;
    uint32_t encoder_id, connector_id, connector_type, connector_type_id;
    uint32_t connection, mm_width, mm_height, subpixel, pad;
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

/* ---- 被测编号 ---- */
static const unsigned long IOCTL_VERSION          = IOWR(DRM_TYPE, 0x00, struct drm_version);
static const unsigned long IOCTL_GETRES           = IOWR(DRM_TYPE, 0xA0, struct drm_mode_card_res);
static const unsigned long IOCTL_GETCONNECTOR     = IOWR(DRM_TYPE, 0xA7, struct drm_mode_get_connector);
static const unsigned long IOCTL_OBJ_GETPROPS     = IOWR(DRM_TYPE, 0xB9, struct drm_mode_obj_get_properties);
/* A 组：mainline 语义编号（修复后应命中） */
static const unsigned long IOCTL_GETPROPERTY_MAIN = IOWR(DRM_TYPE, 0xA8, struct drm_mode_get_property);
static const unsigned long IOCTL_GETPROPBLOB_MAIN = IOWR(DRM_TYPE, 0xAA, struct drm_mode_get_blob);
/* B 组：x-kernel 修复前现用编号（修复后应变为 NOT-DISPATCHED） */
static const unsigned long IOCTL_GETPROPERTY_XK   = IOWR(DRM_TYPE, 0xAA, struct drm_mode_get_property);
static const unsigned long IOCTL_GETPROPBLOB_XK   = IOWR(DRM_TYPE, 0xAC, struct drm_mode_get_blob);

#define ENOTSUP_VAL 95          /* EOPNOTSUPP == ENOTSUP == 95 on Linux */

/* ---- 判定状态 ---- */
static int g_main_prop, g_main_blob, g_xk_prop, g_xk_blob;   /* 1=HIT, 0=NOT-DISPATCHED, -1=未测 */
static int g_chain_step;                                      /* 链式到达的最远步号 */

static const char *verdict_of(int rc, int err)
{
    if (rc == 0)     return "HIT(rc=0)";
    if (err != ENOTSUP_VAL) return "HIT(errno!=95)";
    return "NOT-DISPATCHED(errno=95)";
}
static int hit_of(int rc, int err) { return (rc == 0 || err != ENOTSUP_VAL) ? 1 : 0; }

/* 单点测试：发一次 ioctl，打印 rc/errno/判定 */
static int probe_one(int fd, unsigned long cmd, void *arg, const char *grp,
                     const char *desc, const char *detail)
{
    errno = 0;
    int r = ioctl(fd, cmd, arg);
    int e = errno;
    printf("[PROP] %-3s %-34s %-30s rc=%d errno=%d (%s) %s\n",
           grp, desc, detail, r, e, strerror(e), verdict_of(r, e));
    return hit_of(r, e);
}

/* 链式的一步：返回 0 成功，失败时打印 */
static int chain(int fd, unsigned long cmd, void *arg, int step, const char *what)
{
    errno = 0;
    int r = ioctl(fd, cmd, arg);
    int e = errno;
    printf("[CHAIN] step=%d %-24s rc=%d errno=%d (%s)\n", step, what, r, e, strerror(e));
    if (r == 0) { if (step > g_chain_step) g_chain_step = step; return 0; }
    return -1;
}

/* 把 DRM_MODE_PROP_* 位翻译成名字，让证据自解释（Weston 就是靠这些位判断属性类型） */
static void decode_prop_flags(uint32_t f, char *out, size_t n)
{
    static const struct { uint32_t bit; const char *name; } tbl[] = {
        { 1u << 0,  "PENDING" },
        { 1u << 1,  "RANGE" },
        { 1u << 2,  "IMMUTABLE" },
        { 1u << 3,  "ENUM" },
        { 1u << 4,  "BLOB" },
        { 1u << 5,  "BITMASK" },
        { 1u << 6,  "OBJECT" },
        { 1u << 7,  "SIGNED_RANGE" },
        { 1u << 31, "ATOMIC" },
    };
    size_t i, used = 0;
    out[0] = '\0';
    for (i = 0; i < sizeof tbl / sizeof tbl[0]; i++) {
        if (f & tbl[i].bit) {
            int w = snprintf(out + used, n - used, "%s%s",
                             used ? "|" : "", tbl[i].name);
            if (w < 0 || (size_t)w >= n - used) break;
            used += (size_t)w;
        }
    }
    if (!used) snprintf(out, n, "0");
}

int main(void)
{
    /* ★ 不缓冲：本探针的历史教训（见 autorun_probe.sh 注释）——
     *   stdout 若被重定向/接管道会转全缓冲，进程异常退出时输出全丢。
     *   置为无缓冲，保证每一行都实时落到串口与日志。 */
    setvbuf(stdout, NULL, _IONBF, 0);

    printf("==== drmpropprobe: KMS 属性面 uapi 编号对照 ====\n");
    printf("ioctl 编码自证（十六进制，应分别等于 libdrm 编译期常量）：\n");
    printf("  VERSION            = 0x%08lx\n", IOCTL_VERSION);
    printf("  GETRESOURCES       = 0x%08lx\n", IOCTL_GETRES);
    printf("  GETCONNECTOR       = 0x%08lx\n", IOCTL_GETCONNECTOR);
    printf("  OBJ_GETPROPERTIES  = 0x%08lx\n", IOCTL_OBJ_GETPROPS);
    printf("  GETPROPERTY mainln = 0x%08lx   (nr=0xA8 size=64)\n", IOCTL_GETPROPERTY_MAIN);
    printf("  GETPROPBLOB mainln = 0x%08lx   (nr=0xAA size=16)\n", IOCTL_GETPROPBLOB_MAIN);
    printf("  GETPROPERTY xk-old = 0x%08lx   (nr=0xAA size=64)\n", IOCTL_GETPROPERTY_XK);
    printf("  GETPROPBLOB xk-old = 0x%08lx   (nr=0xAC size=16)\n", IOCTL_GETPROPBLOB_XK);
    printf("sizeof: version=%zu card_res=%zu get_connector=%zu obj_get_props=%zu "
           "get_property=%zu get_blob=%zu\n",
           sizeof(struct drm_version), sizeof(struct drm_mode_card_res),
           sizeof(struct drm_mode_get_connector), sizeof(struct drm_mode_obj_get_properties),
           sizeof(struct drm_mode_get_property), sizeof(struct drm_mode_get_blob));

    errno = 0;
    int fd = open(DEV0, O_RDWR | O_CLOEXEC);
    printf("\nopen(%s, O_RDWR) -> %d errno=%d (%s)\n", DEV0, fd, errno, strerror(errno));
    if (fd < 0) return 1;

    /* ---------------- 自证：VERSION ---------------- */
    {
        char name[64] = {0}, date[64] = {0}, desc[128] = {0};
        struct drm_version v;
        memset(&v, 0, sizeof v);
        v.name = name; v.name_len = sizeof name;
        v.date = date; v.date_len = sizeof date;
        v.desc = desc; v.desc_len = sizeof desc;
        errno = 0;
        int r = ioctl(fd, IOCTL_VERSION, &v);
        printf("[SELF] VERSION -> rc=%d errno=%d (%s)", r, errno, strerror(errno));
        if (r == 0) printf("  driver='%s' %d.%d.%d", name,
                           v.version_major, v.version_minor, v.version_patchlevel);
        printf("\n");
        if (r != 0) {
            printf("[SELF] !! VERSION 不通 ⇒ 本探针的 _IOWR 编码与内核不匹配，\n");
            printf("[SELF] !! 下面所有 A/B 组结果**不能**解读为'内核编号错位'，先修探针。\n");
            close(fd);
            return 2;
        }
        /* VERSION 通 → 顺带取 GETRESOURCES 的资源计数，作为链式的起点准备 */
    }

    /* ---------------- A/B 组：编号对照（用零参数，只看分派是否命中） ---------------- */
    printf("\n---- A 组：mainline 编号（修复后应 HIT）----\n");
    {
        struct drm_mode_get_property gp; memset(&gp, 0, sizeof gp);
        gp.prop_id = 0;     /* 未知 id；命中分派表时会得到 ENOENT，未命中才是 95 */
        g_main_prop = probe_one(fd, IOCTL_GETPROPERTY_MAIN, &gp, "A1",
                                "GETPROPERTY@0xA8/64B", "(mainline 语义)");
        struct drm_mode_get_blob gb; memset(&gb, 0, sizeof gb);
        g_main_blob = probe_one(fd, IOCTL_GETPROPBLOB_MAIN, &gb, "A2",
                                "GETPROPBLOB@0xAA/16B", "(mainline 语义)");
    }
    printf("\n---- B 组：x-kernel 现用编号（证明处理器存在与否）----\n");
    {
        struct drm_mode_get_property gp; memset(&gp, 0, sizeof gp);
        g_xk_prop = probe_one(fd, IOCTL_GETPROPERTY_XK, &gp, "B1",
                              "GETPROPERTY@0xAA/64B", "(xk 现用编号)");
        struct drm_mode_get_blob gb; memset(&gb, 0, sizeof gb);
        g_xk_blob = probe_one(fd, IOCTL_GETPROPBLOB_XK, &gb, "B2",
                              "GETPROPBLOB@0xAC/16B", "(xk 现用编号)");
    }

    /* ---------------- 链式：libdrm 真实调用序列 ---------------- */
    printf("\n---- 链式：GETRESOURCES → GETCONNECTOR → OBJ_GETPROPERTIES → GETPROPERTY ----\n");
    {
        struct drm_mode_card_res cr;
        uint32_t conn_ids[8] = {0};
        uint32_t crtc_ids[8] = {0};
        uint32_t conn_id = 0, crtc_id = 0;
        int have_conn = 0;

        memset(&cr, 0, sizeof cr);
        if (chain(fd, IOCTL_GETRES, &cr, 1, "GETRESOURCES(count)") == 0) {
            printf("[CHAIN]      fbs=%u crtcs=%u conns=%u encs=%u\n",
                   cr.count_fbs, cr.count_crtcs, cr.count_connectors, cr.count_encoders);
            /* 第二次调用：携带数组指针，取真实 id（libdrm 就是两段式） */
            memset(&cr, 0, sizeof cr);
            cr.connector_id_ptr = (uint64_t)(uintptr_t)conn_ids;
            cr.crtc_id_ptr      = (uint64_t)(uintptr_t)crtc_ids;
            cr.count_connectors = 8;
            cr.count_crtcs      = 8;
            if (chain(fd, IOCTL_GETRES, &cr, 2, "GETRESOURCES(ids)") == 0) {
                conn_id = conn_ids[0];
                crtc_id = crtc_ids[0];
                printf("[CHAIN]      connector_id=%u crtc_id=%u\n", conn_id, crtc_id);
                have_conn = (conn_id != 0);
            }
        }

        if (have_conn) {
            struct drm_mode_get_connector gc;
            memset(&gc, 0, sizeof gc);
            gc.connector_id = conn_id;
            if (chain(fd, IOCTL_GETCONNECTOR, &gc, 3, "GETCONNECTOR") == 0) {
                printf("[CHAIN]      connection=%u encoder_id=%u count_props=%u count_modes=%u\n",
                       gc.connection, gc.encoder_id, gc.count_props, gc.count_modes);
            }

            /* OBJ_GETPROPERTIES：拿 connector 上的属性 id 列表（libdrm
             * drmModeObjectGetProperties 的等价调用） */
            uint32_t prop_ids[32] = {0};
            uint64_t prop_vals[32] = {0};
            struct drm_mode_obj_get_properties og;
            memset(&og, 0, sizeof og);
            og.obj_id = conn_id;
            og.obj_type = DRM_MODE_OBJECT_CONNECTOR;
            og.props_ptr = (uint64_t)(uintptr_t)prop_ids;
            og.prop_values_ptr = (uint64_t)(uintptr_t)prop_vals;
            og.count_props = 32;
            int have_props = 0;
            uint32_t first_prop = 0;
            if (chain(fd, IOCTL_OBJ_GETPROPS, &og, 4, "OBJ_GETPROPERTIES") == 0) {
                printf("[CHAIN]      count_props=%u prop_ids[0..3]=%u,%u,%u,%u\n",
                       og.count_props, prop_ids[0], prop_ids[1], prop_ids[2], prop_ids[3]);
                if (og.count_props > 0) { first_prop = prop_ids[0]; have_props = 1; }
            }

            if (have_props) {
                /* 用**真实 prop_id** 调属性查询 —— 这正是 Weston 建 output 的动作。
                 * 先试 mainline 编号（修复后应 rc=0 且 name 非空），再试 xk 旧编号对照。
                 *
                 * ⚠ 坑（本轮实测踩过）：drm_mode_get_property 的 name 是**内嵌数组**
                 *   （char name[32]），不是指针 —— 必须直接打印 gp.name。
                 *   若另开一个缓冲区去打印，会得到恒空的 name=''，看起来像"内核没填名字"。 */
                uint64_t vals[8];
                char flagstr[128];
                struct drm_mode_get_property gp;
                memset(&gp, 0, sizeof gp);
                gp.prop_id = first_prop;
                gp.values_ptr = (uint64_t)(uintptr_t)vals;
                gp.count_values = 8;
                errno = 0;
                int r = ioctl(fd, IOCTL_GETPROPERTY_MAIN, &gp);
                decode_prop_flags(gp.flags, flagstr, sizeof flagstr);
                printf("[CHAIN] step=5 GETPROPERTY@0xA8(prop_id=%u) rc=%d errno=%d (%s) "
                       "name='%s' flags=0x%x[%s] count_values=%u count_enum_blobs=%u\n",
                       first_prop, r, errno, strerror(errno),
                       gp.name, gp.flags, flagstr, gp.count_values, gp.count_enum_blobs);
                if (r == 0) g_chain_step = 5;

                struct drm_mode_get_property gp2;
                memset(&gp2, 0, sizeof gp2);
                gp2.prop_id = first_prop;
                errno = 0;
                int r2 = ioctl(fd, IOCTL_GETPROPERTY_XK, &gp2);
                printf("[CHAIN] step=5b GETPROPERTY@0xAA(prop_id=%u) rc=%d errno=%d (%s) "
                       "[对照：xk 旧编号]\n",
                       first_prop, r2, errno, strerror(errno));
            }
        }
    }

    /* ---------------- 汇总判定 ---------------- */
    printf("\n");
    const char *verdict;
    if (g_main_prop < 0)                    verdict = "UNTESTED";
    else if (g_main_prop && g_main_blob)    verdict = "FIXED";
    else                                    verdict = "BROKEN";
    printf("[PROPSUM] mainline_property=%s mainline_blob=%s xkernel_property=%s "
           "xkernel_blob=%s chain_max_step=%d verdict=%s\n",
           g_main_prop == 1 ? "HIT" : (g_main_prop == 0 ? "NOT-DISPATCHED" : "NA"),
           g_main_blob == 1 ? "HIT" : (g_main_blob == 0 ? "NOT-DISPATCHED" : "NA"),
           g_xk_prop   == 1 ? "HIT" : (g_xk_prop   == 0 ? "NOT-DISPATCHED" : "NA"),
           g_xk_blob   == 1 ? "HIT" : (g_xk_blob   == 0 ? "NOT-DISPATCHED" : "NA"),
           g_chain_step, verdict);

    close(fd);
    printf("==== drmpropprobe done ====\n");
    return 0;
}
