//! Linked worktrees: creating and removing a second checkout that shares one
//! object database and one set of refs.

const worktree_mod = @import("ziggit-worktree/Worktree.zig");
pub const add = worktree_mod.add;
pub const remove = worktree_mod.remove;
pub const prune = worktree_mod.prune;
pub const list = worktree_mod.list;
pub const freeList = worktree_mod.freeList;
pub const Entry = worktree_mod.Entry;
pub const AddOptions = worktree_mod.AddOptions;
pub const RemoveOptions = worktree_mod.RemoveOptions;
pub const Force = worktree_mod.Force;
pub const Error = worktree_mod.Error;

test {
    _ = worktree_mod;
}
