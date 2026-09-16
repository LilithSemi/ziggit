//! Reads `.git/index`, git's staged snapshot of the working tree. Versions
//! 2 and 3 only; this module holds no write path, since a consumer only
//! needs to see what a dirty working tree looks like.

const index_mod = @import("ziggit-index/Index.zig");
pub const Stage = index_mod.Stage;
pub const Entry = index_mod.Entry;
pub const Error = index_mod.Error;
pub const Index = index_mod.Index;

test {
    _ = index_mod;
}
