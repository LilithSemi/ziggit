//! Object ids: git's content-addressed identifiers, and the hashers that
//! produce them.
//!
//! This module imports nothing else in ziggit. Every other module imports
//! it.

const oid_mod = @import("ziggit-oid/Oid.zig");
pub const Format = oid_mod.Format;
pub const Oid = oid_mod.Oid;

const hasher_mod = @import("ziggit-oid/Hasher.zig");
pub const Hasher = hasher_mod.Hasher;

test {
    _ = oid_mod;
    _ = hasher_mod;
}
