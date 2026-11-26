// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 KylinSoft Co., Ltd. <https://www.kylinos.cn/>
// See LICENSES for license details.

//! Namespace identity and user namespace ownership.

use alloc::sync::Arc;
use core::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};

use klazy::Once;

static INIT_USER_NS: Once<Arc<UserNamespace>> = Once::new();

/// Namespace identifier allocated from a kernel-wide atomic counter.
///
/// This is used for namespace identities that are externally rendered as
/// `/proc/[pid]/ns/*` inode-style identifiers.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
pub struct NamespaceId(u64);

impl Default for NamespaceId {
    fn default() -> Self {
        Self::new()
    }
}

impl NamespaceId {
    /// Allocates the next namespace ID without allocating memory.
    ///
    /// The counter starts at one and uses relaxed atomic increment. IDs are
    /// distinct until the `u64` counter wraps; exhaustion is not checked and
    /// allocation does not synchronize unrelated namespace state.
    /// An ID is not an authorization token.
    pub fn new() -> Self {
        static NEXT_ID: AtomicU64 = AtomicU64::new(1);
        Self(NEXT_ID.fetch_add(1, Ordering::Relaxed))
    }

    /// Returns the raw ID value.
    pub fn as_u64(&self) -> u64 {
        self.0
    }
}

impl core::fmt::Display for NamespaceId {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// User-namespace identity and parentage, without ID mapping or privilege policy.
///
/// The current public API exposes only the initial namespace. `Cred` does not
/// store a user namespace, and credential privilege checks do not consult this type.
#[derive(Debug)]
pub struct UserNamespace {
    id: NamespaceId,
    parent: Option<Arc<UserNamespace>>,
    uid_map_written: AtomicBool,
    gid_map_written: AtomicBool,
    uid_inside: AtomicU32,
    uid_outside: AtomicU32,
    uid_length: AtomicU32,
    gid_inside: AtomicU32,
    gid_outside: AtomicU32,
    gid_length: AtomicU32,
    setgroups_denied: AtomicBool,
}

impl UserNamespace {
    fn new_root() -> Self {
        Self {
            id: NamespaceId::new(),
            parent: None,
            uid_map_written: AtomicBool::new(true),
            gid_map_written: AtomicBool::new(true),
            uid_inside: AtomicU32::new(0),
            uid_outside: AtomicU32::new(0),
            uid_length: AtomicU32::new(u32::MAX),
            gid_inside: AtomicU32::new(0),
            gid_outside: AtomicU32::new(0),
            gid_length: AtomicU32::new(u32::MAX),
            setgroups_denied: AtomicBool::new(false),
        }
    }

    /// Creates a child user namespace owned by the supplied parent.
    pub fn new_child(parent: Arc<UserNamespace>) -> Arc<UserNamespace> {
        Arc::new(Self {
            id: NamespaceId::new(),
            parent: Some(parent),
            uid_map_written: AtomicBool::new(false),
            gid_map_written: AtomicBool::new(false),
            uid_inside: AtomicU32::new(0),
            uid_outside: AtomicU32::new(0),
            uid_length: AtomicU32::new(0),
            gid_inside: AtomicU32::new(0),
            gid_outside: AtomicU32::new(0),
            gid_length: AtomicU32::new(0),
            setgroups_denied: AtomicBool::new(false),
        })
    }

    /// Returns the namespace ID.
    pub fn id(&self) -> NamespaceId {
        self.id
    }

    /// Returns the parent user namespace, if this is not the root user namespace.
    pub fn parent(&self) -> Option<&Arc<UserNamespace>> {
        self.parent.as_ref()
    }

    /// Records a single contiguous UID map. The first write wins.
    pub fn write_uid_map(&self, inside: u32, outside: u32, length: u32) -> bool {
        if length == 0 || self.uid_map_written.swap(true, Ordering::AcqRel) {
            return false;
        }
        self.uid_inside.store(inside, Ordering::Release);
        self.uid_outside.store(outside, Ordering::Release);
        self.uid_length.store(length, Ordering::Release);
        true
    }

    /// Records a single contiguous GID map. The first write wins.
    pub fn write_gid_map(&self, inside: u32, outside: u32, length: u32) -> bool {
        if length == 0 || self.gid_map_written.swap(true, Ordering::AcqRel) {
            return false;
        }
        self.gid_inside.store(inside, Ordering::Release);
        self.gid_outside.store(outside, Ordering::Release);
        self.gid_length.store(length, Ordering::Release);
        true
    }

    /// Returns the current UID map as a Linux procfs line.
    pub fn uid_map_line(&self) -> (u32, u32, u32) {
        (self.uid_inside.load(Ordering::Acquire), self.uid_outside.load(Ordering::Acquire), self.uid_length.load(Ordering::Acquire))
    }

    /// Returns the current GID map as a Linux procfs line.
    pub fn gid_map_line(&self) -> (u32, u32, u32) {
        (self.gid_inside.load(Ordering::Acquire), self.gid_outside.load(Ordering::Acquire), self.gid_length.load(Ordering::Acquire))
    }

    /// Marks supplementary-group changes as denied for this user namespace.
    pub fn deny_setgroups(&self) {
        self.setgroups_denied.store(true, Ordering::Release);
    }

    /// Returns whether supplementary groups are denied.
    pub fn setgroups_denied(&self) -> bool {
        self.setgroups_denied.load(Ordering::Acquire)
    }
}

/// Returns a shared reference to the lazily allocated initial user namespace.
///
/// Its parent is `None`; repeated calls clone the same `Arc`. Initialization
/// requires an allocator, may spin on a concurrent initializer, and must not
/// be re-entered. No child-namespace constructor or ID mapping is provided.
///
/// # Panics
///
/// Panics if an earlier initialization unwound and poisoned the internal
/// [`klazy::Once`]. Allocation failure follows the allocator's failure policy.
pub fn initial_user_namespace() -> Arc<UserNamespace> {
    Arc::clone(INIT_USER_NS.call_once(|| Arc::new(UserNamespace::new_root())))
}

#[cfg(unittest)]
mod tests {
    use unittest::{assert, def_test};

    use super::*;

    #[def_test]
    fn test_namespace_id_monotonic() {
        let id1 = NamespaceId::new();
        let id2 = NamespaceId::new();
        let id3 = NamespaceId::new();
        assert!(id2.as_u64() > id1.as_u64());
        assert!(id3.as_u64() > id2.as_u64());
    }

    #[def_test]
    fn test_namespace_id_display() {
        let id = NamespaceId::new();
        let displayed = alloc::format!("{}", id);
        assert!(!displayed.is_empty());
    }

    #[def_test]
    fn test_initial_user_namespace_is_singleton() {
        let first = initial_user_namespace();
        let second = initial_user_namespace();
        assert!(Arc::ptr_eq(&first, &second));
    }
}
