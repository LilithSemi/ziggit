//! What differs between HEAD, the index and the working tree: git's two
//! porcelain columns, plus untracked paths.

const status_mod = @import("ziggit-status/Status.zig");
pub const status = status_mod.status;
pub const Result = status_mod.Result;
pub const Change = status_mod.Change;
pub const Worktree = status_mod.Worktree;
pub const Staged = status_mod.Staged;
pub const Options = status_mod.Options;
pub const Error = status_mod.Error;

test {
    _ = status_mod;
}
