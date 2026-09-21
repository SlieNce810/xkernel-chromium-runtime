/*
 * evprobe.c — evdev 输入设备枚举与文化探针（判定哪个 eventN 是键盘/鼠标）
 *
 * 为什么需要它
 * ------------
 * `guest-bootstrap.sh` 伪造 udev 数据时**硬编码**假定：
 *     /run/udev/data/c13:1 → ID_INPUT_MOUSE
 *     /run/udev/data/c13:2 → ID_INPUT_KEYBOARD
 * 但次设备号由 guest 内 evdev 枚举顺序决定，而根因证据显示 guest 里
 * **只有 /dev/input/event0 (13:1) 一个 evdev 节点**、外加传统 mice 节点 (13:2)。
 * 映射写反的后果是**静默无输入**（libinput 找到设备但类型判错），
 * 直接丢决赛「键盘输入回显与鼠标点击跳转」4 分。
 *
 * 做法：对每个 /dev/input/eventN 取
 *   - EVIOCGNAME  设备名（"QEMU Virtio Keyboard" / "... Mouse" / "... Tablet"）
 *   - EVIOCGID    bustype/vendor/product/version
 *   - EVIOCGBIT(0)          支持的 event 类型（EV_KEY/EV_REL/EV_ABS/...）
 *   - EVIOCGBIT(EV_KEY)     key bitmap → 含 BTN_LEFT/BTN_RIGHT 判指针；含 KEY_A/KEY_SPACE 判键盘
 * 然后给出 KEYBOARD / MOUSE / TABLET / UNKNOWN 归类与建议的 udev 映射。
 *
 * 编译（宿主交叉编译，静态 musl）
 *     aarch64-linux-musl-gcc -static -O2 -Wall -Wextra -o evprobe evprobe.c
 * 运行（guest 内）
 *     /evprobe
 *
 * 输出约定：`[EV] ...` 明细，`[EVSUM] node=... class=...` 汇总，便于 grep。
 */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

/* ---- 直接定义 ioctl 与常量，避免依赖内核头文件 ---- */
#define IOC_NRBITS 8
#define IOC_TYPEBITS 8
#define IOC_SIZEBITS 14
#define IOC_DIRBITS 2
#define IOC_NRSHIFT 0
#define IOC_TYPESHIFT (IOC_NRSHIFT + IOC_NRBITS)
#define IOC_SIZESHIFT (IOC_TYPESHIFT + IOC_TYPEBITS)
#define IOC_DIRSHIFT (IOC_SIZESHIFT + IOC_SIZEBITS)
#define IOC_NONE 0U
#define IOC_WRITE 1U
#define IOC_READ 2U
#define IOC(dir, type, nr, size) \
    ((unsigned long)(((dir) << IOC_DIRSHIFT) | ((type) << IOC_TYPESHIFT) | \
                     ((nr) << IOC_NRSHIFT) | ((size) << IOC_SIZESHIFT)))
#define EVIOCGID _IOR('E', 0x02, struct input_id)
#define _IOR(type, nr, size) IOC(IOC_READ, (type), (nr), sizeof(size))
#define EVIOCGNAME(len) IOC(IOC_READ, 'E', 0x06, (len))
#define EVIOCGBIT(ev, len) IOC(IOC_READ, 'E', 0x20 + (ev), (len))

struct input_id {
    unsigned short bustype;
    unsigned short vendor;
    unsigned short product;
    unsigned short version;
};

#define EV_SYN 0x00
#define EV_KEY 0x01
#define EV_REL 0x02
#define EV_ABS 0x03
#define EV_MSC 0x04
#define EV_SW 0x05
#define EV_LED 0x11
#define EV_SND 0x12
#define EV_REP 0x14
#define EV_FF 0x15

#define EV_MAX 0x1f
#define KEY_MAX 0x2ff

#define BTN_MISC 0x100
#define BTN_MOUSE 0x110
#define BTN_LEFT 0x110
#define BTN_RIGHT 0x111
#define BTN_MIDDLE 0x112
#define BTN_JOYSTICK 0x120
#define BTN_TOUCH 0x14a

#define KEY_ESC 1
#define KEY_A 30
#define KEY_Z 44
#define KEY_SPACE 57
#define KEY_ENTER 28

static int bit_set(const unsigned char *bits, int n) {
    return (bits[n / 8] >> (n % 8)) & 1;
}

static const char *bustype_name(unsigned short t) {
    switch (t) {
        case 0x01: return "BUS_PCI";
        case 0x03: return "BUS_USB";
        case 0x06: return "BUS_VIRTUAL";
        case 0x10: return "BUS_ISAPNP";
        case 0x18: return "BUS_HOST";
        case 0x19: return "BUS_GSC";
        default: return "BUS_?";
    }
}

int main(void) {
    printf("=== evprobe: evdev 输入设备枚举 ===\n");

    int found = 0;
    int kb_minor = -1, ptr_minor = -1;

    for (int idx = 0; idx < 16; idx++) {
        char path[64];
        snprintf(path, sizeof(path), "/dev/input/event%d", idx);

        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0) {
            printf("[EV] %s open -> -1 errno=%d (%s)\n", path, errno, strerror(errno));
            if (idx == 0) {
                printf("[EV] 连 event0 都打不开，停止枚举\n");
                break;
            }
            continue;
        }
        found++;

        struct input_id id;
        memset(&id, 0, sizeof(id));
        int rc_gid = ioctl(fd, EVIOCGID, &id);

        char name[256];
        memset(name, 0, sizeof(name));
        int rc_name = ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name);

        unsigned char evbits[(EV_MAX + 8) / 8];
        memset(evbits, 0, sizeof(evbits));
        int rc_ev = ioctl(fd, EVIOCGBIT(0, sizeof(evbits)), evbits);

        unsigned char keybits[(KEY_MAX + 8) / 8];
        memset(keybits, 0, sizeof(keybits));
        int rc_key = ioctl(fd, EVIOCGBIT(EV_KEY, sizeof(keybits)), keybits);

        printf("[EV] %s\n", path);
        printf("[EV]   EVIOCGNAME  rc=%d name=\"%s\"\n", rc_name, rc_name >= 0 ? name : "");
        if (rc_gid >= 0) {
            printf("[EV]   EVIOCGID    bustype=%s(0x%04x) vendor=0x%04x product=0x%04x version=0x%04x\n",
                   bustype_name(id.bustype), id.bustype, id.vendor, id.product, id.version);
        } else {
            printf("[EV]   EVIOCGID    rc=%d errno=%d (%s)\n", rc_gid, errno, strerror(errno));
        }

        if (rc_ev >= 0) {
            printf("[EV]   EV  types:  SYN=%d KEY=%d REL=%d ABS=%d MSC=%d SW=%d REP=%d\n",
                   bit_set(evbits, EV_SYN), bit_set(evbits, EV_KEY), bit_set(evbits, EV_REL),
                   bit_set(evbits, EV_ABS), bit_set(evbits, EV_MSC), bit_set(evbits, EV_SW),
                   bit_set(evbits, EV_REP));
        } else {
            printf("[EV]   EVIOCGBIT(0)   rc=%d errno=%d (%s)\n", rc_ev, errno, strerror(errno));
        }

        int has_btn = 0, has_kbd_keys = 0, has_rel = bit_set(evbits, EV_REL), has_abs = bit_set(evbits, EV_ABS);
        if (rc_key >= 0) {
            for (int b = BTN_LEFT; b <= BTN_MIDDLE; b++) has_btn |= bit_set(keybits, b);
            has_btn |= bit_set(keybits, BTN_TOUCH);
            has_btn |= bit_set(keybits, BTN_MOUSE);
            has_btn |= bit_set(keybits, BTN_JOYSTICK);
            has_kbd_keys = bit_set(keybits, KEY_A) && bit_set(keybits, KEY_Z) &&
                           (bit_set(keybits, KEY_SPACE) || bit_set(keybits, KEY_ENTER));
            printf("[EV]   key bits:  BTN_LEFT=%d BTN_RIGHT=%d BTN_MIDDLE=%d BTN_TOUCH=%d KEY_A=%d KEY_Z=%d KEY_SPACE=%d\n",
                   bit_set(keybits, BTN_LEFT), bit_set(keybits, BTN_RIGHT),
                   bit_set(keybits, BTN_MIDDLE), bit_set(keybits, BTN_TOUCH),
                   bit_set(keybits, KEY_A), bit_set(keybits, KEY_Z), bit_set(keybits, KEY_SPACE));
        } else {
            printf("[EV]   EVIOCGBIT(EV_KEY) rc=%d errno=%d (%s)\n", rc_key, errno, strerror(errno));
        }

        const char *cls = "UNKNOWN";
        if (has_kbd_keys && !has_btn) {
            cls = "KEYBOARD";
            if (kb_minor < 0) kb_minor = idx + 1;
        } else if (has_btn || has_rel || has_abs) {
            cls = has_abs && !has_rel ? "TABLET/TOUCH" : "MOUSE";
            if (ptr_minor < 0) ptr_minor = idx + 1;
        }
        printf("[EVSUM] node=%s minor=%d class=%s (rel=%d abs=%d btn=%d kbdkeys=%d)\n",
               path, idx + 1, cls, has_rel, has_abs, has_btn, has_kbd_keys);

        close(fd);
    }

    printf("\n[EV] 共找到 %d 个 evdev 节点\n", found);
    printf("[EVMAP] 建议的 udev 伪造（可用次设备号）：keyboard=c13:%d  pointer=c13:%d\n",
           kb_minor > 0 ? kb_minor : -1, ptr_minor > 0 ? ptr_minor : -1);
    if (kb_minor < 0) printf("[EVMAP] 警告：未识别出键盘节点\n");
    if (ptr_minor < 0) printf("[EVMAP] 警告：未识别出指针节点（鼠标/平板）\n");
    return 0;
}
