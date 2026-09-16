//! The top of the core: repository discovery, the on-disk layout, and the
//! `Repository` that ties the object database, the ref store, and config
//! into one thing.
//!
//! This is the one module that knows how the pieces of a repository sit
//! on disk together: where a linked worktree's refs actually live, what a
//! `.git` file means, and which `core.repositoryformatversion` and
//! `extensions.*` values this build understands.

const discover_mod = @import("ziggit-repo/discover.zig");
pub const discover = discover_mod.discover;
pub const DiscoverOptions = discover_mod.DiscoverOptions;

const layout_mod = @import("ziggit-repo/Layout.zig");
pub const Layout = layout_mod.Layout;

const repository_mod = @import("ziggit-repo/Repository.zig");
pub const Repository = repository_mod.Repository;
pub const Error = repository_mod.Error;
pub const readShallowBoundary = repository_mod.readShallowBoundary;
pub const createRemote = repository_mod.Repository.createRemote;

test {
    _ = discover_mod;
    _ = layout_mod;
    _ = repository_mod;
}
