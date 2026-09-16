//! Refs on disk: loose ref files, `packed-refs`, symrefs, compare-and-swap
//! updates, and the reflog. This is the first ziggit module that touches
//! the filesystem; the conventions it sets here (a lock file then an
//! atomic rename, every fault routed through a `Diagnostic` instead of
//! printed) are the ones every later module that does I/O follows.
//!
//! This module does not import `ziggit-object`: here, a ref is only an id
//! and a name. Peeling a tag object to find the commit it names is the
//! caller's job, not this module's.

const store_mod = @import("ziggit-refs/Store.zig");
pub const Store = store_mod.Store;
pub const Target = store_mod.Target;
pub const Reference = store_mod.Reference;

const packed_mod = @import("ziggit-refs/packed.zig");
const loose_mod = @import("ziggit-refs/loose.zig");
const reflog_mod = @import("ziggit-refs/reflog.zig");

test {
    _ = store_mod;
    _ = packed_mod;
    _ = loose_mod;
    _ = reflog_mod;
}
