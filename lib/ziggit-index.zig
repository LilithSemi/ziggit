//! Reads and writes `.git/index`, git's staged snapshot of the working tree.
//! Versions 2 and 3 only; the writer emits v2 and rejects extended flag bits.

const index_mod = @import("ziggit-index/Index.zig");
pub const Stage = index_mod.Stage;
pub const Entry = index_mod.Entry;
pub const Error = index_mod.Error;
pub const Index = index_mod.Index;
pub const write = index_mod.write;

test {
    _ = index_mod;
}
