#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define MAX_PROCESSES 4096
#define MAX_LINE 4096
#define SCHEMA "xkernel.browser.lifecycle.v1"
#define CLOCK_ID "LINUX_CLOCK_MONOTONIC"

typedef struct {
    pid_t pid;
    pid_t ppid;
    uint64_t start_ticks;
    int depth;
    bool in_tree;
    char instance[64];
    char role[32];
    uint64_t rss_kb;
    uint64_t pss_kb;
    uint64_t uss_kb;
    bool memory_present;
} Process;

typedef struct {
    char instance[64];
    char role[32];
    pid_t pid;
    bool active;
    uint64_t role_checked_t_ns;
} SeenProcess;

#define ROLE_RECHECK_INTERVAL_NS 5000000000ULL

static uint64_t sequence_number;
static uint64_t sample_number;
static const char *memory_source = "per-pid-smaps_rollup";
static bool tree_snapshot_timing_present;
static uint64_t tree_snapshot_total_ns;
static uint64_t tree_snapshot_resident_walk_ns;
static uint64_t tree_snapshot_mapcount_ns;
static uint64_t tree_snapshot_rollup_ns;
static uint64_t tree_snapshot_format_ns;
static uint64_t tree_snapshot_process_count;
static uint64_t tree_snapshot_resident_pages;
static uint64_t tree_endpoint_read_ns;

static uint64_t monotonic_ns(void);
static int process_index(const Process *processes, size_t count, pid_t pid);
static bool read_stat(pid_t pid, pid_t *ppid, uint64_t *start_ticks);

static bool parse_u64_field(const char *line, const char *name, uint64_t *value) {
    const char *start = strstr(line, name);
    if (!start)
        return false;
    start += strlen(name);
    char *end = NULL;
    errno = 0;
    unsigned long long parsed = strtoull(start, &end, 10);
    if (errno || end == start)
        return false;
    *value = (uint64_t)parsed;
    return true;
}

/*
 * Prefer the xkernel procfs bulk snapshot.  The endpoint performs one
 * consistent resident/PSS/USS walk inside the kernel and returns the complete
 * descendant tree, so the sampler does not first walk every /proc entry and
 * then issue one potentially blocking smaps read per process.  A return value
 * of 0 means the endpoint is not present and asks the caller to use the
 * historical Linux-compatible fallback; -1 means the endpoint was present but
 * the snapshot was incomplete or malformed and must remain an invalid sample.
 */
static int read_tree_endpoint(Process *processes, size_t *count, pid_t root_pid) {
    char path[96];
    snprintf(path, sizeof(path), "/proc/%d/xk_memory_snapshot", root_pid);
    FILE *file = fopen(path, "r");
    bool xk_snapshot = true;
    if (!file && errno == ENOENT) {
        snprintf(path, sizeof(path), "/proc/%d/tree_smaps_rollup", root_pid);
        file = fopen(path, "r");
        xk_snapshot = false;
    }
    if (!file)
        return errno == ENOENT ? 0 : -1;

    uint64_t read_started_ns = monotonic_ns();
    tree_snapshot_timing_present = false;
    tree_snapshot_total_ns = 0;
    tree_snapshot_resident_walk_ns = 0;
    tree_snapshot_mapcount_ns = 0;
    tree_snapshot_rollup_ns = 0;
    tree_snapshot_format_ns = 0;
    tree_snapshot_process_count = 0;
    tree_snapshot_resident_pages = 0;
    char line[MAX_LINE];
    bool header_seen = false;
    bool complete = false;
    uint64_t expected_rows = 0;
    size_t rows = 0;
    while (fgets(line, sizeof(line), file)) {
        if (xk_snapshot && strncmp(line, "snapshot version=1 ", 19) == 0) {
            header_seen = true;
            if (strstr(line, "complete=1") == NULL) {
                fclose(file);
                return -1;
            }
            complete = true;
            uint64_t ignored = 0;
            if (!parse_u64_field(line, "total_ns=", &tree_snapshot_total_ns) ||
                !parse_u64_field(line, "resident_walk_ns=", &tree_snapshot_resident_walk_ns) ||
                !parse_u64_field(line, "mapcount_ns=", &tree_snapshot_mapcount_ns) ||
                !parse_u64_field(line, "rollup_ns=", &tree_snapshot_rollup_ns) ||
                !parse_u64_field(line, "format_ns=", &tree_snapshot_format_ns) ||
                !parse_u64_field(line, "process_count=", &tree_snapshot_process_count) ||
                !parse_u64_field(line, "resident_pages=", &tree_snapshot_resident_pages)) {
                /* Timing fields were added after the first MVP. Keep the
                 * snapshot usable while marking timing unavailable. */
                tree_snapshot_timing_present = false;
            } else {
                tree_snapshot_timing_present = true;
            }
            (void)parse_u64_field(line, "t_ns=", &ignored);
            continue;
        }
        if (!xk_snapshot && strncmp(line, "META ", 5) == 0) {
            header_seen = true;
            complete = parse_u64_field(line, "total_ns=", &tree_snapshot_total_ns) &&
                       parse_u64_field(line, "resident_walk_ns=", &tree_snapshot_resident_walk_ns) &&
                       parse_u64_field(line, "mapcount_ns=", &tree_snapshot_mapcount_ns) &&
                       parse_u64_field(line, "rollup_ns=", &tree_snapshot_rollup_ns) &&
                       parse_u64_field(line, "format_ns=", &tree_snapshot_format_ns) &&
                       parse_u64_field(line, "process_count=", &tree_snapshot_process_count) &&
                       parse_u64_field(line, "resident_pages=", &tree_snapshot_resident_pages);
            tree_snapshot_timing_present = complete;
            continue;
        }
        if (!xk_snapshot && strncmp(line, "PID ", 4) == 0)
            continue;
        if (xk_snapshot && strncmp(line, "process ", 8) == 0) {
            if (!header_seen || rows >= MAX_PROCESSES)
                continue;
            Process *process = &processes[rows];
            int pid = 0;
            int ppid = 0;
            unsigned long long start = 0;
            unsigned long long rss_pages = 0;
            unsigned long long pss_pages = 0;
            unsigned long long uss_pages = 0;
            unsigned long long shared_pages = 0;
            char role[sizeof(process->role)] = "child";
            if (sscanf(line,
                       "process pid=%d ppid=%d start=%llu role=%31s rss_pages=%llu "
                       "pss_pages=%llu uss_pages=%llu shared_pages=%llu",
                       &pid, &ppid, &start, role, &rss_pages, &pss_pages,
                       &uss_pages, &shared_pages) != 8 || pid <= 0 || ppid < 0)
                continue;
            memset(process, 0, sizeof(*process));
            process->pid = (pid_t)pid;
            process->ppid = (pid_t)ppid;
            process->start_ticks = (uint64_t)start;
            process->in_tree = true;
            process->depth = 0;
            snprintf(process->instance, sizeof(process->instance), "%d-%" PRIu64,
                     process->pid, process->start_ticks);
            snprintf(process->role, sizeof(process->role), "%s",
                     pid == root_pid ? "browser" :
                     (strcmp(role, "renderer") == 0 || strcmp(role, "zygote") == 0 ||
                      strcmp(role, "utility") == 0 || strcmp(role, "gpu") == 0)
                         ? role : "child");
            if (rss_pages > UINT64_MAX / 4 || pss_pages > UINT64_MAX / 4 ||
                uss_pages > UINT64_MAX / 4 || shared_pages > UINT64_MAX / 4)
                continue;
            process->rss_kb = (uint64_t)rss_pages * 4;
            process->pss_kb = (uint64_t)pss_pages * 4;
            process->uss_kb = (uint64_t)uss_pages * 4;
            process->memory_present = true;
            rows++;
            continue;
        }
        if (!xk_snapshot && header_seen && line[0] >= '0' && line[0] <= '9') {
            if (rows >= MAX_PROCESSES)
                continue;
            Process *process = &processes[rows];
            int pid = 0;
            int ppid = 0;
            unsigned long long rss = 0;
            unsigned long long pss = 0;
            unsigned long long uss = 0;
            if (sscanf(line, "%d %d %llu %llu %llu", &pid, &ppid, &rss, &pss, &uss) != 5 ||
                pid <= 0 || ppid < 0)
                continue;
            memset(process, 0, sizeof(*process));
            process->pid = (pid_t)pid;
            process->ppid = (pid_t)ppid;
            process->start_ticks = 0;
            pid_t ignored_ppid = 0;
            (void)read_stat(process->pid, &ignored_ppid, &process->start_ticks);
            process->in_tree = true;
            process->depth = 0;
            snprintf(process->instance, sizeof(process->instance), "%d-%" PRIu64,
                     process->pid, process->start_ticks);
            snprintf(process->role, sizeof(process->role), "%s",
                     pid == root_pid ? "browser" : "child");
            process->rss_kb = rss;
            process->pss_kb = pss;
            process->uss_kb = uss;
            process->memory_present = true;
            rows++;
            continue;
        }
        if (xk_snapshot && strncmp(line, "snapshot-end ", 14) == 0) {
            if (!parse_u64_field(line, "rows=", &expected_rows)) {
                fclose(file);
                return -1;
            }
        }
    }
    fclose(file);
    tree_endpoint_read_ns = monotonic_ns() - read_started_ns;
    if (!xk_snapshot)
        expected_rows = rows;
    if (!header_seen || !complete || rows == 0 || expected_rows != rows)
        return -1;

    int root_index = process_index(processes, rows, root_pid);
    if (root_index < 0)
        return -1;
    processes[root_index].depth = 0;
    for (size_t i = 0; i < rows; ++i) {
        if ((int)i == root_index)
            continue;
        int current = (int)i;
        int depth = 0;
        bool reaches_root = false;
        for (size_t hops = 0; hops <= rows; ++hops) {
            if (processes[current].pid == root_pid) {
                reaches_root = true;
                break;
            }
            int parent = process_index(processes, rows, processes[current].ppid);
            if (parent < 0 || parent == current)
                break;
            current = parent;
            depth++;
        }
        if (!reaches_root)
            return -1;
        processes[i].depth = depth;
    }
    memory_source = "procfs-xk-memory-snapshot";
    *count = rows;
    return 1;
}
static uint64_t monotonic_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        perror("clock_gettime");
        exit(2);
    }
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static bool parse_positive_pid(const char *text, pid_t *pid) {
    if (!text || !*text)
        return false;
    char *end = NULL;
    errno = 0;
    long value = strtol(text, &end, 10);
    if (errno || *end || value <= 0 || value > INT_MAX)
        return false;
    *pid = (pid_t)value;
    return true;
}

static int process_index(const Process *processes, size_t count, pid_t pid) {
    for (size_t i = 0; i < count; ++i) {
        if (processes[i].pid == pid)
            return (int)i;
    }
    return -1;
}

static bool read_stat(pid_t pid, pid_t *ppid, uint64_t *start_ticks) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/stat", pid);
    FILE *file = fopen(path, "r");
    if (!file)
        return false;
    char line[MAX_LINE];
    if (!fgets(line, sizeof(line), file)) {
        fclose(file);
        return false;
    }
    fclose(file);
    char *right_paren = strrchr(line, ')');
    if (!right_paren || right_paren[1] != ' ')
        return false;
    char *save = NULL;
    char *token = strtok_r(right_paren + 2, " ", &save);  // field 3: state
    unsigned field = 3;
    long parsed_ppid = -1;
    uint64_t parsed_start = 0;
    while (token) {
        if (field == 4) {
            char *end = NULL;
            errno = 0;
            parsed_ppid = strtol(token, &end, 10);
            if (errno || end == token || *end || parsed_ppid < 0 || parsed_ppid > INT_MAX)
                return false;
        } else if (field == 22) {
            char *end = NULL;
            errno = 0;
            parsed_start = strtoull(token, &end, 10);
            if (errno || end == token || *end)
                return false;
            break;
        }
        field++;
        token = strtok_r(NULL, " ", &save);
    }
    if (parsed_ppid < 0)
        return false;
    *ppid = (pid_t)parsed_ppid;
    *start_ticks = parsed_start;
    return true;
}

static bool assign_process_role(Process *process, const char *name) {
    const char *role = NULL;
    if (strcmp(name, "CrRendererMain") == 0 || strstr(name, "--type=renderer"))
        role = "renderer";
    else if (strcmp(name, "CrZygoteMain") == 0 || strstr(name, "--type=zygote"))
        role = "zygote";
    else if (strcmp(name, "CrUtilityMain") == 0 || strstr(name, "--type=utility"))
        role = "utility";
    else if (strcmp(name, "CrGpuMain") == 0 || strstr(name, "--type=gpu-process"))
        role = "gpu";
    if (!role)
        return false;
    snprintf(process->role, sizeof(process->role), "%s", role);
    return true;
}

static bool read_process_comm(const Process *process, char *comm,
                              size_t capacity) {
    char path[80];
    snprintf(path, sizeof(path), "/proc/%d/task/%d/comm", process->pid,
             process->pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0 || capacity < 2) {
        if (fd >= 0)
            close(fd);
        return false;
    }
    ssize_t length = read(fd, comm, capacity - 1);
    close(fd);
    if (length <= 0)
        return false;
    while (length > 0 && (comm[length - 1] == '\n' || comm[length - 1] == '\r'))
        --length;
    comm[length] = '\0';
    return length > 0;
}

static void classify_process_role(Process *process, bool recheck_zygote_child) {
    if (recheck_zygote_child) {
        if (strcmp(process->role, "browser") == 0 ||
            strcmp(process->role, "renderer") == 0 ||
            strcmp(process->role, "utility") == 0 ||
            strcmp(process->role, "gpu") == 0 ||
            (strcmp(process->role, "zygote") == 0 && process->depth <= 1))
            return;
        char comm[64];
        if (read_process_comm(process, comm, sizeof(comm)))
            (void)assign_process_role(process, comm);
        return;
    }
    if (strcmp(process->role, "browser") == 0 ||
        strcmp(process->role, "renderer") == 0 ||
        strcmp(process->role, "utility") == 0 ||
        strcmp(process->role, "gpu") == 0)
        return;
    char comm[64];
    if (read_process_comm(process, comm, sizeof(comm)) &&
        assign_process_role(process, comm))
        return;
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/cmdline", process->pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return;
    char command[2048];
    ssize_t length = read(fd, command, sizeof(command) - 1);
    close(fd);
    if (length <= 0)
        return;
    for (ssize_t i = 0; i < length; ++i) {
        if (command[i] == '\0')
            command[i] = ' ';
    }
    command[length] = '\0';
    (void)assign_process_role(process, command);
}

static size_t scan_processes(Process *processes) {
    DIR *proc = opendir("/proc");
    if (!proc) {
        perror("opendir /proc");
        return 0;
    }
    size_t count = 0;
    struct dirent *entry;
    while ((entry = readdir(proc)) != NULL) {
        pid_t pid;
        if (!parse_positive_pid(entry->d_name, &pid))
            continue;
        if (count == MAX_PROCESSES)
            break;
        pid_t ppid;
        uint64_t start_ticks;
        if (!read_stat(pid, &ppid, &start_ticks))
            continue;
        Process *row = &processes[count++];
        memset(row, 0, sizeof(*row));
        row->pid = pid;
        row->ppid = ppid;
        row->start_ticks = start_ticks;
        snprintf(row->instance, sizeof(row->instance), "%d-%" PRIu64, pid, start_ticks);
        snprintf(row->role, sizeof(row->role), "%s", "child");
    }
    closedir(proc);
    return count;
}

static bool build_process_tree(Process *processes, size_t count, pid_t root_pid) {
    int root_index = process_index(processes, count, root_pid);
    if (root_index < 0)
        return false;
    processes[root_index].in_tree = true;
    processes[root_index].depth = 0;
    snprintf(processes[root_index].role, sizeof(processes[root_index].role), "%s", "browser");
    for (int depth = 0; depth < 64; ++depth) {
        bool added = false;
        for (size_t i = 0; i < count; ++i) {
            if (processes[i].in_tree)
                continue;
            int parent = process_index(processes, count, processes[i].ppid);
            if (parent < 0 || !processes[parent].in_tree || processes[parent].depth != depth)
                continue;
            processes[i].in_tree = true;
            processes[i].depth = depth + 1;
            if (depth == 0)
                snprintf(processes[i].role, sizeof(processes[i].role), "%s", "browser_child");
            else
                snprintf(processes[i].role, sizeof(processes[i].role), "%s", "child");
            added = true;
        }
        if (!added)
            break;
    }
    return true;
}

static SeenProcess *seen_instance(SeenProcess *seen, size_t count, const char *instance) {
    for (size_t i = 0; i < count; ++i) {
        if (strcmp(seen[i].instance, instance) == 0)
            return &seen[i];
    }
    return NULL;
}

static void emit_event(FILE *events, const char *run_id, uint64_t t_ns,
                      const char *event, const Process *process,
                      const char *parent_instance) {
    uint64_t seq = ++sequence_number;
    fprintf(events,
            "{\"schema\":\"%s\",\"run_id\":\"%s\",\"clock_id\":\"%s\","
            "\"seq\":%" PRIu64 ",\"event_id\":\"%s:%" PRIu64 "\","
            "\"t_ns\":%" PRIu64 ",\"event\":\"%s\"",
            SCHEMA, run_id, CLOCK_ID, seq, run_id, seq, t_ns, event);
    if (process) {
        fprintf(events,
                ",\"pid\":%d,\"ppid\":%d,\"process_instance\":\"%s\",\"role\":\"%s\"",
                process->pid, process->ppid, process->instance, process->role);
        if (parent_instance && *parent_instance)
            fprintf(events, ",\"parent_process_instance\":\"%s\"", parent_instance);
    }
    fputs("}\n", events);
    fflush(events);
}

static bool read_memory(pid_t pid, uint64_t *rss, uint64_t *pss, uint64_t *uss) {
    char path[80];
    snprintf(path, sizeof(path), "/proc/%d/smaps_rollup", pid);
    FILE *file = fopen(path, "r");
    if (!file)
        return false;
    bool has_rss = false, has_pss = false, has_reported_uss = false;
    bool has_private_fields = false;
    uint64_t reported_uss = 0;
    uint64_t private_clean = 0, private_dirty = 0, private_hugetlb = 0;
    char line[256];
    while (fgets(line, sizeof(line), file)) {
        unsigned long long value;
        if (sscanf(line, "Rss: %llu kB", &value) == 1) {
            *rss = value;
            has_rss = true;
        } else if (sscanf(line, "Pss: %llu kB", &value) == 1) {
            *pss = value;
            has_pss = true;
        } else if (sscanf(line, "USS: %llu kB", &value) == 1) {
            reported_uss = value;
            has_reported_uss = true;
        } else if (sscanf(line, "Private_Clean: %llu kB", &value) == 1) {
            private_clean = value;
            has_private_fields = true;
        } else if (sscanf(line, "Private_Dirty: %llu kB", &value) == 1) {
            private_dirty = value;
            has_private_fields = true;
        } else if (sscanf(line, "Private_Hugetlb: %llu kB", &value) == 1) {
            private_hugetlb = value;
            has_private_fields = true;
        }
    }
    fclose(file);
    if (has_reported_uss)
        *uss = reported_uss;
    else if (has_private_fields)
        *uss = private_clean + private_dirty + private_hugetlb;
    return has_rss && has_pss && (has_reported_uss || has_private_fields);
}

// The kernel's bulk endpoint computes all process PSS/USS values in one
// mapcount pass. On older kernels, fall back to per-process smaps_rollup.
static int read_tree_snapshot(Process *processes, size_t count, pid_t root_pid) {
    tree_snapshot_timing_present = false;
    tree_snapshot_total_ns = 0;
    tree_snapshot_resident_walk_ns = 0;
    tree_snapshot_mapcount_ns = 0;
    tree_snapshot_rollup_ns = 0;
    tree_snapshot_format_ns = 0;
    tree_snapshot_process_count = 0;
    tree_snapshot_resident_pages = 0;
    char path[96];
    snprintf(path, sizeof(path), "/proc/%d/tree_smaps_rollup", root_pid);
    FILE *file = fopen(path, "r");
    if (!file)
        return errno == ENOENT ? 0 : -1;
    char line[MAX_LINE];
    bool header_seen = false;
    while (fgets(line, sizeof(line), file)) {
        if (strncmp(line, "META ", 5) == 0) {
            unsigned long long total_ns, resident_walk_ns, mapcount_ns;
            unsigned long long rollup_ns, format_ns, process_count, resident_pages;
            if (tree_snapshot_timing_present ||
                sscanf(line,
                       "META total_ns=%llu resident_walk_ns=%llu mapcount_ns=%llu "
                       "rollup_ns=%llu format_ns=%llu process_count=%llu resident_pages=%llu",
                       &total_ns, &resident_walk_ns, &mapcount_ns, &rollup_ns,
                       &format_ns, &process_count, &resident_pages) != 7) {
                fclose(file);
                return -1;
            }
            tree_snapshot_total_ns = (uint64_t)total_ns;
            tree_snapshot_resident_walk_ns = (uint64_t)resident_walk_ns;
            tree_snapshot_mapcount_ns = (uint64_t)mapcount_ns;
            tree_snapshot_rollup_ns = (uint64_t)rollup_ns;
            tree_snapshot_format_ns = (uint64_t)format_ns;
            tree_snapshot_process_count = (uint64_t)process_count;
            tree_snapshot_resident_pages = (uint64_t)resident_pages;
            tree_snapshot_timing_present = true;
            continue;
        }
        if (!header_seen && strncmp(line, "PID ", 4) == 0) {
            header_seen = true;
            continue;
        }
        int pid, ppid;
        unsigned long long rss, pss, uss;
        if (sscanf(line, "%d %d %llu %llu %llu", &pid, &ppid, &rss, &pss, &uss) != 5) {
            fclose(file);
            return -1;
        }
        int index = process_index(processes, count, (pid_t)pid);
        if (index < 0 || !processes[index].in_tree)
            continue;
        if (processes[index].ppid != (pid_t)ppid) {
            fclose(file);
            return -1;
        }
        processes[index].rss_kb = rss;
        processes[index].pss_kb = pss;
        processes[index].uss_kb = uss;
        processes[index].memory_present = true;
    }
    fclose(file);
    if (!header_seen)
        return -1;
    for (size_t i = 0; i < count; ++i) {
        if (processes[i].in_tree && !processes[i].memory_present)
            return -1;
    }
    memory_source = "procfs-tree-smaps_rollup";
    return 1;
}

static bool add_seen(SeenProcess *seen, size_t *seen_count, const Process *process) {
    if (*seen_count >= MAX_PROCESSES)
        return false;
    SeenProcess *row = &seen[(*seen_count)++];
    memset(row, 0, sizeof(*row));
    snprintf(row->instance, sizeof(row->instance), "%s", process->instance);
    snprintf(row->role, sizeof(row->role), "%s", process->role);
    row->pid = process->pid;
    row->active = true;
    return true;
}

static bool process_in_tree(const Process *processes, size_t count, const char *instance) {
    for (size_t i = 0; i < count; ++i) {
        if (processes[i].in_tree && strcmp(processes[i].instance, instance) == 0)
            return true;
    }
    return false;
}

static int sample_tree(FILE *events, FILE *memory, FILE *errors,
                       const char *run_id, pid_t root_pid,
                       SeenProcess *seen, size_t *seen_count,
                       uint64_t sample_t_ns) {
    Process *processes = calloc(MAX_PROCESSES, sizeof(*processes));
    if (!processes)
        return -1;
    size_t count = 0;
    int endpoint = read_tree_endpoint(processes, &count, root_pid);
    bool direct_snapshot = endpoint == 1;
    if (endpoint == 0) {
        count = scan_processes(processes);
        if (!count || !build_process_tree(processes, count, root_pid)) {
            free(processes);
            return -2;
        }
    } else if (endpoint < 0) {
        free(processes);
        return -2;
    }

    for (size_t i = 0; i < *seen_count; ++i) {
        if (!seen[i].active || process_in_tree(processes, count, seen[i].instance))
            continue;
        Process exited;
        memset(&exited, 0, sizeof(exited));
        exited.pid = seen[i].pid;
        snprintf(exited.instance, sizeof(exited.instance), "%s", seen[i].instance);
        snprintf(exited.role, sizeof(exited.role), "%s", seen[i].role);
        emit_event(events, run_id, sample_t_ns, "process_exited", &exited, NULL);
        seen[i].active = false;
    }

    for (size_t i = 0; i < count; ++i) {
        Process *process = &processes[i];
        if (!process->in_tree)
            continue;
        SeenProcess *known = seen_instance(seen, *seen_count, process->instance);
        if (!known)
            continue;
        if (direct_snapshot) {
            known->role_checked_t_ns = sample_t_ns;
            if (strcmp(known->role, process->role) != 0) {
                emit_event(events, run_id, sample_t_ns, "process_role_changed", process, NULL);
                snprintf(known->role, sizeof(known->role), "%s", process->role);
            }
            continue;
        }
        if (sample_t_ns >= known->role_checked_t_ns &&
            sample_t_ns - known->role_checked_t_ns < ROLE_RECHECK_INTERVAL_NS)
            continue;
        char previous_role[sizeof(known->role)];
        snprintf(previous_role, sizeof(previous_role), "%s", known->role);
        classify_process_role(process, true);
        known->role_checked_t_ns = sample_t_ns;
        if (strcmp(previous_role, process->role) != 0) {
            emit_event(events, run_id, sample_t_ns, "process_role_changed", process, NULL);
            snprintf(known->role, sizeof(known->role), "%s", process->role);
        }
    }

    for (int depth = 0; depth < 64; ++depth) {
        for (size_t i = 0; i < count; ++i) {
            Process *process = &processes[i];
            if (!process->in_tree || process->depth != depth || seen_instance(seen, *seen_count, process->instance))
                continue;
            int parent_index = process->depth == 0 ? -1 : process_index(processes, count, process->ppid);
            const char *parent_instance = parent_index >= 0 ? processes[parent_index].instance : NULL;
            if (!direct_snapshot)
                classify_process_role(process, false);
            emit_event(events, run_id, sample_t_ns, "process_started", process, parent_instance);
            if (!add_seen(seen, seen_count, process)) {
                free(processes);
                return -3;
            }
        }
    }

    uint64_t sample_id = sample_number + 1;
    uint64_t tree_read_started_ns = monotonic_ns();
    int bulk = direct_snapshot ? 1 : read_tree_snapshot(processes, count, root_pid);
    uint64_t tree_smaps_rollup_read_ns = direct_snapshot
                                             ? tree_endpoint_read_ns
                                             : monotonic_ns() - tree_read_started_ns;
    bool complete = bulk >= 0;
    for (size_t i = 0; complete && i < count; ++i) {
        Process *process = &processes[i];
        if (!process->in_tree || bulk == 1)
            continue;
        if (!read_memory(process->pid, &process->rss_kb, &process->pss_kb, &process->uss_kb)) {
            fprintf(errors, "sample=%" PRIu64 " pid=%d process_instance=%s smaps_rollup=unavailable\n",
                    sample_id, process->pid, process->instance);
            fflush(errors);
            complete = false;
            break;
        }
        process->memory_present = true;
    }
    if (bulk < 0) {
        fprintf(errors, "sample=%" PRIu64 " pid=%d tree_smaps_rollup=unavailable_or_invalid\n",
                sample_id, root_pid);
        fflush(errors);
    }
    for (size_t i = 0; complete && i < count; ++i) {
        Process *process = &processes[i];
        if (process->in_tree && !process->memory_present)
            complete = false;
    }
    uint64_t sample_work_ns = monotonic_ns() - sample_t_ns;
    if (complete) {
        sample_number = sample_id;
        if (bulk == 0 && strcmp(memory_source, "per-pid-smaps_rollup") != 0)
            memory_source = "mixed-smaps-sources";
        for (size_t i = 0; i < count; ++i) {
            Process *process = &processes[i];
            if (!process->in_tree)
                continue;
            if (tree_snapshot_timing_present) {
                fprintf(memory,
                        "%s,%s,%" PRIu64 ",%" PRIu64 ",%d,%d,%s,%" PRIu64 ",%" PRIu64 ",%" PRIu64 ","
                        "%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 "\n",
                        run_id, CLOCK_ID, sample_id, sample_t_ns, process->pid, process->ppid,
                        process->instance, process->rss_kb, process->pss_kb, process->uss_kb,
                        tree_snapshot_total_ns, tree_snapshot_resident_walk_ns,
                        tree_snapshot_mapcount_ns, tree_snapshot_rollup_ns, tree_snapshot_format_ns,
                        tree_snapshot_process_count, tree_snapshot_resident_pages,
                        tree_smaps_rollup_read_ns, sample_work_ns);
            } else {
                fprintf(memory,
                        "%s,%s,%" PRIu64 ",%" PRIu64 ",%d,%d,%s,%" PRIu64 ",%" PRIu64 ",%" PRIu64 ","
                        "UNAVAILABLE,UNAVAILABLE,UNAVAILABLE,UNAVAILABLE,UNAVAILABLE,UNAVAILABLE,UNAVAILABLE,UNAVAILABLE,UNAVAILABLE\n",
                        run_id, CLOCK_ID, sample_id, sample_t_ns, process->pid, process->ppid,
                        process->instance, process->rss_kb, process->pss_kb, process->uss_kb);
            }
        }
        fflush(memory);
    } else {
        fprintf(errors, "sample=%" PRIu64 " memory_sample_incomplete=1\n", sample_id);
        fflush(errors);
    }
    free(processes);
    return complete ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--clock-now") == 0) {
        printf("%" PRIu64 "\n", monotonic_ns());
        return 0;
    }
    const char *run_id = NULL;
    const char *out_dir = "/root";
    uint64_t launch_ns = 0;
    int duration_seconds = 900;
    pid_t root_pid = 0;
    int interval_ms = 1000;
    bool clock_sync_enabled = false;
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--run-id") == 0 && i + 1 < argc)
            run_id = argv[++i];
        else if (strcmp(argv[i], "--root-pid") == 0 && i + 1 < argc)
            parse_positive_pid(argv[++i], &root_pid);
        else if (strcmp(argv[i], "--launch-ns") == 0 && i + 1 < argc)
            launch_ns = strtoull(argv[++i], NULL, 10);
        else if (strcmp(argv[i], "--duration-seconds") == 0 && i + 1 < argc)
            duration_seconds = atoi(argv[++i]);
        else if (strcmp(argv[i], "--interval-ms") == 0 && i + 1 < argc)
            interval_ms = atoi(argv[++i]);
        else if (strcmp(argv[i], "--out-dir") == 0 && i + 1 < argc)
            out_dir = argv[++i];
        else if (strcmp(argv[i], "--clock-sync") == 0)
            clock_sync_enabled = true;
        else {
            fprintf(stderr, "usage: proc_tree_sampler --run-id ID --root-pid PID --launch-ns NS [--duration-seconds N] [--interval-ms N] [--out-dir PATH] [--clock-sync]\n");
            return 2;
        }
    }
    if (!run_id || !*run_id || root_pid <= 0 || launch_ns == 0 || duration_seconds < 1 || interval_ms < 100) {
        fprintf(stderr, "invalid run-id, root PID, launch timestamp, duration, or interval\n");
        return 2;
    }
    for (const char *p = run_id; *p; ++p) {
        if (!( (*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') || (*p >= '0' && *p <= '9') || *p == '-' || *p == '_' || *p == '.')) {
            fprintf(stderr, "run-id contains unsupported characters\n");
            return 2;
        }
    }
    char events_path[PATH_MAX], memory_path[PATH_MAX], errors_path[PATH_MAX];
    snprintf(events_path, sizeof(events_path), "%s/lifecycle-events.jsonl", out_dir);
    snprintf(memory_path, sizeof(memory_path), "%s/memory-samples.csv", out_dir);
    snprintf(errors_path, sizeof(errors_path), "%s/memory-sampling-errors.log", out_dir);
    FILE *events = fopen(events_path, "wx");
    FILE *memory = fopen(memory_path, "wx");
    FILE *errors = fopen(errors_path, "wx");
    FILE *clock_console = clock_sync_enabled ? fopen("/dev/console", "w") : NULL;
    if (!events || !memory || !errors) {
        fprintf(stderr, "refusing to overwrite sample outputs: %s\n", out_dir);
        if (events) fclose(events);
        if (memory) fclose(memory);
        if (errors) fclose(errors);
        if (clock_console) fclose(clock_console);
        return 3;
    }
    fputs("run_id,clock_id,sample_id,t_ns,pid,ppid,process_instance,rss_kb,pss_kb,uss_kb,"
          "tree_snapshot_total_ns,tree_snapshot_resident_walk_ns,tree_snapshot_mapcount_ns,"
          "tree_snapshot_rollup_ns,tree_snapshot_format_ns,tree_snapshot_process_count,"
          "tree_snapshot_resident_pages,tree_smaps_rollup_read_ns,sample_work_ns\n", memory);
    emit_event(events, run_id, launch_ns, "browser_launch_requested", NULL, NULL);
    uint64_t start_ns = monotonic_ns();
    uint64_t end_ns = start_ns + (uint64_t)duration_seconds * 1000000000ULL;
    uint64_t next_ns = start_ns;
    SeenProcess *seen = calloc(MAX_PROCESSES, sizeof(*seen));
    if (!seen) {
        fclose(events); fclose(memory); fclose(errors);
        return 4;
    }
    size_t seen_count = 0;
    unsigned missed = 0;
    while (next_ns < end_ns) {
        struct timespec deadline = {
            .tv_sec = (time_t)(next_ns / 1000000000ULL),
            .tv_nsec = (long)(next_ns % 1000000000ULL),
        };
        while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &deadline, NULL) == EINTR) {}
        uint64_t sample_t_ns = monotonic_ns();
        if (clock_console) {
            fprintf(clock_console, "MP_METRICS_CLOCK_SYNC run_id=%s guest_t_ns=%" PRIu64 "\n",
                    run_id, sample_t_ns);
            fflush(clock_console);
        }
        int rc = sample_tree(events, memory, errors, run_id, root_pid, seen, &seen_count, sample_t_ns);
        if (rc == -2) {
            fprintf(errors, "t_ns=%" PRIu64 " chromium_root_pid=%d process_tree=unavailable\n", sample_t_ns, root_pid);
            fflush(errors);
            missed++;
        } else if (rc != 0) {
            missed++;
        }
        uint64_t sample_finished_ns = monotonic_ns();
        uint64_t sample_duration_ns = sample_finished_ns - sample_t_ns;
        if (sample_duration_ns > 1500000000ULL) {
            uint64_t overrun_ms = (uint64_t)(sample_duration_ns / 1000000ULL);
            fprintf(errors, "t_ns=%" PRIu64 " sampler_overrun_ms=%" PRIu64 "\n",
                    sample_t_ns, overrun_ms);
            fflush(errors);
            next_ns = sample_finished_ns + (uint64_t)interval_ms * 1000000ULL;
            missed++;
        } else {
            next_ns += (uint64_t)interval_ms * 1000000ULL;
            if (next_ns < sample_finished_ns)
                next_ns = sample_finished_ns;
        }
    }
    uint64_t finished_ns = monotonic_ns();
    emit_event(events, run_id, finished_ns, "memory_sampling_finished", NULL, NULL);
    uint64_t duration_ms = (uint64_t)((finished_ns - start_ns) / 1000000ULL);
    fprintf(stderr, "PROC_TREE_SAMPLER_RESULT run_id=%s samples=%" PRIu64 " processes=%zu missed=%u source=%s duration_ms=%" PRIu64 "\n",
            run_id, sample_number, seen_count, missed, memory_source, duration_ms);
    char status_path[PATH_MAX];
    snprintf(status_path, sizeof(status_path), "%s/proc-tree-sampler.status", out_dir);
    FILE *status = fopen(status_path, "wx");
    if (status) {
        fprintf(status,
                "run_id=%s\nresult=%s\nsamples=%" PRIu64 "\nprocess_instances=%zu\nmissed=%u\nmemory_source=%s\nfinished_t_ns=%" PRIu64 "\n",
                run_id, missed == 0 && sample_number > 0 ? "PASS" : "FAIL",
                sample_number, seen_count, missed, memory_source, finished_ns);
        fclose(status);
    } else {
        fprintf(errors, "status_file_write_failed errno=%d\n", errno);
        fflush(errors);
        missed++;
    }
    free(seen);
    if (clock_console)
        fclose(clock_console);
    fclose(events);
    fclose(memory);
    fclose(errors);
    return missed == 0 && sample_number > 0 ? 0 : 5;
}
