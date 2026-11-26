// SPDX-License-Identifier: Apache-2.0
//! Classic BPF core for seccomp. Installation and syscall dispatch are not wired here.
extern crate alloc;

use alloc::vec;
use alloc::vec::Vec;
use alloc::sync::Arc;

/// Linux action mask; the low 16 bits carry action-specific data.
pub const ACTION_MASK: u32 = 0xffff_0000;
/// Terminate the current thread with SIGSYS.
pub const RET_KILL_THREAD: u32 = 0x0000_0000;
/// Terminate the whole process with SIGSYS.
pub const RET_KILL_PROCESS: u32 = 0x8000_0000;
/// Deliver SIGSYS with seccomp metadata.
pub const RET_TRAP: u32 = 0x0003_0000;
/// Return an errno to the caller.
pub const RET_ERRNO: u32 = 0x0005_0000;
/// Return to a ptracer, or ENOSYS when no tracer handles the event.
pub const RET_TRACE: u32 = 0x7ff0_0000;
/// Permit the system call and request an audit record.
pub const RET_LOG: u32 = 0x7ffc_0000;
/// Linux's permit action.
pub const RET_ALLOW: u32 = 0x7fff_0000;
/// Maximum instructions across an entire filter path, including penalties.
pub const MAX_PATH_INSNS: usize = 32768;

/// The information made available to a seccomp filter for one system call.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SeccompData {
    /// System call number.
    pub nr: i32,
    /// Linux AUDIT_ARCH value.
    pub arch: u32,
    /// Instruction pointer at system call entry.
    pub instruction_pointer: u64,
    /// Six raw system call arguments.
    pub args: [u64; 6],
}

impl SeccompData {
    /// Encode the Linux UAPI layout using native byte order.
    pub fn to_bytes(self) -> [u8; 64] {
        let mut data = [0; 64];
        data[0..4].copy_from_slice(&self.nr.to_ne_bytes());
        data[4..8].copy_from_slice(&self.arch.to_ne_bytes());
        data[8..16].copy_from_slice(&self.instruction_pointer.to_ne_bytes());
        for (index, argument) in self.args.iter().enumerate() {
            let start = 16 + index * 8;
            data[start..start + 8].copy_from_slice(&argument.to_ne_bytes());
        }
        data
    }
}

/// One Linux classic BPF instruction in `sock_filter` layout.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct Insn {
    /// Instruction opcode.
    pub code: u16,
    /// Forward offset for a true condition.
    pub jt: u8,
    /// Forward offset for a false condition.
    pub jf: u8,
    /// Immediate value, memory index, or forward offset.
    pub k: u32,
}

/// Reasons a filter cannot be accepted.
#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    /// Empty or oversized program.
    Length,
    /// Opcode or immediate value is not supported.
    Instruction,
    /// A data load is misaligned or outside `seccomp_data`.
    DataOffset,
    /// Scratch index is invalid or not initialized on every path.
    Scratch,
    /// A branch or fallthrough escapes the program.
    Jump,
    /// An immediate divisor is zero.
    DivisionByZero,
    /// The return action is unsupported by syscall dispatch.
    Action,
    /// The final instruction is not a return.
    MissingReturn,
}

/// Verify a forward-only seccomp classic BPF program. Scratch words must be
/// initialized on every path reaching a load. Unsupported encodings fail closed.
fn verify(program: &[Insn]) -> Result<(), Error> {
    if program.is_empty() || program.len() > 4096 {
        return Err(Error::Length);
    }
    // `None` means unreachable; intersections retain definite initialization.
    let mut incoming: Vec<Option<u16>> = vec![None; program.len()];
    incoming[0] = Some(0);
    for (pc, ins) in program.iter().enumerate() {
        let mut mask = incoming[pc].unwrap_or(0);
        let reachable = incoming[pc].is_some();
        let mut successors = [None, None];
        match ins.code {
            0x00 | 0x01 | 0x80 | 0x81 | 0x07 | 0x87 => {}
            0x20 => {
                if ins.k > 60 || ins.k % 4 != 0 { return Err(Error::DataOffset); }
            }
            0x60 | 0x61 => {
                if ins.k >= 16 || (reachable && mask & (1 << ins.k) == 0) {
                    return Err(Error::Scratch);
                }
            }
            0x02 | 0x03 => {
                if ins.k >= 16 { return Err(Error::Scratch); }
                mask |= 1 << ins.k;
            }
            0x04 | 0x0c | 0x14 | 0x1c | 0x24 | 0x2c | 0x34 | 0x3c |
            0x44 | 0x4c | 0x54 | 0x5c | 0x64 | 0x6c | 0x74 | 0x7c |
            0x84 | 0xa4 | 0xac => {
                if ins.code == 0x34 && ins.k == 0 {
                    return Err(Error::DivisionByZero);
                }
                if matches!(ins.code, 0x64 | 0x74) && ins.k >= 32 {
                    return Err(Error::Instruction);
                }
            }
            0x05 => {
                successors[0] = Some(pc.checked_add(1).and_then(|p| p.checked_add(ins.k as usize)).ok_or(Error::Jump)?);
            }
            0x15 | 0x1d | 0x25 | 0x2d | 0x35 | 0x3d | 0x45 | 0x4d => {
                successors[0] = pc.checked_add(1 + ins.jt as usize);
                successors[1] = pc.checked_add(1 + ins.jf as usize);
            }
            0x06 => {
                if !action_is_supported(ins.k) { return Err(Error::Action); }
                continue;
            }
            0x16 => continue,
            _ => return Err(Error::Instruction),
        }
        if successors == [None, None] {
            successors[0] = pc.checked_add(1);
        }
        for target in successors.into_iter().flatten() {
            if target >= program.len() { return Err(Error::Jump); }
            if reachable {
                incoming[target] = Some(incoming[target].map_or(mask, |old| old & mask));
            }
        }
    }
    if !matches!(program.last().map(|ins| ins.code), Some(0x06 | 0x16)) {
        return Err(Error::MissingReturn);
    }
    Ok(())
}

/// Return actions currently implemented by the seccomp syscall path.
pub fn action_is_supported(value: u32) -> bool {
    matches!(
        value & ACTION_MASK,
        RET_KILL_THREAD | RET_KILL_PROCESS | RET_TRAP | RET_ERRNO | RET_TRACE | RET_LOG | RET_ALLOW
    )
}

/// An immutable program that has passed classic BPF validation.
pub struct VerifiedProgram(Vec<Insn>);

impl VerifiedProgram {
    /// Validate and own a program before allowing it to execute.
    pub fn new(program: Vec<Insn>) -> Result<Self, Error> {
        verify(&program)?;
        Ok(Self(program))
    }

    /// Execute on the 64-byte Linux `seccomp_data` structure.
    pub fn run(&self, data: &[u8; 64]) -> u32 {
        execute(&self.0, data)
    }
}

/// Immutable filter node; sharing the previous node supports fork inheritance.
pub struct FilterChain {
    program: VerifiedProgram,
    previous: Option<Arc<FilterChain>>,
    path_insns: usize,
}

impl FilterChain {
    /// Add a verified filter while enforcing Linux's per-path instruction limit.
    pub fn append(previous: Option<Arc<Self>>, program: VerifiedProgram) -> Result<Arc<Self>, Error> {
        let previous_cost = match &previous {
            Some(node) => node.path_insns.checked_add(4).ok_or(Error::Length)?,
            None => 0,
        };
        let path_insns = previous_cost.checked_add(program.0.len()).ok_or(Error::Length)?;
        if path_insns > MAX_PATH_INSNS {
            return Err(Error::Length);
        }
        Ok(Arc::new(Self { program, previous, path_insns }))
    }

    /// Evaluate newest to oldest; preserve the newest result for equal actions.
    pub fn run(&self, data: &SeccompData) -> u32 {
        let bytes = data.to_bytes();
        let mut result = RET_ALLOW;
        let mut current = Some(self);
        while let Some(node) = current {
            let value = node.program.run(&bytes);
            if ((value & ACTION_MASK) as i32) < ((result & ACTION_MASK) as i32) {
                result = value;
            }
            current = node.previous.as_deref();
        }
        result
    }

    /// Return the total charged instructions in this path.
    pub fn path_insns(&self) -> usize {
        self.path_insns
    }
}

fn execute(program: &[Insn], data: &[u8; 64]) -> u32 {
    let (mut a, mut x, mut pc) = (0u32, 0u32, 0usize);
    let mut mem = [0u32; 16];
    while let Some(ins) = program.get(pc) {
        let source = if ins.code & 8 != 0 { x } else { ins.k };
        match ins.code {
            0x00 => a = ins.k,
            0x01 => x = ins.k,
            0x20 => { let i = ins.k as usize; a = u32::from_ne_bytes(data[i..i + 4].try_into().unwrap()); }
            0x60 => a = mem[ins.k as usize],
            0x61 => x = mem[ins.k as usize],
            0x80 => a = 64,
            0x81 => x = 64,
            0x02 => mem[ins.k as usize] = a,
            0x03 => mem[ins.k as usize] = x,
            0x04 | 0x0c => a = a.wrapping_add(source),
            0x14 | 0x1c => a = a.wrapping_sub(source),
            0x24 | 0x2c => a = a.wrapping_mul(source),
            0x34 | 0x3c => { if source == 0 { return 0; } a /= source; }
            0x44 | 0x4c => a |= source,
            0x54 | 0x5c => a &= source,
            0x64 | 0x6c => a = a.wrapping_shl(source & 31),
            0x74 | 0x7c => a = a.wrapping_shr(source & 31),
            0x84 => a = a.wrapping_neg(),
            0xa4 | 0xac => a ^= source,
            0x05 => { pc += ins.k as usize + 1; continue; }
            0x15 | 0x1d | 0x25 | 0x2d | 0x35 | 0x3d | 0x45 | 0x4d => {
                let yes = match ins.code & 0xf0 {
                    0x10 => a == source, 0x20 => a > source,
                    0x30 => a >= source, 0x40 => a & source != 0, _ => false,
                };
                pc += 1 + if yes { ins.jt as usize } else { ins.jf as usize };
                continue;
            }
            0x06 => return ins.k,
            0x16 => return a,
            0x07 => x = a,
            0x87 => a = x,
            _ => return 0,
        }
        pc += 1;
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    fn i(code: u16, jt: u8, jf: u8, k: u32) -> Insn { Insn { code, jt, jf, k } }

    #[test]
    fn seccomp_syscall_comparison() {
        let p = [i(0x20, 0, 0, 0), i(0x15, 0, 1, 52), i(0x06, 0, 0, 0x0005_0001), i(0x06, 0, 0, 0x7fff_0000)];
        let program = VerifiedProgram::new(p.to_vec()).unwrap();
        let mut data = [0; 64];
        data[..4].copy_from_slice(&52u32.to_ne_bytes());
        assert_eq!(program.run(&data), 0x0005_0001);
        data[..4].copy_from_slice(&63u32.to_ne_bytes());
        assert_eq!(program.run(&data), 0x7fff_0000);
    }

    #[test]
    fn rejects_uninitialized_scratch_and_bad_branches() {
        assert_eq!(verify(&[i(0x60, 0, 0, 0), i(0x16, 0, 0, 0)]), Err(Error::Scratch));
        assert_eq!(verify(&[i(0x15, 0, 1, 0), i(0x02, 0, 0, 0), i(0x60, 0, 0, 0), i(0x16, 0, 0, 0)]), Err(Error::Scratch));
        assert_eq!(verify(&[i(0x05, 0, 0, 9), i(0x06, 0, 0, 0)]), Err(Error::Jump));
        assert_eq!(verify(&[i(0x20, 0, 0, 63), i(0x16, 0, 0, 0)]), Err(Error::DataOffset));
    }

    #[test]
    fn handles_runtime_zero_divisor() {
        let p = [i(0x01, 0, 0, 0), i(0x3c, 0, 0, 0), i(0x16, 0, 0, 0)];
        let program = VerifiedProgram::new(p.to_vec()).unwrap();
        assert_eq!(program.run(&[0; 64]), 0);
    }

    #[test]
    fn seccomp_rejects_modulo_and_masks_register_shift() {
        assert_eq!(verify(&[i(0x94, 0, 0, 1), i(0x16, 0, 0, 0)]), Err(Error::Instruction));
        let p = [i(0x00, 0, 0, 1), i(0x01, 0, 0, 33), i(0x6c, 0, 0, 0), i(0x16, 0, 0, 0)];
        assert_eq!(VerifiedProgram::new(p.to_vec()).unwrap().run(&[0; 64]), 2);
    }

    #[test]
    fn data_layout_and_chain_priority() {
        let data = SeccompData { nr: 52, arch: 0xc000_00b7, instruction_pointer: 0x1234, args: [1, 2, 3, 4, 5, 6] };
        let bytes = data.to_bytes();
        assert_eq!(u32::from_ne_bytes(bytes[4..8].try_into().unwrap()), 0xc000_00b7);
        assert_eq!(u64::from_ne_bytes(bytes[56..64].try_into().unwrap()), 6);
        let old = FilterChain::append(None, VerifiedProgram::new(vec![i(0x06, 0, 0, 0x0005_000d)]).unwrap()).unwrap();
        let new = FilterChain::append(Some(old), VerifiedProgram::new(vec![i(0x06, 0, 0, 0x0005_0001)]).unwrap()).unwrap();
        assert_eq!(new.path_insns(), 6);
        assert_eq!(new.run(&data), 0x0005_0001);
        let kill = FilterChain::append(Some(new), VerifiedProgram::new(vec![i(0x06, 0, 0, 0x8000_0000)]).unwrap()).unwrap();
        assert_eq!(kill.run(&data), 0x8000_0000);
    }

    #[test]
    fn chain_limit_includes_previous_filter_penalty() {
        let make = || VerifiedProgram::new(vec![i(0x06, 0, 0, RET_ALLOW); 4096]).unwrap();
        let mut chain = None;
        for _ in 0..7 {
            chain = Some(FilterChain::append(chain, make()).unwrap());
        }
        assert!(matches!(FilterChain::append(chain, make()), Err(Error::Length)));
    }
}
