// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

use alloc::{borrow::ToOwned, fmt, string::String};

use kerrno::KResult;
use ktask::{TaskInner, TaskState};

use crate::AsThread;

/// Represents the `/proc/[pid]/stat` file.
#[derive(Default)]
pub struct TaskStat {
    /// Process ID.
    pub pid: u32,
    /// Filename of the executable (limited to 16 chars).
    pub comm: String,
    /// Process state.
    pub state: char,
    /// Parent process ID.
    pub ppid: u32,
    /// Process group ID.
    pub pgrp: u32,
    /// Session ID.
    pub session: u32,
    /// Controlling terminal of the process.
    pub tty_nr: u32,
    /// Foreground process group ID of the terminal.
    pub tpgid: u32,
    /// Kernel flags for the process.
    pub flags: u32,
    /// Minor faults the process has made.
    pub minflt: u64,
    /// Minor faults made by the process's waited-for children.
    pub cminflt: u64,
    /// Major faults the process has made.
    pub majflt: u64,
    /// Major faults made by the process's waited-for children.
    pub cmajflt: u64,
    /// User mode time in jiffies.
    pub utime: u64,
    /// Kernel mode time in jiffies.
    pub stime: u64,
    /// User mode time of waited-for children in jiffies.
    pub cutime: u64,
    /// Kernel mode time of waited-for children in jiffies.
    pub cstime: u64,
    /// Process priority.
    pub priority: i32,
    /// Nice value.
    pub nice: i32,
    /// Number of threads in this process.
    pub num_threads: u32,
    /// Obsolete (always 0 in Linux).
    pub itrealvalue: u32,
    /// Start time since system boot (jiffies).
    pub starttime: u64,
    /// Virtual memory size in bytes.
    pub vsize: u64,
    /// Resident set size.
    pub rss: i64,
    /// Soft limit for RSS.
    pub rsslim: u64,
    /// Address above which program text can run.
    pub start_code: u64,
    /// Address below which program text can run.
    pub end_code: u64,
    /// Address of the start of the stack.
    pub start_stack: u64,
    /// Current value of ESP (obsolete).
    pub kstk_esp: u64,
    /// Current value of EIP (obsolete).
    pub kstk_eip: u64,
    /// Pending signals.
    pub signal: u32,
    /// Blocked signals.
    pub blocked: u32,
    /// Ignored signals.
    pub sigignore: u32,
    /// Caught signals.
    pub sigcatch: u32,
    /// Channel in which the process is waiting.
    pub wchan: u64,
    /// Swapped-out memory (obsolete).
    pub nswap: u64,
    /// Swapped-out memory of children (obsolete).
    pub cnswap: u64,
    /// Signal sent to parent when we die.
    pub exit_signal: u8,
    /// Last CPU number executed on.
    pub processor: u32,
    /// Realtime scheduling priority.
    pub rt_priority: u32,
    /// Scheduling policy.
    pub policy: u32,
    /// Aggregated block I/O delays.
    pub delayacct_blkio_ticks: u64,
    /// Guest time of the process.
    pub guest_time: u64,
    /// Guest time of children.
    pub cguest_time: u64,
    /// Address above which initialized and uninitialized data are placed.
    pub start_data: u64,
    /// Address below which initialized and uninitialized data are placed.
    pub end_data: u64,
    /// Address above which heap can be expanded with `brk`.
    pub start_brk: u64,
    /// Address above which command-line arguments are placed.
    pub arg_start: u64,
    /// Address below which command-line arguments are placed.
    pub arg_end: u64,
    /// Address above which environment is placed.
    pub env_start: u64,
    /// Address below which environment is placed.
    pub env_end: u64,
    /// The thread's exit status.
    pub exit_code: i32,
}

impl TaskStat {
    /// Creates a new [`TaskStat`] from a [`TaskInner`].
    ///
    /// # Errors
    ///
    /// The current implementation always returns `Ok` after constructing the
    /// snapshot; this Result is retained for the public interface.
    ///
    /// # Panics
    ///
    /// Panics when the task has no Thread runtime, or when truncating a name at
    /// byte 16 would split a UTF-8 character.
    pub fn from_thread(task: &TaskInner) -> KResult<Self> {
        let thread = task.as_thread();
        let proc = thread.process();

        let pid = proc.pid();
        let comm = task.name();
        let comm = comm[..comm.len().min(16)].to_owned();
        let state = match task.state() {
            TaskState::Running | TaskState::Ready => 'R',
            TaskState::Blocked => 'S',
            TaskState::Exited => 'Z',
        };
        let ppid = proc.parent().map_or(0, |p| p.pid());
        let pgrp = proc.group().pgid();
        let session = proc.group().session().sid();
        let nice = thread.nice();
        // MM 快照：只在这里拿一次锁，拿到的是 Copy 快照，随后立刻释放；
        // 格式化在锁外进行（设计文档的锁定契约）。
        let mm_usage = proc
            .address_space()
            .ok()
            .map(|aspace| aspace.lock().memory_usage());
        Ok(Self {
            pid,
            comm: comm.to_owned(),
            state,
            ppid,
            pgrp,
            session,
            // Linux proc stat starttime uses USER_HZ (100 Hz here).
            starttime: task.start_time_ns() / 10_000_000,
            priority: nice.proc_stat_priority(),
            nice: nice.as_i32(),
            num_threads: proc.thread_count() as u32,
            exit_signal: proc.exit_signal().map_or(0, |signo| signo as u8),
            exit_code: proc.exit_code(),
            // vsize 按字节、rss 按页 —— Linux `/proc/<pid>/stat` 的原生单位。
            vsize: mm_usage.map_or(0, |u| u.virtual_pages * memaddr::PAGE_SIZE_4K as u64),
            rss: mm_usage.map_or(0, |u| u.resident_pages() as i64),
            // CPU 时间按 10 ms 一个 jiffy 折算，与 Linux 默认 100 Hz 对齐。
            // 注意：本内核拿不到「当前是否用户态」，全部计入 utime，stime 恒 0，
            // 这是总量统计而非 Linux 精确语义（见 TaskInner::cpu_time_ns_nanos）。
            utime: task.cpu_time_nanos() / 10_000_000,
            stime: 0,
            ..Default::default()
        })
    }
}

impl fmt::Display for TaskStat {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let Self {
            pid,
            comm,
            state,
            ppid,
            pgrp,
            session,
            tty_nr,
            tpgid,
            flags,
            minflt,
            cminflt,
            majflt,
            cmajflt,
            utime,
            stime,
            cutime,
            cstime,
            priority,
            nice,
            num_threads,
            itrealvalue,
            starttime,
            vsize,
            rss,
            rsslim,
            start_code,
            end_code,
            start_stack,
            kstk_esp,
            kstk_eip,
            signal,
            blocked,
            sigignore,
            sigcatch,
            wchan,
            nswap,
            cnswap,
            exit_signal,
            processor,
            rt_priority,
            policy,
            delayacct_blkio_ticks,
            guest_time,
            cguest_time,
            start_data,
            end_data,
            start_brk,
            arg_start,
            arg_end,
            env_start,
            env_end,
            exit_code,
        } = self;
        writeln!(
            f,
            "{pid} ({comm}) {state} {ppid} {pgrp} {session} {tty_nr} {tpgid} {flags} {minflt} \
             {cminflt} {majflt} {cmajflt} {utime} {stime} {cutime} {cstime} {priority} {nice} \
             {num_threads} {itrealvalue} {starttime} {vsize} {rss} {rsslim} {start_code} \
             {end_code} {start_stack} {kstk_esp} {kstk_eip} {signal} {blocked} {sigignore} \
             {sigcatch} {wchan} {nswap} {cnswap} {exit_signal} {processor} {rt_priority} {policy} \
             {delayacct_blkio_ticks} {guest_time} {cguest_time} {start_data} {end_data} \
             {start_brk} {arg_start} {arg_end} {env_start} {env_end} {exit_code}",
        )
    }
}

#[cfg(unittest)]
mod tests_stat {
    use unittest::def_test;

    use super::TaskStat;

    #[def_test]
    fn test_taskstat_display_default() {
        let stat = TaskStat::default();
        let text = alloc::format!("{stat}");
        let text = text.trim_end();
        assert!(text.starts_with("0 ("));
        assert!(text.ends_with(" 0"));
    }

    #[def_test]
    fn test_taskstat_display_custom() {
        let stat = TaskStat {
            pid: 7,
            comm: "init".into(),
            state: 'R',
            priority: 10,
            nice: -10,
            starttime: 1234,
            ..Default::default()
        };
        let text = alloc::format!("{stat}");
        assert!(text.contains(" 10 -10 "));
        let fields = text.split(") ").nth(1).unwrap().split_whitespace().collect::<alloc::vec::Vec<_>>();
        assert_eq!(fields[19], "1234");
    }
}
