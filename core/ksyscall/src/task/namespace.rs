//! Namespace-changing syscalls used by Chromium's sandbox bootstrap.

use kerrno::{KError, KResult};
use kprocess::current_user_process;
use kns::{CloneNsError, NamespaceFlags, NamespaceFsContext};

/// Linux unshare syscall for namespace types implemented by kns.
///
/// The namespace proxy is replaced only after the requested clone and
/// filesystem retargeting succeed, so a failed request leaves the caller in
/// its original namespaces.
pub fn sys_unshare(flags: u64) -> KResult<isize> {
    let flags = NamespaceFlags::from_bits(flags).ok_or(KError::InvalidInput)?;
    if flags.is_empty() {
        return Ok(0);
    }

    let process = current_user_process();
    let parent = process.nsproxy()?;
    let fs_context = process.fs_context()?;
    let mut fs = fs_context.lock();
    let child = parent
        .clone_for_child(flags, NamespaceFsContext::Private(&mut fs))
        .map_err(|error| match error {
            CloneNsError::InvalidFlagCombination => KError::InvalidInput,
            CloneNsError::Unimplemented => KError::OperationNotSupported,
            CloneNsError::Mount(_) => KError::OperationNotSupported,
        })?;
    process.replace_nsproxy(child)?;
    if flags.contains(NamespaceFlags::NEWUSER) {
        let thread = kprocess::current_user_thread();
        let mut credentials = thread.prepare_creds();
        let parent_user_namespace = credentials.user_namespace();
        credentials.set_user_namespace(kcred::UserNamespace::new_child(
            parent_user_namespace,
        ));
        thread.commit_creds(credentials);
        // A task that creates a user namespace receives a full capability
        // set in that namespace, independently of its mapped numeric UID.
        thread.set_capabilities_empty(false);
    }
    Ok(0)
}

/// setns is exposed explicitly so Chromium receives a stable EOPNOTSUPP
/// result until namespace file descriptors are implemented.
///
/// Returning a typed unsupported error is preferable to silently accepting a
/// request and leaving the renderer in the wrong namespace.
pub fn sys_setns(_fd: i32, _nstype: u32) -> KResult<isize> {
    Err(KError::OperationNotSupported)
}
