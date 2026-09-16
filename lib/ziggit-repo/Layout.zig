//! Where the pieces of a repository live on disk.
//!
//! `discover` fills this in before any object format is known: this struct
//! carries only the physical shape a directory walk can answer on its own
//! (bare or not, a linked worktree or not), never anything that needs
//! config. `Repository.open` reads config afterward, on top of the
//! directories this already opened, to pick the hash format and build the
//! object database and the ref store.

const std = @import("std");

/// The directories `discover` opened while walking the filesystem, plus
/// the physical shape of the repository that only the directory layout
/// itself can answer.
pub const Layout = struct {
    /// The repository's own git directory: `.git` itself for an ordinary
    /// repository, or the directory a `.git` file's `gitdir:` line names,
    /// for a linked worktree or a submodule. Owned; closed by `deinit`.
    git_dir: std.Io.Dir,
    /// Where refs, `packed-refs`, `config`, and `objects` actually live.
    /// Equal to `git_dir`, handle for handle, for every repository that is
    /// not a linked worktree. Owned; closed by `deinit`.
    common_dir: std.Io.Dir,
    /// The directory holding `git_dir` (or naming it, for the `.git` file
    /// case). Null for a bare repository. Owned; closed by `deinit`.
    work_tree: ?std.Io.Dir,
    is_bare: bool,
    is_linked_worktree: bool,

    /// Closes every directory this owns. `git_dir` and `common_dir` share
    /// one handle for every repository that is not a linked worktree, so
    /// this compares the two handles first and closes that one directory
    /// once, never twice.
    pub fn deinit(l: *Layout, io: std.Io) void {
        const shared_handle = l.git_dir.handle == l.common_dir.handle;
        l.git_dir.close(io);
        if (!shared_handle) l.common_dir.close(io);
        if (l.work_tree) |wt| wt.close(io);
        l.* = undefined;
    }
};
