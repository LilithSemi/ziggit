//! The packfile format alone: the "PACK" header and delta-compressed entry
//! stream, delta chain resolution, and `.idx` version 2 reading and
//! writing.
//!
//! This module holds no database policy: no `.git/objects` layout, no
//! alternates, and no loose objects. `ziggit-odb`, in a later task, is
//! what decides which pack to open and which offset or id to ask this
//! module for.

const std = @import("std");

const pack_mod = @import("ziggit-pack/Pack.zig");
pub const EntryType = pack_mod.EntryType;
pub const Pack = pack_mod.Pack;

const delta_mod = @import("ziggit-pack/delta.zig");
pub const delta = delta_mod.delta;

const index_mod = @import("ziggit-pack/Index.zig");
pub const Index = index_mod.Index;

const index_writer_mod = @import("ziggit-pack/index_writer.zig");
pub const writeIndex = index_writer_mod.writeIndex;

/// Test-only surface, kept apart from the real API above so the intent is
/// explicit at the call site. Exported so a later module's own tests (a
/// fetch strategy that must feed `writeIndex` a real received pack, for
/// instance) can build one without duplicating this file's varint and
/// zlib framing by hand. Zig's module boundaries require a real export for
/// a sibling module's tests to reach these; there is no test-only import
/// path.
pub const testing = struct {
    pub const TestEntry = pack_mod.TestEntry;
    pub const BuiltPack = pack_mod.BuiltPack;
    pub const buildTestPack = pack_mod.buildTestPack;
};

test {
    _ = pack_mod;
    _ = delta_mod;
    _ = index_mod;
    _ = index_writer_mod;
}
