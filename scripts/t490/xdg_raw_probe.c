// BUILD: static
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

static int fd = -1;
static uint32_t compositor_id, wm_id, surface_id, xdg_id, top_id, region_id;
static uint32_t next_id = 10;
static int top_configures, xdg_configures, display_errors;

static void out(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fflush(stderr);
}

static size_t put_u32(uint8_t *p, size_t off, uint32_t v) {
    memcpy(p + off, &v, 4);
    return off + 4;
}
static size_t put_i32(uint8_t *p, size_t off, int32_t v) {
    memcpy(p + off, &v, 4);
    return off + 4;
}
static size_t put_string(uint8_t *p, size_t off, const char *s) {
    size_t n = strlen(s) + 1;
    off = put_u32(p, off, (uint32_t)n);
    memcpy(p + off, s, n);
    off += n;
    while (off & 3) p[off++] = 0;
    return off;
}
static int send_req(uint32_t object, uint16_t opcode, const uint8_t *args, size_t arglen) {
    uint8_t buf[1024];
    if (arglen + 8 > sizeof(buf)) return -1;
    uint32_t h0 = object;
    uint32_t h1 = (uint32_t)(((arglen + 8) << 16) | opcode);
    memcpy(buf, &h0, 4); memcpy(buf + 4, &h1, 4);
    memcpy(buf + 8, args, arglen);
    size_t total = arglen + 8, done = 0;
    out("[XDGRAW] send object=%u opcode=%u len=%zu\n", object, opcode, total);
    while (done < total) {
        ssize_t n = send(fd, buf + done, total - done, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        done += (size_t)n;
    }
    return 0;
}
static int req0(uint32_t obj, uint16_t op) { return send_req(obj, op, NULL, 0); }
static int req_u32(uint32_t obj, uint16_t op, uint32_t a) {
    uint8_t b[4]; put_u32(b, 0, a); return send_req(obj, op, b, 4);
}
static int req_two_i32(uint32_t obj, uint16_t op, int32_t a, int32_t b) {
    uint8_t x[8]; put_i32(x, 0, a); put_i32(x, 4, b); return send_req(obj, op, x, 8);
}
static int connect_wayland(void) {
    const char *dir = getenv("XDG_RUNTIME_DIR");
    const char *name = getenv("WAYLAND_DISPLAY");
    if (!dir) dir = "/run/user/0";
    if (!name) name = "wayland-0";
    char path[256]; snprintf(path, sizeof(path), "%s/%s", dir, name);
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un sa; memset(&sa, 0, sizeof(sa)); sa.sun_family = AF_UNIX;
    strncpy(sa.sun_path, path, sizeof(sa.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) return -1;
    out("[XDGRAW] connected %s\n", path);
    return 0;
}
static int read_one(uint8_t *buf, size_t cap, size_t *used) {
    for (;;) {
        if (*used >= 8) {
            uint32_t h; memcpy(&h, buf + 4, 4);
            uint16_t len = (uint16_t)(h >> 16);
            if (len >= 8 && len <= cap && *used >= len) return (int)len;
        }
        ssize_t n = recv(fd, buf + *used, cap - *used, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        *used += (size_t)n;
    }
}
static void consume(size_t *used, size_t len, uint8_t *buf) {
    if (*used > len) memmove(buf, buf + len, *used - len);
    *used -= len;
}
static void parse_event(uint8_t *b, size_t len) {
    uint32_t obj, h; memcpy(&obj, b, 4); memcpy(&h, b + 4, 4);
    uint16_t op = (uint16_t)h;
    if (obj == 1 && op == 0) {
        display_errors++;
        uint32_t bad, code; memcpy(&bad, b + 8, 4); memcpy(&code, b + 12, 4);
        uint32_t slen = 0; if (len >= 20) memcpy(&slen, b + 16, 4);
        const char *msg = (len >= 20 && slen > 0) ? (const char *)(b + 20) : "";
        out("[XDGRAW] wl_display.error object=%u code=%u msg=%s\n", bad, code, msg);
    } else if (obj == 2 && op == 0) {
        uint32_t name, ver, slen; memcpy(&name,b+8,4); memcpy(&slen,b+12,4);
        const char *s = (const char *)(b + 16); size_t off = 16 + ((slen + 3) & ~3u);
        if (off + 4 <= len) memcpy(&ver, b + off, 4); else ver = 1;
        out("[XDGRAW] registry.global name=%u iface=%s version=%u\n", name, s, ver);
        if (!compositor_id && strcmp(s, "wl_compositor") == 0) compositor_id = next_id++;
        if (!wm_id && strcmp(s, "xdg_wm_base") == 0) wm_id = next_id++;
        if (compositor_id && strcmp(s, "wl_compositor") == 0) {
            uint8_t a[128]; size_t n=0; n=put_u32(a,n,name); n=put_string(a,n,s); n=put_u32(a,n,ver>4?4:ver); n=put_u32(a,n,compositor_id); send_req(2,0,a,n);
        } else if (wm_id && strcmp(s, "xdg_wm_base") == 0) {
            uint8_t a[128]; size_t n=0; n=put_u32(a,n,name); n=put_string(a,n,s); n=put_u32(a,n,ver>7?7:ver); n=put_u32(a,n,wm_id); send_req(2,0,a,n);
        }
    } else if (obj == 3 && op == 0) {
        out("[XDGRAW] sync.done\n");
    } else if (obj == xdg_id && op == 0) {
        uint32_t serial; memcpy(&serial,b+8,4); xdg_configures++; out("[XDGRAW] xdg_surface.configure serial=%u count=%d\n",serial,xdg_configures);
    } else if (obj == top_id && op == 0) {
        int32_t w,hv; memcpy(&w,b+8,4); memcpy(&hv,b+12,4); top_configures++; out("[XDGRAW] xdg_toplevel.configure %d %d count=%d\n",w,hv,top_configures);
    }
}

int main(void) {
    if (connect_wayland() < 0) { perror("connect"); return 2; }
    uint8_t a[16]; put_u32(a,0,2); send_req(1,1,a,4); /* get_registry */
    put_u32(a,0,3); send_req(1,0,a,4); /* sync */
    uint8_t buf[8192]; size_t used=0;
    for (int i=0; i<40 && (!compositor_id || !wm_id); ++i) { int n=read_one(buf,sizeof(buf),&used); if(n<0) return 3; parse_event(buf,(size_t)n); consume(&used,(size_t)n,buf); }
    if (!compositor_id || !wm_id) { out("[XDGRAW] missing globals compositor=%u wm=%u\n",compositor_id,wm_id); return 4; }
    surface_id=next_id++; xdg_id=next_id++; top_id=next_id++; region_id=next_id++;
    req_u32(compositor_id,0,surface_id); /* create_surface */
    req_u32(compositor_id,1,region_id); /* create_region */
    uint8_t r[16]; size_t rn=0; rn=put_i32(r,rn,0); rn=put_i32(r,rn,0); rn=put_i32(r,rn,1280); rn=put_i32(r,rn,800); send_req(region_id,1,r,rn);
    uint8_t q[4]; put_u32(q,0,region_id); send_req(surface_id,4,q,4); req0(region_id,0);
    uint8_t x[8]; size_t xn=0; xn=put_u32(x,xn,xdg_id); xn=put_u32(x,xn,surface_id); send_req(wm_id,2,x,xn); /* get_xdg_surface */
    req_u32(xdg_id,1,top_id); /* get_toplevel */
    uint8_t str[128]; size_t n=0; n=put_string(str,n,"xdg-sequence-probe"); send_req(top_id,3,str,n); n=0; n=put_string(str,n,"Untitled - Chromium"); send_req(top_id,2,str,n);
    req_two_i32(top_id,8,532,130); req_two_i32(top_id,7,0,0); req0(top_id,10); req_two_i32(top_id,8,532,130); req_two_i32(top_id,7,0,0);
    if (getenv("XDGPROBE_DAMAGE")) { uint8_t d[16]; size_t dn=0; dn=put_i32(d,dn,0); dn=put_i32(d,dn,0); dn=put_i32(d,dn,2147483647); dn=put_i32(d,dn,2147483647); send_req(surface_id,2,d,dn); out("[XDGRAW] damage sent\n"); }
    req0(surface_id,6); out("[XDGRAW] initial commit sent\n");
    uint8_t g[16]; size_t gn=0; gn=put_i32(g,gn,16); gn=put_i32(g,gn,10); gn=put_i32(g,gn,1248); gn=put_i32(g,gn,758); send_req(xdg_id,3,g,gn); req_u32(top_id,11,0);
    for (int i=0;i<5;i++) { int z=read_one(buf,sizeof(buf),&used); if(z<0) break; parse_event(buf,(size_t)z); consume(&used,(size_t)z,buf); }
    out("[XDGRAW_RESULT] xdg=%d top=%d errors=%d\n",xdg_configures,top_configures,display_errors);
    return (xdg_configures && top_configures && !display_errors) ? 0 : 1;
}
