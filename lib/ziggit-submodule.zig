//! Submodules: parsing `.gitmodules`, and fetching and checking out every
//! submodule a tree records, recursively.
//!
//! A `.gitmodules` file lives inside the repository, and a fetched
//! repository comes from a remote server, so every field this reads --
//! a submodule's name, path, or url -- is untrusted input, the same as a
//! tree entry name is to `ziggit-checkout`. A submodule's `path` is a
//! relative path with separators, legitimately, unlike a tree entry
//! name, so it gets its own, component-wise validation rather than
//! `ziggit-checkout`'s single-component rejection.

const gitmodules_mod = @import("ziggit-submodule/gitmodules.zig");
pub const Submodule = gitmodules_mod.Submodule;
pub const Error = gitmodules_mod.Error;
pub const parseGitmodules = gitmodules_mod.parseGitmodules;

const update_mod = @import("ziggit-submodule/update.zig");
pub const max_depth = update_mod.max_depth;
pub const UpdateOptions = update_mod.UpdateOptions;
pub const updateAll = update_mod.updateAll;

test {
    _ = gitmodules_mod;
    _ = update_mod;
}
