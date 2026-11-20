#!/bin/sh
# Chromium 默认多进程诊断轮（T1 入口对齐 + T2 生命周期账本）
#
# 本入口刻意不使用 --single-process / --no-zygote：它要在**默认 zygote** 路线上
# 回答 renderer 门禁。任何拿单进程结果解释本路线的说法都不成立。
#
# ── 2026-11-02 T1：入口对齐真实环境（与 autorun_single_initial.sh 同一套）
#   1. 补 write_input_seat_metadata()。x-kernel 的 virtio-input 只有设备节点，
#      uevent 里没有 ID_INPUT / ID_SEAT；缺这两项 libinput 会静默丢弃设备，
#      Weston 随即以"无输入"退出。此前正是用 --continue-without-input 把这种
#      失败掩盖成了"Weston 起来了"。
#   2. 正式轮**移除** --continue-without-input；只有 MP_WESTON_CONTINUE=1 的
#      A/B 诊断轮才保留。默认 0 == "没有真实输入就不许起 Weston"，这是门禁。
#   3. 早退路径 sync。trap cleanup 里补 sync：否则 Weston/seatd 失败后 guest
#      日志留在 page cache，宿主只能从基础镜像里捞到上一轮的旧文件。
#
# ── 2026-11-02 T2：生命周期账本
#   - 每秒一次 /proc 闭包扫描（browser → zygote → renderer 的传递子进程），
#     记录 pid/ppid/kind/state/threads/start_ms，并对 pid 集合做差集输出
#     created / exited 事件；
#   - 每 SAMPLE_SECONDS 补一次 wchan 与 syscall：直接说明进程卡在 wait/fork、
#     read、poll，还是已在跑用户态 —— 比"ps 里有没有 --type=renderer"硬得多；
#   - 生命周期 syscall 用**窄过滤** strace（clone/clone3/execve/execveat/
#     exit_group/wait4/prctl/set_tid_address）。全量 -ff 在 TCG 下既拖慢整轮，
#     又把关键行淹掉；
#   - Chromium 侧只导出**原始回执**（关键字计数 + 首末行）。日志时间戳前缀
#     不做换算，没有真实回执就不输出 MP_*_EPOCH_MS 指标。
#
# 已知陷阱（都已在本脚本里处理）：
#   - 带 strace 时 `$!` 是 strace 的 pid，不是 Chromium 的。直接拿它当
#     browser_pid 会让"存活判定"和 kill 都作用在 tracer 上（tracee 变孤儿），
#     所以启动后会从 tracer 的子进程里解析真实 BROWSER_PID。
#   - 宿主 sed 只在注入时替换占位符（双下划线包住的标记名）；guest 是 busybox sh，
#     脚本里不得调用 sed。注释里也不要写出占位符的字面形态 —— 宿主注入后的
#     "无残留" 硬校验会 grep 整个文件，注释同样会命中并让整轮直接失败。

set -u

LOG=/root/mp-diag.log
LEDGER_HEAD=/root/mp-ledger.head
LIFE=/root/mp-life.log
WLOG=/root/mp-weston.log
CHROME_LOG=/root/mp-chromium.log
SEATD_LOG=/root/mp-seatd.log
UDEVD_LOG=/root/mp-udevd.log
EVENT_LOG=/root/multiprocess-events.jsonl
PROCESS_EVENTS_SEEN=/tmp/mp-process-events-seen
PROCESS_FAMILY_SEEN=/tmp/mp-process-family-seen
RUNTIME_DIR=/run/user/0
PAGE_URL=${PAGE_URL:-file:///usr/share/html-test/index.html}
# 以下四个由 t490_round.sh 在注入时烘焙；宿主环境变量本身不跨 QEMU 边界。
TRACE_MODE=__MP_TRACE__
TRACE_SNAPSHOT_NEXT_MS=120000
EXTRA_FLAGS="__EXTRA_FLAGS__"
PERF_TRACE_RUN_ID="__PROFILE_ID__"
PERF_TRACE_FILE=""
for perf_trace_arg in $EXTRA_FLAGS; do
    case "$perf_trace_arg" in
        --trace-startup-file=*) PERF_TRACE_FILE=${perf_trace_arg#*=} ;;
    esac
done
PERF_TRACE_EXPORTED=0
GL_MODE=__MP_GL__
NET_MODE=__MP_NET__
LEDGER_MODE=__MP_LEDGER__
MP_FAMILY_DIAGNOSTICS=__MP_FAMILY_DIAGNOSTICS__
FAMILY_WATCHDOG_INTERVAL=__MP_FAMILY_WATCHDOG_INTERVAL__
WESTON_CONTINUE_WITHOUT_INPUT=__MP_WESTON_CONTINUE__
CHROME_PROFILE=/root/mp-chromium-profile
MAX_SECONDS=${MP_MAX_SECONDS:-__MP_MAX_SECONDS__}
SAMPLE_SECONDS=${MP_SAMPLE_SECONDS:-5}
HOLD_SECONDS=${MP_HOLD_SECONDS:-__MP_HOLD_SECONDS__}
LEDGER_MAX_PIDS=${MP_LEDGER_MAX_PIDS:-40}

: > "$LOG"
: > "$LEDGER_HEAD"
: > "$CHROME_LOG"
: > "$LIFE"
: > "$EVENT_LOG"
: > "$PROCESS_EVENTS_SEEN"
: > "$PROCESS_FAMILY_SEEN"

log() {
    line="[mpdiag] $*"
    echo "$line" >> "$LOG"
    echo "$line" > /dev/console 2>/dev/null || true
}

perf_trace_export_once() {
    [ "$PERF_TRACE_EXPORTED" = "0" ] || return 0
    [ -n "$PERF_TRACE_FILE" ] && [ -s "$PERF_TRACE_FILE" ] || return 0
    grep -Fq "Completed startup tracing to $PERF_TRACE_FILE" "$CHROME_LOG" 2>/dev/null || return 0

    if ! command -v gzip >/dev/null 2>&1 || ! command -v base64 >/dev/null 2>&1 \
            || ! command -v fold >/dev/null 2>&1 || ! command -v tr >/dev/null 2>&1; then
        log "MP_PERF_TRACE_EXPORT_UNAVAILABLE gzip=$(command -v gzip 2>/dev/null || echo missing) base64=$(command -v base64 2>/dev/null || echo missing) fold=$(command -v fold 2>/dev/null || echo missing) tr=$(command -v tr 2>/dev/null || echo missing)"
        return 1
    fi

    trace_gzip_file="/tmp/mp-perf-trace-export-$$.gz"
    trace_base64_file="/tmp/mp-perf-trace-export-$$.base64"
    trace_flat_file="/tmp/mp-perf-trace-export-$$.flat"
    trace_b64_file="/tmp/mp-perf-trace-export-$$.b64"
    rm -f "$trace_gzip_file" "$trace_base64_file" "$trace_flat_file" "$trace_b64_file"

    trace_bytes_before=$(wc -c < "$PERF_TRACE_FILE" 2>/dev/null | tr -d '[:space:]' || echo 0)
    trace_sha_before=$(sha256sum "$PERF_TRACE_FILE" 2>/dev/null | awk '{print $1}')
    sleep 1
    trace_bytes=$(wc -c < "$PERF_TRACE_FILE" 2>/dev/null | tr -d '[:space:]' || echo 0)
    trace_sha=$(sha256sum "$PERF_TRACE_FILE" 2>/dev/null | awk '{print $1}')
    if [ "$trace_bytes_before" != "$trace_bytes" ] || [ "$trace_sha_before" != "$trace_sha" ]; then
        log "MP_PERF_TRACE_EXPORT_WAIT_FILE_STABLE run_id=$PERF_TRACE_RUN_ID before_bytes=$trace_bytes_before after_bytes=$trace_bytes"
        return 0
    fi

    if ! gzip -c "$PERF_TRACE_FILE" > "$trace_gzip_file" 2>/dev/null; then
        rm -f "$trace_gzip_file"
        log "MP_PERF_TRACE_EXPORT_GZIP_FAIL run_id=$PERF_TRACE_RUN_ID"
        return 1
    fi
    if ! gzip -t "$trace_gzip_file" 2>/dev/null; then
        rm -f "$trace_gzip_file"
        log "MP_PERF_TRACE_EXPORT_GZIP_TEST_FAIL run_id=$PERF_TRACE_RUN_ID"
        return 1
    fi
    trace_bytes_after=$(wc -c < "$PERF_TRACE_FILE" 2>/dev/null | tr -d '[:space:]' || echo 0)
    trace_sha_after=$(sha256sum "$PERF_TRACE_FILE" 2>/dev/null | awk '{print $1}')
    if [ "$trace_bytes_after" != "$trace_bytes" ] || [ "$trace_sha_after" != "$trace_sha" ]; then
        rm -f "$trace_gzip_file"
        log "MP_PERF_TRACE_EXPORT_WAIT_FILE_STABLE run_id=$PERF_TRACE_RUN_ID before_gzip_bytes=$trace_bytes after_gzip_bytes=$trace_bytes_after"
        return 0
    fi

    if ! base64 < "$trace_gzip_file" > "$trace_base64_file" 2>/dev/null; then
        rm -f "$trace_gzip_file" "$trace_base64_file"
        log "MP_PERF_TRACE_EXPORT_BASE64_FAIL run_id=$PERF_TRACE_RUN_ID"
        return 1
    fi
    if ! tr -d '\n' < "$trace_base64_file" > "$trace_flat_file" 2>/dev/null; then
        rm -f "$trace_gzip_file" "$trace_base64_file" "$trace_flat_file"
        log "MP_PERF_TRACE_EXPORT_FOLD_FAIL run_id=$PERF_TRACE_RUN_ID stage=tr"
        return 1
    fi
    if ! fold -w 256 < "$trace_flat_file" > "$trace_b64_file" 2>/dev/null; then
        rm -f "$trace_gzip_file" "$trace_base64_file" "$trace_flat_file" "$trace_b64_file"
        log "MP_PERF_TRACE_EXPORT_FOLD_FAIL run_id=$PERF_TRACE_RUN_ID stage=fold"
        return 1
    fi

    trace_gzip_bytes=$(wc -c < "$trace_gzip_file" 2>/dev/null | tr -d '[:space:]' || echo 0)
    trace_gzip_sha=$(sha256sum "$trace_gzip_file" 2>/dev/null | awk '{print $1}')
    trace_chunks=$(wc -l < "$trace_b64_file" 2>/dev/null | tr -d '[:space:]' || echo 0)
    [ "$trace_chunks" -gt 0 ] || {
        rm -f "$trace_gzip_file" "$trace_base64_file" "$trace_flat_file" "$trace_b64_file"
        log "MP_PERF_TRACE_EXPORT_EMPTY run_id=$PERF_TRACE_RUN_ID"
        return 1
    }

    log "MP_PERF_TRACE_EXPORT_BEGIN run_id=$PERF_TRACE_RUN_ID bytes=$trace_bytes chunks=$trace_chunks sha256=$trace_sha gzip_bytes=$trace_gzip_bytes gzip_sha256=$trace_gzip_sha"
    trace_seq=0
    while IFS= read -r trace_chunk; do
        trace_chunk_length=${#trace_chunk}
        printf '[mpdiag] MP_PERF_TRACE_DATA run_id=%s seq=%s len=%s %s\n' \
            "$PERF_TRACE_RUN_ID" "$trace_seq" "$trace_chunk_length" "$trace_chunk" > /dev/console 2>/dev/null || true
        trace_seq=$((trace_seq + 1))
    done < "$trace_b64_file"
    rm -f "$trace_gzip_file" "$trace_base64_file" "$trace_flat_file" "$trace_b64_file"
    if [ "$trace_seq" -ne "$trace_chunks" ]; then
        log "MP_PERF_TRACE_EXPORT_COUNT_MISMATCH run_id=$PERF_TRACE_RUN_ID expected=$trace_chunks emitted=$trace_seq"
        return 1
    fi
    log "MP_PERF_TRACE_EXPORT_END run_id=$PERF_TRACE_RUN_ID encoding=gzip+base64 chunks=$trace_chunks"
    PERF_TRACE_EXPORTED=1
}

epoch_ms() {
    value=$(date +%s%3N 2>/dev/null || true)
    case "$value" in
        ''|*[!0-9]*)
            seconds=$(date +%s 2>/dev/null || echo 0)
            echo "$((seconds * 1000))"
            ;;
        *) echo "$value" ;;
    esac
}

mono_ms() {
    awk 'NR == 1 { printf "%.0f\n", $1 * 1000 }' /proc/uptime 2>/dev/null || echo 0
}

process_pid_from_line() {
    set -f
    set -- $1
    PROCESS_PID_FIELD=${1:-}
    set +f
}

STABILITY_FAMILY_LINE=""
STABILITY_FAMILY_COUNT=0
stability_family_add() {
    STABILITY_MEMBER_PID=$1
    STABILITY_MEMBER_KIND=$2
    [ -d "/proc/$STABILITY_MEMBER_PID" ] || return 0
    set -- $(proc_state_threads "$STABILITY_MEMBER_PID")
    STABILITY_MEMBER_STATE=$1
    STABILITY_MEMBER_THREADS=$2
    case "$STABILITY_MEMBER_THREADS" in
        ''|*[!0-9]*) STABILITY_MEMBER_THREADS=1 ;;
    esac
    STABILITY_FAMILY_COUNT=$((STABILITY_FAMILY_COUNT + 1))
    STABILITY_FAMILY_LINE="$STABILITY_FAMILY_LINE $STABILITY_MEMBER_PID:$STABILITY_MEMBER_KIND/$STABILITY_MEMBER_STATE/$STABILITY_MEMBER_THREADS"
}

MP_EVENT_SEQ=0
emit_process_event() {
    event_role=$1
    event_name=$2
    event_pid=$3
    event_ppid=$4
    event_source=${5:-guest-launcher}
    event_ms=$(mono_ms)
    event_time=$(awk -v ms="$event_ms" -v seq="$MP_EVENT_SEQ" \
        'BEGIN { printf "%.6f", (ms + seq * 0.001) / 1000 }')
    MP_EVENT_SEQ=$((MP_EVENT_SEQ + 1))
    event_json=$(printf '{"timestamp_monotonic":%s,"process_role":"%s","pid":%s,"ppid":%s,"navigation_id":0,"frame_tree_node_id":0,"document_id":"","mojo_endpoint_or_pipe_id":"","shared_object_id_or_file_object_id":"","event":"%s","status":"observed","error":"","observation_source":"%s"}' \
        "$event_time" "$event_role" "$event_pid" "$event_ppid" "$event_name" "$event_source")
    printf '%s\n' "$event_json" >> "$EVENT_LOG"
    event_start_ms=$(proc_start_ms "$event_pid")
    printf '%s %s %s %s\n' "$event_role" "$event_pid" "$event_ppid" "$event_start_ms" \
        >> "$PROCESS_FAMILY_SEEN"
    echo "MP_EVENT $event_json" > /dev/console 2>/dev/null || true
    log "MP_PROCESS_OBSERVED role=$event_role event=$event_name pid=$event_pid ppid=$event_ppid"
}

observe_process_tree() {
    dump_ppid_table
    STABILITY_FAMILY_LINE=""
    STABILITY_FAMILY_COUNT=0
    stability_family_add "$BROWSER_PID" browser
    if ! grep -qxF "browser:$BROWSER_PID" "$PROCESS_EVENTS_SEEN" 2>/dev/null; then
        browser_ppid=$(snapshot_ppid "$BROWSER_PID")
        emit_process_event browser browser-start "$BROWSER_PID" "$browser_ppid" guest-launcher
        echo "browser:$BROWSER_PID" >> "$PROCESS_EVENTS_SEEN"
    fi

    PROCESS_LIST=/tmp/mp-process-snapshot.txt
    ZYGOTE_LIST=/tmp/mp-observed-zygotes.txt
    # Save ps before filtering. Do not put a --type token in an awk/grep
    # command line: ps can see the scanner itself and falsely match it.
    ps 2>/dev/null > "$PROCESS_LIST"
    : > "$ZYGOTE_LIST"
    while IFS= read -r process_line; do
        process_pid_from_line "$process_line"
        process_pid=$PROCESS_PID_FIELD
        case "$process_pid" in ''|*[!0-9]*) continue ;; esac
        case "$process_line" in *"--type=zygote"*) ;; *) continue ;; esac
        zygote_pid=$process_pid
        zygote_ppid=$(snapshot_ppid "$zygote_pid")
        echo "$zygote_pid" >> "$ZYGOTE_LIST"
        if [ "$zygote_ppid" = "$BROWSER_PID" ]; then
            stability_family_add "$zygote_pid" browser_child
        fi
        if ! grep -qxF "zygote:$zygote_pid" "$PROCESS_EVENTS_SEEN" 2>/dev/null; then
            emit_process_event zygote zygote-observed "$zygote_pid" "$zygote_ppid" guest-ps-snapshot
            echo "zygote:$zygote_pid" >> "$PROCESS_EVENTS_SEEN"
            if [ "$zygote_ppid" != "$BROWSER_PID" ]; then
                log "MP_ZYGOTE_PARENT_NOT_BROWSER zygote_pid=$zygote_pid ppid=$zygote_ppid browser_pid=$BROWSER_PID"
            fi
        fi
    done < "$PROCESS_LIST"

    while read -r renderer_pid renderer_ppid; do
        case "$renderer_pid" in ''|*[!0-9]*) continue ;; esac
        case "$renderer_ppid" in ''|*[!0-9]*) continue ;; esac
        renderer_parent_is_zygote=0
        while IFS= read -r zygote_pid; do
            [ "$renderer_ppid" = "$zygote_pid" ] && renderer_parent_is_zygote=1
        done < "$ZYGOTE_LIST"
        [ "$renderer_parent_is_zygote" = "1" ] || continue
        stability_family_add "$renderer_pid" zygote_child
        if ! grep -qxF "renderer:$renderer_pid" "$PROCESS_EVENTS_SEEN" 2>/dev/null; then
            emit_process_event renderer renderer-observed "$renderer_pid" "$renderer_ppid" guest-ps-snapshot
            echo "renderer:$renderer_pid" >> "$PROCESS_EVENTS_SEEN"
        fi
    done < /tmp/mp-ppid.txt
    if [ "$LEDGER_MODE" = "0" ]; then
        family_label=$(mono_ms)
        echo "[mpdiag] MP_FAMILY label=$family_label n=$STABILITY_FAMILY_COUNT$STABILITY_FAMILY_LINE" \
            > /dev/console 2>/dev/null || true
    fi
}

# 阶段打点：只在 PHASE_DEBUG=1 时输出，用来把"循环停了"定位到具体语句。
# 串口是唯一落地通道，所以打点必须走 /dev/console，而不是写文件。
phase() {
    [ "${PHASE_DEBUG:-0}" = "1" ] || return 0
    echo "[mpdiag] MP_PHASE p=$1 tick=${2:-?}" > /dev/console 2>/dev/null
}

mark() {
    key="$1"
    value="$2"
    echo "MP_${key}=${value}" >> "$LOG"
    echo "[mpdiag] MP_${key}=${value}" > /dev/console 2>/dev/null || true
}

# ---------------------------------------------------------------- 输入 seat 元数据
# 只补 uevent 缺的那几项，设备节点和事件流仍是真实的 virtio-input：
# 不造假设备、不改 libinput 行为， Weston 拿到的 evdev 与 QEMU 注入的是同一路。
write_input_seat_metadata() {
    for dev in /dev/input/event*; do
        [ -c "$dev" ] || continue
        set -- $(ls -l "$dev" 2>/dev/null | awk '{gsub(",", "", $5); print $5, $6}')
        [ $# -eq 2 ] || continue
        major=$1
        minor=$2
        name=$(cat "/sys/class/input/${dev##*/}/device/name" 2>/dev/null || echo unknown)
        data="/run/udev/data/c${major}:${minor}"
        {
            echo "E:ID_INPUT=1"
            echo "E:ID_SEAT=seat0"
            echo "E:ID_SERIAL=x-kernel-virtio-input"
            case "$name" in
                *[Kk]eyboard*) echo "E:ID_INPUT_KEYBOARD=1" ;;
                *[Mm]ouse*)    echo "E:ID_INPUT_MOUSE=1" ;;
            esac
        } > "$data"
        log "INPUT_SEAT dev=$dev major=$major minor=$minor name=$name data=$data"
    done
}

# ---------------------------------------------------------------- 账本原语
# /proc/<pid>/stat 的 comm 可能含空格，字段号会错位，所以 starttime（第 22 字段）
# 用 ")" 之后切分的方式取，而不是直接 awk 第 22 列。
proc_start_ms() {
    pid=$1
    awk '{ n = split($0, a, ") "); m = split(a[2], b, " "); if (m >= 20) printf "%.0f\n", b[20] * 10 }' \
        "/proc/$pid/stat" 2>/dev/null || echo 0
}

# kind 判定：优先 --type=，退回 comm。fork 未 exec 的子进程 cmdline 仍是 zygote
# 的 argv，会在这里被判成 zygote —— 这不是 bug，是 procfs 的既有行为，
# 由 MP_RENDERER_CMDLINE_IS_ZYGOTE 标记显式登记，真伪交给 strace 的 execve 回执。
proc_kind() {
    # 只用 stat（comm/ppid），**绝不读 cmdline/status**：
    # 2026-11-02 对照实验：普通子进程（sleep）的 status/cmdline 读取 rc=0；
    # 但 Chromium 的 zygote 子进程上，读 status/cmdline 会把读方永久挂住
    # （连读三轮都在此处停住，阶段打点 scan_closure_end 之后消失）。
    # 所以类型只能按父子关系推断，--type= 从 cmdline 取值这条路在本内核上不可用。
    pid=$1
    ppid=$(proc_ppid "$pid")
    if [ "$pid" = "${BROWSER_PID:-}" ]; then
        echo browser
    elif [ "$ppid" = "${BROWSER_PID:-}" ]; then
        echo browser_child
    elif [ "$(proc_ppid "$ppid")" = "${BROWSER_PID:-}" ]; then
        echo zygote_child
    else
        echo other
    fi
}

# ppid 也从 stat 取（字段 4）：本 guest 上读 /proc/<pid>/status 会在子进程刚出现时
# 阻塞住读方（2026-11-02 阶段打点定位：scan_dump_begin 之后无输出），
# 因此账本全程不碰 status，只用 stat。
proc_ppid() {
    awk '{ n = split($0, a, ") "); m = split(a[2], b, " "); if (m >= 2) print b[2]; else print 0 }' \
        "/proc/$1/stat" 2>/dev/null || echo 0
}

proc_state_threads() {
    # 先走 /proc/<pid>/stat：字段 3 = state，字段 20 = num_threads。
    # 之所以不优先用 status：本 guest 的 status 里 State/Threads 可能缺字段，
    # 上一轮就出现过 state=? threads=?（不是进程异常，是字段没实现）。
    set -- $(awk '{ n = split($0, a, ") "); m = split(a[2], b, " "); if (m >= 18) printf "%s %s\n", b[1], b[18] }' \
        "/proc/$1/stat" 2>/dev/null)
    if [ -n "${1:-}" ] && [ -n "${2:-}" ]; then
        echo "$1 $2"
        return
    fi
    # 没有 status 回退：本内核上读 Chromium 子进程的 status 会挂死读方。
    echo "? ?"
}

# 一次性把 pid→ppid 全表抓出来（单个 awk 进程，避免每个 pid 一次 fork）
# 全表只读 stat，不读 status：stage 打点证明 status 全表扫描会在子进程出现时挂住。
dump_ppid_table() {
    awk '{ n = split($0, a, ") "); m = split(a[2], b, " "); if (m >= 2) { sub("/stat","",FILENAME); sub("/proc/","",FILENAME); print FILENAME, b[2] } }' \
        /proc/[0-9]*/stat 2>/dev/null > /tmp/mp-ppid.txt
}

snapshot_ppid() {
    observed_ppid=$(awk -v wanted="$1" '$1 == wanted { print $2; found = 1; exit } END { if (!found) print 0 }' \
        /tmp/mp-ppid.txt 2>/dev/null)
    case "$observed_ppid" in
        ''|0) observed_ppid=$(proc_ppid "$1") ;;
    esac
    case "$observed_ppid" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$observed_ppid" ;;
    esac
}

# 闭包 = chrome 家族（browser 的传递子进程）∪ 上一轮已知且仍存活的 pid。
# 后者是为了不把"zygote 退出后 renderer 被 init 收养"误报成 exited。
family_closure() {
    awk -v root="$BROWSER_PID" '
        { pid[$1] = 1; par[$1] = $2 }
        END {
            if (root == "") exit
            fam[root] = 1
            changed = 1
            while (changed) {
                changed = 0
                for (p in par) {
                    if (!(p in fam) && (par[p] in fam)) { fam[p] = 1; changed = 1 }
                }
            }
            for (p in fam) print p
        }' /tmp/mp-ppid.txt > /tmp/mp-family.new
    if [ -s /tmp/mp-family.prev ]; then
        while read -r old; do
            [ -n "$old" ] || continue
            [ -d "/proc/$old" ] || continue
            grep -qxF "$old" /tmp/mp-family.new || echo "$old" >> /tmp/mp-family.new
        done < /tmp/mp-family.prev
    fi
    sort -n /tmp/mp-family.new > /tmp/mp-family.cur
    cp -f /tmp/mp-family.cur /tmp/mp-family.prev 2>/dev/null || true
}

# 每秒一次：created / exited 事件 + 每个家族进程的一行状态
ledger_scan() {
    label=$1
    # ⚠️ 必须先抓下来：下面用 `set -- $(proc_state_threads ...)` 给局部变量赋值，
    #    它会覆盖本函数的位置参数，末尾再读 $2 就已经是被覆盖后的值了。
    want_deep=${2:-0}
    now_ms=$(epoch_ms)
    phase scan_dump_begin "$label"
    dump_ppid_table
    phase scan_dump_end "$label"
    family_closure
    phase scan_closure_end "$label"
    n_family=0
    n_renderer=0
    renderer_pids=""

    # created：本轮出现、上一轮没有
    while read -r pid; do
        [ -n "$pid" ] || continue
        grep -qxF "$pid" "${LAST_IDS:-/dev/null}" 2>/dev/null && continue
        ppid=$(proc_ppid "$pid")
        kind=$(proc_kind "$pid")
        start_ms=$(proc_start_ms "$pid")
        echo "MP_PROC_EVENT event=created pid=$pid ppid=$ppid kind=$kind start_ms=$start_ms label=$label" >> "$LOG"
        # "第一次"只能是第一次：不加这个闸，每个新子进程都会把 PID 覆盖成最后一个。
        case "$kind" in
            browser_child)
                if [ "${ZYGOTE_SEEN:-0}" = "0" ]; then
                    ZYGOTE_SEEN=1
                    mark ZYGOTE_FIRST_SEEN_EPOCH_MS "$now_ms"
                    mark ZYGOTE_FIRST_PID "$pid"
                fi
                ;;
            zygote_child)
                if [ "${RENDERER_CANDIDATE_SEEN:-0}" = "0" ]; then
                    RENDERER_CANDIDATE_SEEN=1
                    mark RENDERER_CANDIDATE_FIRST_EPOCH_MS "$now_ms"
                    mark RENDERER_CANDIDATE_FIRST_PID "$pid"
                fi
                ;;
        esac
    done < /tmp/mp-family.cur

    # exited：上一轮还在、这一轮没了
    if [ -s "${LAST_IDS:-/dev/null}" ]; then
        while read -r pid; do
            [ -n "$pid" ] || continue
            [ -d "/proc/$pid" ] && continue
            last=$(grep -F "pid=$pid " "${LAST_INFO:-/dev/null}" 2>/dev/null | tail -1)
            echo "MP_PROC_EVENT event=exited pid=$pid label=$label last=\"$last\"" >> "$LOG"
        done < "$LAST_IDS"
    fi

    phase scan_diff_end "$label"
    : > "${NEXT_INFO:-/tmp/mp-info.new}"
    fam_line=""
    while read -r pid; do
        [ -n "$pid" ] || continue
        [ -d "/proc/$pid" ] || continue
        n_family=$((n_family + 1))
        [ "$n_family" -gt "$LEDGER_MAX_PIDS" ] && break
        ppid=$(proc_ppid "$pid")
        kind=$(proc_kind "$pid")
        set -- $(proc_state_threads "$pid")
        state=${1:-?}
        threads=${2:-?}
        comm=$(proc_comm "$pid")
        echo "MP_LEDGER label=$label pid=$pid ppid=$ppid kind=$kind comm=$comm state=$state threads=$threads" >> "$LOG"
        echo "pid=$pid ppid=$ppid kind=$kind comm=$comm state=$state threads=$threads" >> "${NEXT_INFO:-/tmp/mp-info.new}"
        fam_line="$fam_line ${pid}:${kind}/${state}/${threads}"
        if [ "$kind" = "zygote_child" ]; then
            n_renderer=$((n_renderer + 1))
            renderer_pids="$renderer_pids $pid"
        fi
    done < /tmp/mp-family.cur
    # 一行摘要进串口：即使 /root 不落盘，也能从 console.log 还原每个时刻的进程族。
    echo "[mpdiag] MP_FAMILY label=$label n=$n_family$fam_line" > /dev/console 2>/dev/null

    # 深度说明：早期版本在这里读 /proc/<pid>/wchan 与 /proc/<pid>/syscall，
    # 结果两轮都在"第一次深采样"处把脚本挂死（看门狗继续跑、Weston 与 Chromium
    # 都还活着，只有写日志的进程停了）。这两个文件需要持锁访问目标任务，
    # 本内核在目标正跑在别的 CPU 上时会卡住读方 —— 已停用并登记为 procfs 缺口。
    # 现在深采样只做两件安全事：按 /proc/<pid>/stat 复核进程状态、按 status 取 VmRSS。
    phase scan_pids_end "$label"
    if [ "$want_deep" = "1" ]; then
        while read -r pid; do
            [ -n "$pid" ] || continue
            [ -d "/proc/$pid" ] || continue
            set -- $(awk '{ n = split($0, a, ") "); m = split(a[2], b, " "); if (m >= 22) printf "%s %s\n", b[1], b[22] }' \
                "/proc/$pid/stat" 2>/dev/null)
            pstate=${1:-?}
            rss_pages=${2:-0}
            rss_kb=$((rss_pages * 4))
            echo "MP_BLOCK label=$label pid=$pid stat_state=$pstate rss_kb=$rss_kb" >> "$LOG"
        done < /tmp/mp-family.cur
    fi

    cp -f "${NEXT_INFO:-/tmp/mp-info.new}" /tmp/mp-info.cur 2>/dev/null || true
    cp -f /tmp/mp-family.cur "${LAST_IDS:-/tmp/mp-ids.cur}" 2>/dev/null || true
    LAST_INFO=/tmp/mp-info.cur
    echo "$n_family $n_renderer $renderer_pids"
}

# 串口是唯一可靠的落地通道：Guest 的 /root 写入在关机后不回落到镜像
# （2026-11-02 final-mp-t1 实测：disk.img 里 /root 只有 9 月旧日志）。
# 所以凡是"这一轮结论要靠它"的数据，必须走 /dev/console。
# 看门狗独立于主循环：它停 = 整机冻死；它继续而 weston/chrome 变 no = 单进程死亡。
# 这两种情况的下一步完全不同，不能用"没输出"含糊过去。
watchdog() {
    family_watchdog_elapsed=0
    while :; do
        up=$(awk '{printf "%.0f", $1}' /proc/uptime 2>/dev/null || echo 0)
        mf=$(awk '/^MemFree:/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
        w=no
        c=no
        [ -n "${WESTON_PID:-}" ] && [ -d "/proc/$WESTON_PID" ] && w=yes
        [ -n "${BROWSER_PID:-}" ] && [ -d "/proc/$BROWSER_PID" ] && c=yes
        echo "[mpdiag] MP_WATCHDOG uptime_s=$up weston=$w chrome=$c memfree_kb=$mf" > /dev/console 2>/dev/null
        family_watchdog_elapsed=$((family_watchdog_elapsed + 2))
        if [ "$family_watchdog_elapsed" -ge "$FAMILY_WATCHDOG_INTERVAL" ]; then
            stability_family_snapshot
            family_watchdog_elapsed=0
        fi
        sleep 2
    done
}

proc_family_stat() {
    family_stat_pid=$1
    # Read stat once per candidate. Separate starttime/PPID/state reads run
    # several awk processes per PID and made high-frequency TCG scans costly.
    awk '{
        line = $0
        sub(/^.*\) /, "", line)
        count = split(line, field, / +/)
        if (count < 20 || field[1] !~ /^[A-Z?]$/ ||
            field[2] !~ /^[0-9]+$/ || field[18] !~ /^[0-9]+$/ ||
            field[20] !~ /^[0-9]+$/) exit 1
        printf "%s %s %s %.0f\n", field[2], field[1], field[18], field[20] * 10
    }' "/proc/$family_stat_pid/stat" 2>/dev/null
}

stability_family_snapshot() {
    [ -s "$PROCESS_FAMILY_SEEN" ] || return 0
    stability_label=$(mono_ms)
    stability_live_zygotes=" "
    stability_n=0
    stability_members=""

    # Validate each browser-owned Zygote once, and keep its same-read fields.
    while read -r role pid ppid start_ms; do
        [ "$role" = "zygote" ] || continue
        [ "$ppid" = "$BROWSER_PID" ] || continue
        if [ ! -r "/proc/$pid/stat" ]; then
            family_diagnostic_skip "$role" "$pid" "$BROWSER_PID" proc_missing "$start_ms" "" ""
            continue
        fi
        stability_fields=$(proc_family_stat "$pid") || {
            family_diagnostic_skip "$role" "$pid" "$BROWSER_PID" stat_unreadable "$start_ms" "" ""
            continue
        }
        set -- $stability_fields
        [ "$#" -eq 4 ] || continue
        stability_actual_ppid=$1
        stability_state=$2
        stability_threads=$3
        stability_actual_start=$4
        if [ "$stability_actual_start" != "$start_ms" ]; then
            family_diagnostic_skip "$role" "$pid" "$BROWSER_PID" starttime_mismatch \
                "$start_ms" "$stability_actual_start" "$stability_actual_ppid"
            continue
        fi
        if [ "$stability_actual_ppid" != "$BROWSER_PID" ]; then
            family_diagnostic_skip "$role" "$pid" "$BROWSER_PID" ppid_mismatch \
                "$start_ms" "$stability_actual_start" "$stability_actual_ppid"
            continue
        fi
        stability_live_zygotes="$stability_live_zygotes$pid "
        stability_n=$((stability_n + 1))
        stability_members="$stability_members $pid:browser_child/$stability_state/$stability_threads"
    done < "$PROCESS_FAMILY_SEEN"

    # Renderer candidates are included only when their recorded Zygote parent
    # remains live and PID, PPID, and starttime still match the observed child.
    while read -r role pid ppid start_ms; do
        [ "$role" = "renderer" ] || continue
        case "$stability_live_zygotes" in
            *" $ppid "*) ;;
            *) family_diagnostic_skip "$role" "$pid" "$ppid" zygote_parent_not_live "$start_ms" "" ""; continue ;;
        esac
        if [ ! -r "/proc/$pid/stat" ]; then
            family_diagnostic_skip "$role" "$pid" "$ppid" proc_missing "$start_ms" "" ""
            continue
        fi
        stability_fields=$(proc_family_stat "$pid") || {
            family_diagnostic_skip "$role" "$pid" "$ppid" stat_unreadable "$start_ms" "" ""
            continue
        }
        set -- $stability_fields
        [ "$#" -eq 4 ] || continue
        stability_actual_ppid=$1
        stability_state=$2
        stability_threads=$3
        stability_actual_start=$4
        if [ "$stability_actual_start" != "$start_ms" ]; then
            family_diagnostic_skip "$role" "$pid" "$ppid" starttime_mismatch \
                "$start_ms" "$stability_actual_start" "$stability_actual_ppid"
            continue
        fi
        if [ "$stability_actual_ppid" != "$ppid" ]; then
            family_diagnostic_skip "$role" "$pid" "$ppid" ppid_mismatch \
                "$start_ms" "$stability_actual_start" "$stability_actual_ppid"
            continue
        fi
        stability_n=$((stability_n + 1))
        stability_members="$stability_members $pid:zygote_child/$stability_state/$stability_threads"
    done < "$PROCESS_FAMILY_SEEN"

    echo "[mpdiag] MP_FAMILY_WATCHDOG label=$stability_label n=$stability_n$stability_members" \
        > /dev/console 2>/dev/null || true
}

family_diagnostic_skip() {
    [ "${MP_FAMILY_DIAGNOSTICS:-0}" = "1" ] || return 0
    echo "[mpdiag] MP_FAMILY_SKIP label=$stability_label role=$1 pid=$2 expected_ppid=$3 reason=$4 expected_start_ms=$5 actual_start_ms=$6 actual_ppid=$7" \
        > /dev/console 2>/dev/null || true
}

dump_fd_table_once() {
    label=$1
    pid=$2
    [ -n "$pid" ] || return 0
    [ -d "/proc/$pid/fd" ] || return 0
    echo "MP_FD_DUMP_BEGIN label=$label pid=$pid" >> "$LOG"
    echo "[mpdiag] MP_FD_DUMP_BEGIN label=$label pid=$pid" > /dev/console 2>/dev/null || true
    for fd in /proc/$pid/fd/*; do
        [ -e "$fd" ] || continue
        target=$(readlink "$fd" 2>/dev/null || true)
        echo "MP_FD pid=$pid fd=${fd##*/} target=$target" >> "$LOG"
        echo "[mpdiag] MP_FD pid=$pid fd=${fd##*/} target=$target" > /dev/console 2>/dev/null || true
    done
    echo "MP_FD_DUMP_END label=$label pid=$pid" >> "$LOG"
    echo "[mpdiag] MP_FD_DUMP_END label=$label pid=$pid" > /dev/console 2>/dev/null || true
}

# RSS 走 /proc/<pid>/status：busybox 的 `ps -o rss=` 在本 guest 上不可靠
# （上一轮 MP_RSS_KB 恒为 0，属于测量缺陷而不是"没有内存"）。
# RSS 同样只走 stat 字段 24（单位 = 页，按 4 KiB 折算）。
# 不用 status 的 VmRSS：本内核读 Chromium 子进程 status 会挂死读方。
family_rss_kb() {
    total=0
    while read -r pid; do
        [ -n "$pid" ] || continue
        set -- $(awk '{ n = split($0, a, ") "); m = split(a[2], b, " "); if (m >= 22) print b[22] }' \
            "/proc/$pid/stat" 2>/dev/null)
        v=${1:-0}
        case "$v" in ''|*[!0-9]*) v=0 ;; esac
        total=$((total + v * 4))
    done < /tmp/mp-family.cur
    echo "$total"
}

wait_for_wayland() {
    i=0
    while [ "$i" -lt 45 ]; do
        socket=$(find "$RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' 2>/dev/null | head -1)
        if [ -n "$socket" ]; then
            WAYLAND_DISPLAY=${socket##*/}
            export WAYLAND_DISPLAY
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    return 1
}

cleanup() {
    if [ -n "${WD_PID:-}" ] && [ -d "/proc/$WD_PID" ]; then
        kill -TERM "$WD_PID" 2>/dev/null || true
    fi
    if [ -n "${BROWSER_PID:-}" ] && [ -d "/proc/$BROWSER_PID" ]; then
        kill -TERM "$BROWSER_PID" 2>/dev/null || true
    fi
    if [ -n "${LAUNCHER_PID:-}" ] && [ -d "/proc/$LAUNCHER_PID" ]; then
        kill -TERM "$LAUNCHER_PID" 2>/dev/null || true
    fi
    if [ -n "${WESTON_PID:-}" ] && [ -d "/proc/$WESTON_PID" ]; then
        kill -TERM "$WESTON_PID" 2>/dev/null || true
    fi
    if [ -n "${SEATD_PID:-}" ] && [ -d "/proc/$SEATD_PID" ]; then
        kill -TERM "$SEATD_PID" 2>/dev/null || true
    fi
    if [ -n "${UDEVD_PID:-}" ] && [ -d "/proc/$UDEVD_PID" ]; then
        kill -TERM "$UDEVD_PID" 2>/dev/null || true
    fi
    # 早退（Weston/输入/DRM 失败）也必须把 guest 日志落盘，否则宿主只能从
    # 基础镜像里捞到上一轮的旧文件。
    sync 2>/dev/null || true
}
trap cleanup EXIT INT TERM

mark AUTORUN_START_EPOCH_MS "$(epoch_ms)"
mark AUTORUN_START_MONO_MS "$(mono_ms)"
log "PAGE_URL=$PAGE_URL"
log "TRACE_MODE=$TRACE_MODE"
log "GL_MODE=$GL_MODE"
log "NET_MODE=$NET_MODE"
log "LEDGER_MODE=$LEDGER_MODE"
log "FAMILY_WATCHDOG_INTERVAL=$FAMILY_WATCHDOG_INTERVAL"
log "WESTON_CONTINUE_WITHOUT_INPUT=$WESTON_CONTINUE_WITHOUT_INPUT"
log "MP_FAMILY_DIAGNOSTICS=$MP_FAMILY_DIAGNOSTICS"
log "MAX_SECONDS=$MAX_SECONDS SAMPLE_SECONDS=$SAMPLE_SECONDS HOLD_SECONDS=$HOLD_SECONDS"
log "kernel=$(uname -srm 2>/dev/null || true)"
log "PROC_VERSION=$(cat /proc/version 2>/dev/null || true)"
log "LD_PRELOAD=${LD_PRELOAD:-<unset>}"
log "CHROMIUM_SHA256=$(sha256sum /usr/lib/chromium/chromium 2>/dev/null | awk '{print $1}')"
log "OVERLAY_SHA256=$(sha256sum /pkgs.tar.gz 2>/dev/null | awk '{print $1}')"

# The installed guest image already contains the Chromium/Wayland package set.
# A stale /pkgs.tar.gz may still be present because it was used by an older
# injection round; unpacking it on every boot adds several minutes under TCG
# and can prevent Weston from ever starting.  Overlay extraction is therefore
# an explicit experiment, never an implicit side effect of a score run.
EXTRACT_OVERLAY=__MP_EXTRACT_OVERLAY__
DATAPIPE_FIX_FLAG=__MP_DATAPIPE_FIX__
MOJO_LEGACY_FEATURE=__MP_MOJO_LEGACY__
FD_DUMP=__MP_FD_DUMP__

mkdir -p /run/udev/data "$RUNTIME_DIR" /tmp/.X11-unix 2>/dev/null || true
chmod 700 "$RUNTIME_DIR" 2>/dev/null || true
rm -f /run/seatd.sock "$RUNTIME_DIR"/wayland-* 2>/dev/null || true

# The package overlay is immutable evidence input.  Extraction is allowed only
# when the caller supplied the tarball; no apk solver is run in this round.
if [ "$EXTRACT_OVERLAY" = "1" ] && [ -s /pkgs.tar.gz ]; then
    tar -xzf /pkgs.tar.gz -C / >> "$LOG" 2>&1 || log "PKG_OVERLAY_RC=$?"
elif [ -s /pkgs.tar.gz ]; then
    log "PKG_OVERLAY_SKIP=1 (set MP_EXTRACT_OVERLAY_VALUE=1 only for an explicit overlay experiment)"
fi

# strace 自检：Alpine overlay 的 strace 不认 %sched 这类新 trace group。
# 与其在日志里留下"看起来在 trace 其实没跑"的假象，不如先跑一次最小验证。
STRACE_OK=0
if command -v strace >/dev/null 2>&1; then
    log "STRACE_FILE=$(command -v strace)"
    if strace -e trace=execve -o /dev/null /bin/true >/dev/null 2>&1; then
        STRACE_OK=1
        log "STRACE_SELF_TEST=OK"
    else
        log "STRACE_SELF_TEST=FAIL"
    fi
else
    log "STRACE_FILE=missing"
fi

if command -v udevd >/dev/null 2>&1; then
    udevd --debug > "$UDEVD_LOG" 2>&1 &
    UDEVD_PID=$!
    sleep 1
    udevadm trigger --action=add --subsystem-match=input >/root/mp-udev-trigger.log 2>&1 || true
    udevadm trigger --action=add --subsystem-match=drm >>/root/mp-udev-trigger.log 2>&1 || true
    udevadm settle --timeout=8 >/root/mp-udev-settle.log 2>&1 || true
fi

# Use the real DRM sysfs/udev topology.  The former faux bus workaround made
# Weston hide the real /dev/dri/card0 and is forbidden for decision evidence.
log "DRM_NODES=$(ls -l /dev/dri 2>&1 || true)"
log "INPUT_NODES=$(ls -l /dev/input 2>&1 || true)"
log "DRM_SYSFS=$(find /sys/class/drm -maxdepth 2 \( -type f -o -type l \) 2>&1 | sort)"
write_input_seat_metadata

if command -v seatd >/dev/null 2>&1; then
    SEATD_VTBOUND=0 seatd -l info > "$SEATD_LOG" 2>&1 &
    SEATD_PID=$!
    sleep 1
fi

WESTON_EXTRA=""
if [ "$WESTON_CONTINUE_WITHOUT_INPUT" = "1" ]; then
    WESTON_EXTRA="--continue-without-input"
    log "WESTON_CONTINUE_WITHOUT_INPUT=ENABLED（A/B 诊断轮；本轮不得写入功能验收）"
fi
log "WESTON_ARGS=--backend=drm-backend.so --renderer=pixman --drm-device=card0 --seat=seat0 $WESTON_EXTRA --idle-time=0"

env XDG_RUNTIME_DIR="$RUNTIME_DIR" WESTON_DISABLE_ATOMIC=1 \
    LIBSEAT_BACKEND=seatd SEATD_SOCK=/run/seatd.sock \
    weston --backend=drm-backend.so --renderer=pixman --drm-device=card0 \
    --seat=seat0 $WESTON_EXTRA --idle-time=0 --debug --log="$WLOG" \
    >/root/mp-weston-stdout.log 2>&1 &
WESTON_PID=$!
if ! wait_for_wayland; then
    mark GATE 0
    log "WAYLAND_SOCKET_MISSING=1"
    weston_alive=no
    seatd_alive=no
    udevd_alive=no
    [ -n "${WESTON_PID:-}" ] && [ -d "/proc/$WESTON_PID" ] && weston_alive=yes
    [ -n "${SEATD_PID:-}" ] && [ -d "/proc/$SEATD_PID" ] && seatd_alive=yes
    [ -n "${UDEVD_PID:-}" ] && [ -d "/proc/$UDEVD_PID" ] && udevd_alive=yes
    log "WESTON_PID=${WESTON_PID:-unset} alive=$weston_alive"
    log "SEATD_PID=${SEATD_PID:-unset} alive=$seatd_alive"
    log "UDEVD_PID=${UDEVD_PID:-unset} alive=$udevd_alive"
    log "INPUT_SEAT_DATA_BEGIN"
    for f in /run/udev/data/c*; do
        [ -f "$f" ] || continue
        log "SEAT_DATA $f=$(tr '\n' ';' < "$f" 2>/dev/null)"
    done
    log "INPUT_SEAT_DATA_END"
    for failure_log in "$WLOG" /root/mp-weston-stdout.log "$SEATD_LOG" "$UDEVD_LOG" /root/mp-udev-trigger.log /root/mp-udev-settle.log; do
        [ -f "$failure_log" ] || continue
        log "FAILURE_LOG=$failure_log"
        tail -n 120 "$failure_log" >> "$LOG" 2>&1 || true
        echo "[mpdiag] FAILURE_LOG=$failure_log" > /dev/console 2>/dev/null || true
        tail -n 80 "$failure_log" > /dev/console 2>&1 || true
    done
    exit 31
fi
mark WESTON_SOCKET "$WAYLAND_DISPLAY"
log "weston_pid=$WESTON_PID alive=$([ -d "/proc/$WESTON_PID" ] && echo yes || echo no)"
log "WESTON_INPUT_LINES=$(grep -c -i 'input\|keyboard\|mouse\|seat' "$WLOG" 2>/dev/null || echo 0)"
grep -i 'input\|keyboard\|mouse\|seat' "$WLOG" 2>/dev/null | head -20 >> "$LOG" || true

rm -rf "$CHROME_PROFILE" 2>/dev/null || true
XDG_RUNTIME_DIR="$RUNTIME_DIR"
export XDG_RUNTIME_DIR WAYLAND_DISPLAY
export VK_ICD_FILENAMES=${VK_ICD_FILENAMES:-/usr/lib/chromium/vk_swiftshader_icd.json}

# This command is intentionally multi-process.  Keep the string in the log so
# a collector can fail a run that accidentally regresses to diagnostic mode.
case "$GL_MODE" in
    legacy)
        GL_ARGS="--use-gl=swiftshader"
        GL_FEATURES="Vulkan,SegmentationPlatform,OptimizationGuideModelDownloading,OptimizationHints,WebAppProvider,InterestFeedContentSuggestions"
        ;;
    angle)
        GL_ARGS="--use-gl=angle --use-angle=swiftshader"
        GL_FEATURES="SegmentationPlatform,OptimizationGuideModelDownloading,OptimizationHints,WebAppProvider,InterestFeedContentSuggestions"
        ;;
    *)
        log "INVALID_GL_MODE=$GL_MODE"
        exit 33
        ;;
esac
case "$NET_MODE" in
    normal) NET_FEATURES="$GL_FEATURES" ;;
    disable) NET_FEATURES="$GL_FEATURES,NetworkService" ;;
    *) log "INVALID_NET_MODE=$NET_MODE"; exit 34 ;;
esac
# Pure TCG can take several minutes between zygote fork and the first renderer
# control message. Keep the browser-side connection alive long enough for the
# renderer to finish bootstrap; this remains the normal zygote/renderer path.
CHROME_ARGS="--ozone-platform=wayland --js-flags=--jitless $DATAPIPE_FIX_FLAG $GL_ARGS --in-process-gpu --no-sandbox --disable-dev-shm-usage --disable-crash-reporter --disable-breakpad --no-first-run --no-default-browser-check --disable-sync --disable-component-update --disable-background-networking --disable-extensions --ipc-connection-timeout=600 --window-size=1280,800 --start-fullscreen --kiosk --disable-features=Vulkan,AudioServiceOutOfProcess,AudioServiceSandbox,$NET_FEATURES$MOJO_LEGACY_FEATURE --enable-logging=stderr --v=1 --vmodule=*file_url_loader_factory*=3,*document_loader*=3,*render_frame_impl*=3,*compositor_frame*=3,*frame_sink*=3,*wayland*=2,*ozone*=2,*navigation*=3,*render_process*=2,*zygote*=2,*mojo*=2 --user-data-dir=$CHROME_PROFILE $EXTRA_FLAGS"
case "$CHROME_ARGS" in
    *--single-process*|*--no-zygote*)
        mark GATE 0
        log "MULTIPROCESS_ARGUMENT_GUARD=FAIL"
        exit 32
        ;;
esac
log "CHROME_ARGS=$CHROME_ARGS"
mark BROWSER_START_EPOCH_MS "$(epoch_ms)"
BROWSER_START_MONO_MS_VALUE="$(mono_ms)"
mark BROWSER_START_MONO_MS "$BROWSER_START_MONO_MS_VALUE"

# 窄过滤生命周期 trace：保留 clone/clone3/execve/execveat/exit_group/wait4/
# prctl/set_tid_address，并包含 inotify_add_watch 以便区分路径 ENOENT 与
# syscall 能力缺失。正式评分与采样默认 TRACE_MODE=0，不受诊断过滤项影响。
TRACE_SYSCALLS=clone,clone3,execve,execveat,exit_group,wait4,prctl,set_tid_address,inotify_add_watch
if [ "$TRACE_MODE" = "1" ] && [ "$STRACE_OK" = "1" ]; then
    log "TRACE_CMD=strace -f -ttt -T -s 256 -e trace=$TRACE_SYSCALLS -o $LIFE"
    strace -f -ttt -T -s 256 \
        -e trace="$TRACE_SYSCALLS" \
        -o "$LIFE" \
        /usr/lib/chromium/chromium $CHROME_ARGS "$PAGE_URL" >> "$CHROME_LOG" 2>&1 &
    LAUNCHER_PID=$!
    BROWSER_PID=""
    i=0
    while [ "$i" -lt 20 ]; do
        for p in /proc/[0-9]*; do
            pid=${p#/proc/}
            ppid=$(proc_ppid "$pid")
            [ "$ppid" = "$LAUNCHER_PID" ] || continue
            BROWSER_PID=$pid
            break
        done
        [ -n "$BROWSER_PID" ] && break
        i=$((i + 1))
        sleep 1
    done
    if [ -z "$BROWSER_PID" ]; then
        log "BROWSER_PID_RESOLVE=FAIL（回落到 tracer pid；本轮存活判定按 tracer 计）"
        BROWSER_PID="$LAUNCHER_PID"
    else
        log "BROWSER_PID_RESOLVE=OK pid=$BROWSER_PID tracer=$LAUNCHER_PID"
    fi
else
    [ "$TRACE_MODE" = "1" ] && log "STRACE_SKIPPED=unavailable"
    /usr/lib/chromium/chromium $CHROME_ARGS "$PAGE_URL" >> "$CHROME_LOG" 2>&1 &
    BROWSER_PID=$!
    LAUNCHER_PID=$BROWSER_PID
fi
mark BROWSER_PID "$BROWSER_PID"
log "browser_pid=$BROWSER_PID launcher_pid=$LAUNCHER_PID"
browser_ppid=$(proc_ppid "$BROWSER_PID")
emit_process_event browser browser-start "$BROWSER_PID" "$browser_ppid"
echo "browser:$BROWSER_PID" >> "$PROCESS_EVENTS_SEEN"
watchdog &
WD_PID=$!
log "WATCHDOG_PID=$WD_PID（独立心跳：它停 = 整机冻死）"

: > /tmp/mp-family.prev
: > /tmp/mp-ids.cur
: > /tmp/mp-info.cur
LAST_IDS=/tmp/mp-ids.cur
LAST_INFO=/tmp/mp-info.cur
mark LEDGER_FORMAT "MP_LEDGER/MP_PROC_EVENT/MP_BLOCK/MP_FAMILY/MP_WATCHDOG"
mark BLOCK_READS "disabled:wchan,syscall 会挂住读方（2026-11-02 实测两轮）"
mark LEDGER_LIMIT "阻塞读：跨进程读 Chromium 子进程 procfs 会挂住读方；账本在其后停住（待内核侧修复）"

renderer_streak=0
renderer_max_streak=0
renderer_seen=0
fd_dumped=0
max_rss=0
elapsed=0
tick=0
# 提前导出一次 Chromium 日志：轮次被 DUR 掐断时，收尾的 tail -160 永远走不到
# （2026-11-04 的 mp-r2：跑到 600 s 仍在扫描循环里，日志一句没出来）。
# 这里在 tick≥6 时导一次，只导一次，代价 120 行串口输出。
CHROME_LOG_DUMPED=0
[ "$SAMPLE_SECONDS" -ge 1 ] 2>/dev/null || SAMPLE_SECONDS=5
while [ "$elapsed" -lt "$MAX_SECONDS" ]; do
    [ -d "/proc/$BROWSER_PID" ] || [ -d "/proc/$LAUNCHER_PID" ] || break
    tick=$((tick + 1))
    deep=0
    [ $((tick % SAMPLE_SECONDS)) -eq 1 ] && deep=1
    if [ "$tick" -le 30 ]; then PHASE_DEBUG=1; else PHASE_DEBUG=0; fi
    phase loop_begin "$tick"
    if [ "$LEDGER_MODE" = "1" ]; then
        set -- $(ledger_scan "${elapsed}s" "$deep")
        phase loop_scan_returned "$tick"
        n_family=${1:-0}
        renderer_count=${2:-0}
        renderer_pids=${3:-}
    else
        # 轻量模式：ps 只枚举 /proc 顶层，不做跨任务深读。跨任务读与进程生命周期
        # 都交给独立的 C 探针，原因是 shell 每 tick fork 几十次（本内核 fork≈47.5ms），
        # 记账本身就会把采样周期从 1 s 拖到 26–50 s。
        #   /proc_ledger   —— 全程不 fork，只读 stat，给出 created/exited/summary；
        #   /procfs_latency —— 只量延迟，用于对齐历史数据。
        PROCESS_LIST=/tmp/mp-process-snapshot.txt
        ZYGOTE_LIST=/tmp/mp-observed-zygotes.txt
        ps 2>/dev/null > "$PROCESS_LIST"
        n_family=$(awk 'NR > 1 { n++ } END { print n + 0 }' "$PROCESS_LIST" 2>/dev/null)
        : > "$ZYGOTE_LIST"
        while IFS= read -r process_line; do
            process_pid_from_line "$process_line"
            process_pid=$PROCESS_PID_FIELD
            case "$process_pid" in ''|*[!0-9]*) continue ;; esac
            case "$process_line" in *"--type=zygote"*) echo "$process_pid" >> "$ZYGOTE_LIST" ;; esac
        done < "$PROCESS_LIST"
        renderer_pids=""
        renderer_count=0
        while read -r process_pid process_ppid; do
            case "$process_pid" in ''|*[!0-9]*) continue ;; esac
            case "$process_ppid" in ''|*[!0-9]*) continue ;; esac
            zygote_parent=0
            while IFS= read -r zygote_pid; do
                [ "$process_ppid" = "$zygote_pid" ] && zygote_parent=1
            done < "$ZYGOTE_LIST"
            if [ "$zygote_parent" = "1" ]; then
                renderer_pids="${renderer_pids}${process_pid},"
                renderer_count=$((renderer_count + 1))
            fi
        done < /tmp/mp-ppid.txt
        echo "MP_LIGHT_SAMPLE elapsed=${elapsed}s family=${n_family} renderer_count=${renderer_count} renderer_pids=${renderer_pids}" >> "$LOG"
        if [ -x /proc_ledger ] && [ ! -d "/proc/${PLEDGER_PID:-none}" ]; then
            PLEDGER_PID=""
            /proc_ledger -i 2 > /dev/console 2>&1 &
            PLEDGER_PID=$!
            log "PROC_LEDGER_START pid=$PLEDGER_PID"
        fi
        if [ -x /procfs_latency ] && [ "${LAT_SAMPLE:-0}" = "1" ] && [ ! -d "/proc/${LAT_PID:-none}" ]; then
            LAT_PID=""
            /procfs_latency -n 100000 -i 30 -b 3000 -s > /dev/console 2>&1 &
            LAT_PID=$!
            log "LAT_PROBE_START pid=$LAT_PID"
        fi
    fi
    if [ "$deep" = "1" ]; then
        observe_process_tree
    fi
    if [ "$deep" = "1" ]; then
        rss=$(family_rss_kb)
        [ "$rss" -gt "$max_rss" ] 2>/dev/null && max_rss=$rss
        mark SAMPLE_ELAPSED_SEC "$elapsed"
        mark RENDERER_COUNT "$renderer_count"
        mark FAMILY_COUNT "$n_family"
        mark RENDERER_PIDS "$renderer_pids"
        mark RSS_KB "$rss"
    fi
    if [ "$renderer_count" -gt 0 ]; then
        [ "$renderer_seen" -eq 0 ] && mark RENDERER_FIRST_STREAK_EPOCH_MS "$(epoch_ms)"
        renderer_seen=1
        renderer_streak=$((renderer_streak + 1))
        [ "$renderer_streak" -gt "$renderer_max_streak" ] && renderer_max_streak=$renderer_streak
        if [ "$FD_DUMP" = "1" ] && [ "$fd_dumped" = "0" ]; then
            dump_fd_table_once browser "$BROWSER_PID"
            # cmdline is normally readable on Linux, but has blocked the
            # observer on this kernel before. Bound each read to 2 seconds and
            # fall back to the already-known browser child closure.
            renderer_pid=""
            if [ -r "/proc/$BROWSER_PID/task/$BROWSER_PID/children" ]; then
                renderer_pid=$(cat "/proc/$BROWSER_PID/task/$BROWSER_PID/children" 2>/dev/null | awk '{print $1}')
            fi
            if [ -z "$renderer_pid" ]; then
                for child_stat in /proc/[0-9]*/stat; do
                    child=${child_stat#/proc/}
                    child=${child%/stat}
                    ppid=$(proc_ppid "$child")
                    if [ "$ppid" = "$BROWSER_PID" ]; then renderer_pid=$child; break; fi
                done
            fi
            if [ -n "$renderer_pid" ]; then
                dump_fd_table_once renderer "$renderer_pid"
            else
                log "MP_FD_RENDERER_UNRESOLVED pids=$renderer_pids"
            fi
            fd_dumped=1
        fi
    else
        renderer_streak=0
    fi
    # 等启动日志真正产生后再导出。renderer 候选刚出现时 Chrome 日志文件经常
    # 仍是 0 字节；过早导出会把最有价值的 FileURLLoader/DocumentLoader 证据丢掉。
    if [ "${CHROME_LOG_DUMPED:-0}" = "0" ] && [ "$tick" -ge 25 ]; then
        CHROME_LOG_DUMPED=1
        # 串口是唯一落地通道：必须写 /dev/console（写 $LOG 只在 guest 磁盘里）
        echo "CHROMIUM_EARLY_LOG_BEGIN tick=$tick bytes=$(wc -c < "$CHROME_LOG" 2>/dev/null || echo 0)" >> "$LOG"
        echo "CHROMIUM_EARLY_LOG_BEGIN tick=$tick bytes=$(wc -c < "$CHROME_LOG" 2>/dev/null || echo 0)" > /dev/console
        tail -n 120 "$CHROME_LOG" >> "$LOG" 2>&1 || true
        tail -n 120 "$CHROME_LOG" > /dev/console 2>&1 || true
        echo "CHROMIUM_EARLY_LOG_END" >> "$LOG"
        echo "CHROMIUM_EARLY_LOG_END" > /dev/console
    fi
    # Diagnostic-only strace windows make Renderer bootstrap failures visible
    # before the host readiness timeout ends the QEMU session. Formal runs keep
    # TRACE_MODE=0 and do not pay this logging cost.
    if [ "$TRACE_MODE" = "1" ]; then
        snapshot_now_ms="$(mono_ms)"
        snapshot_age_ms=$((snapshot_now_ms - BROWSER_START_MONO_MS_VALUE))
        while [ "$snapshot_age_ms" -ge "$TRACE_SNAPSHOT_NEXT_MS" ]; do
            log "CHROMIUM_DIAGNOSTIC_SNAPSHOT_BEGIN age_ms=$snapshot_age_ms chrome_bytes=$(wc -c < "$CHROME_LOG" 2>/dev/null || echo 0) trace_bytes=$(wc -c < "$LIFE" 2>/dev/null || echo 0)"
            tail -n 80 "$CHROME_LOG" >> "$LOG" 2>&1 || true
            tail -n 80 "$CHROME_LOG" > /dev/console 2>&1 || true
            if [ -s "$LIFE" ]; then
                log "CHROMIUM_LIFECYCLE_SNAPSHOT_BEGIN tick=$tick bytes=$(wc -c < "$LIFE" 2>/dev/null || echo 0)"
                grep -E 'clone\(|clone3\(|execve(at)?\(|exit_group\(|wait4\(' "$LIFE" 2>/dev/null \
                    | tail -n 40 | while IFS= read -r trace_line; do
                        log "CHROMIUM_LIFECYCLE_TRACE $trace_line"
                    done
            else
                log "CHROMIUM_LIFECYCLE_TRACE_UNAVAILABLE=1"
            fi
            log "CHROMIUM_DIAGNOSTIC_SNAPSHOT_END age_ms=$snapshot_age_ms"
            TRACE_SNAPSHOT_NEXT_MS=$((TRACE_SNAPSHOT_NEXT_MS + 120000))
        done
    fi
    if [ -n "$PERF_TRACE_FILE" ] && [ $((elapsed % 5)) -eq 0 ]; then
        perf_trace_export_once
    fi
    phase loop_body_done "$tick"
    elapsed=$((elapsed + 1))
    sleep 1
done
mark LEDGER_ELAPSED_SEC "$elapsed"
# 退出原因是账本的第一性问题：超时结束 / 浏览器先死 / 其他，三者结论完全不同。
if [ "$elapsed" -ge "$MAX_SECONDS" ]; then
    mark LOOP_EXIT timeout
elif [ ! -d "/proc/$BROWSER_PID" ] && [ ! -d "/proc/$LAUNCHER_PID" ]; then
    mark LOOP_EXIT browser_gone
else
    mark LOOP_EXIT other
fi

if [ -d "/proc/$BROWSER_PID" ]; then
    kill -TERM "$BROWSER_PID" 2>/dev/null || true
fi
grace=0
while [ "$grace" -lt 5 ] && [ -d "/proc/$BROWSER_PID" ]; do
    sleep 1
    grace=$((grace + 1))
done
if [ -d "/proc/$BROWSER_PID" ]; then
    log "BROWSER_TERM_TIMEOUT=1"
    kill -KILL "$BROWSER_PID" 2>/dev/null || true
fi
if [ -n "${LAUNCHER_PID:-}" ] && [ -d "/proc/$LAUNCHER_PID" ]; then
    sleep 1
    kill -TERM "$LAUNCHER_PID" 2>/dev/null || true
fi
# 必须 wait 直接子进程：带 strace 时 BROWSER_PID 是孙进程，wait 它只会拿到
# 127（"not a child"），从而把一个正常的收尾记成异常退出码。
wait "$LAUNCHER_PID" 2>/dev/null
chrome_rc=$?
perf_trace_export_once
mark BROWSER_EXIT_EPOCH_MS "$(epoch_ms)"
mark LAUNCHER_EXIT_RC "$chrome_rc"
[ "$LAUNCHER_PID" = "$BROWSER_PID" ] && mark LAUNCHER_KIND direct || mark LAUNCHER_KIND strace
mark RSS_MAX_KB "$max_rss"
mark RENDERER_CANDIDATE_SEEN "$renderer_seen"
mark RENDERER_CANDIDATE_MAX_STREAK "$renderer_max_streak"

# ---------------------------------------------------------------- 生命周期回执
# 从窄 trace 里抽出 clone / execve / exit_group，给出"谁 fork 了谁、谁真的 exec、
# 谁以什么码退出"。这是账本的第三根支柱（另两根：每秒状态、Chromium 原始日志）。
if [ -s "$LIFE" ]; then
    mark LIFECYCLE_LINES "$(wc -l < "$LIFE" 2>/dev/null || echo 0)"
    awk '
        {
            pid = $1
            gsub(/[^0-9]/, "", pid)
            if (pid == "") next
            line = $0
            if (line ~ /clone\(|clone3\(/) {
                n = split(line, parts, "= ")
                if (n >= 2) {
                    # 失败的 clone 返回 "-1 EAGAIN (...)"，直接把数字抠出来会得到
                    # child=1 —— 一个不存在的子进程，会把账本污染成"fork 过、后来没了"。
                    res = parts[n]
                    if (res ~ /^[0-9]+$/) {
                        printf "MP_LIFECYCLE event=clone parent=%s child=%s raw=%s\n", pid, res, line
                    }
                }
            } else if (line ~ /execve\(|execveat\(/) {
                path = ""
                if (match(line, /"[^"]+"/)) path = substr(line, RSTART, RLENGTH)
                printf "MP_LIFECYCLE event=exec pid=%s path=%s raw=%s\n", pid, path, line
            } else if (line ~ /exit_group\(/) {
                printf "MP_LIFECYCLE event=exit pid=%s raw=%s\n", pid, line
            }
        }' "$LIFE" > /tmp/mp-life.parse
    n_life=$(wc -l < /tmp/mp-life.parse 2>/dev/null || echo 0)
    if [ "$n_life" -gt 400 ] 2>/dev/null; then
        head -200 /tmp/mp-life.parse >> "$LOG"
        echo "MP_LIFECYCLE_TRUNCATED total=$n_life kept_head=200 kept_tail=200" >> "$LOG"
        tail -200 /tmp/mp-life.parse >> "$LOG"
    else
        cat /tmp/mp-life.parse >> "$LOG"
    fi
    echo "MP_LIFECYCLE_END" >> "$LOG"
fi


# ---------------------------------------------------------------- Chromium 原始回执
# 只报关键字命中次数与首末行，不把日志时间戳换算成 epoch（前缀格式随版本变化，
# 换算错会造出一个"看起来精确"的假指标）。
receipt() {
    key=$1
    pat=$2
    cnt=$(grep -c -E "$pat" "$CHROME_LOG" 2>/dev/null || echo 0)
    echo "MP_RECEIPT_COUNT key=$key count=$cnt" >> "$LOG"
    [ "$cnt" -gt 0 ] 2>/dev/null || return 0
    grep -E "$pat" "$CHROME_LOG" 2>/dev/null | head -3 | while IFS= read -r l; do
        echo "MP_RECEIPT_FIRST key=$key line=$l" >> "$LOG"
    done
    grep -E "$pat" "$CHROME_LOG" 2>/dev/null | tail -3 | while IFS= read -r l; do
        echo "MP_RECEIPT_LAST key=$key line=$l" >> "$LOG"
    done
}
log "CHROMIUM_LOG_BYTES=$(wc -c < "$CHROME_LOG" 2>/dev/null || echo 0)"
receipt zygote 'zygote'
receipt launch_process 'LaunchProcess|launch_process'
receipt render_process 'render_process|RenderProcess'
receipt renderer_exit 'renderer.*exit|Renderer process|exited with'
receipt navigation 'NavigationRequest|DidStartNavigation|CommitNavigation'

# 最终门禁：候选子进程累计存活 >=12 s **且** Chromium 自己打出 render_process 回执，
# 两条同时成立才算 renderer 成立。缺一即 GATE=0 —— 不能把"zygote 的孙子进程"
# 直接当成 renderer，那正是这类诊断最容易出的假绿。
rp=$(grep -o "MP_RECEIPT_COUNT key=render_process count=[0-9]*" "$LOG" 2>/dev/null | tail -1 | grep -o "[0-9]*$")
[ -n "${rp:-}" ] || rp=0
mark RENDERER_RECEIPT_COUNT "$rp"
if [ "$renderer_max_streak" -ge 12 ] && [ "$rp" -gt 0 ] 2>/dev/null; then
    mark GATE 1
else
    mark GATE 0
fi

tail -n 160 "$CHROME_LOG" >> "$LOG" 2>&1 || true
tail -n 160 "$CHROME_LOG" > /dev/console 2>&1 || true

# Keep the compositor alive long enough for a caller to take a stability shot.
hold=0
while [ "$hold" -lt "$HOLD_SECONDS" ] && [ -d "/proc/$WESTON_PID" ]; do
    sleep 5
    hold=$((hold + 5))
done

# 内核侧最后一条线索：若 guest 撑到收尾，dmesg 里常有 OOM/异常；没有就明写没有。
if command -v dmesg >/dev/null 2>&1; then
    log "DMESG_BEGIN"
    dmesg 2>/dev/null | tail -n 40 >> "$LOG" || true
    log "DMESG_END"
else
    log "DMESG=unavailable"
fi
sync
