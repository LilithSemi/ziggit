//! The object database: the policy layer that decides which backend, loose
//! or packed, answers a read, and that owns alternates and the environment
//! redirection a sandboxed consumer depends on.
//!
//! This module holds no repository discovery and no ref resolution; it
//! only ever sees an already-open objects directory and object ids.

const odb_mod = @import("ziggit-odb/Odb.zig");
pub const Odb = odb_mod.Odb;

const loose_backend_mod = @import("ziggit-odb/loose_backend.zig");
const pack_backend_mod = @import("ziggit-odb/pack_backend.zig");
const alternates_mod = @import("ziggit-odb/alternates.zig");

const tree_builder_mod = @import("ziggit-odb/TreeBuilder.zig");
pub const writeTreeFromIndex = tree_builder_mod.writeTreeFromIndex;

test {
    _ = odb_mod;
    _ = loose_backend_mod;
    _ = pack_backend_mod;
    _ = alternates_mod;
    _ = tree_builder_mod;
}
