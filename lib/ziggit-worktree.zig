//! Linked worktrees: creating and removing a second checkout that shares one
//! object database and one set of refs.

const worktree_mod = @import("ziggit-worktree/Worktree.zig");
pub const add = worktree_mod.add;
pub const remove = worktree_mod.remove;
pub const AddOptions = worktree_mod.AddOptions;
pub const RemoveOptions = worktree_mod.RemoveOptions;
pub const Error = worktree_mod.Error;

test {
    _ = worktree_mod;
}
