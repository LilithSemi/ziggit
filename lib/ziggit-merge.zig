//! Three-way merge.
//!
//! Shaped after libgit2's merge API, since this library replaces it:
//! `mergeFile` is `git_merge_file`, and its `automergeable` field carries
//! the same meaning. Defaults come from libgit2's own
//! `GIT_MERGE_FILE_OPTIONS_INIT`: seven-character markers and the two-way
//! marker style, with `ours` and `theirs` as the labels.

const merge_file_mod = @import("ziggit-merge/merge_file.zig");
const merge_trees_mod = @import("ziggit-merge/merge_trees.zig");
const write_tree_mod = @import("ziggit-merge/write_tree.zig");

pub const Error = merge_file_mod.Error;
pub const Input = merge_file_mod.Input;
pub const FileOptions = merge_file_mod.FileOptions;
pub const FileResult = merge_file_mod.FileResult;
pub const mergeFile = merge_file_mod.mergeFile;

pub const TreeError = merge_trees_mod.Error;
pub const ConflictKind = merge_trees_mod.ConflictKind;
pub const Conflict = merge_trees_mod.Conflict;
pub const Options = merge_trees_mod.Options;
pub const Result = merge_trees_mod.Result;
pub const mergeTrees = merge_trees_mod.mergeTrees;
pub const writeTree = write_tree_mod.writeTree;

test {
    _ = merge_file_mod;
    _ = merge_trees_mod;
    _ = write_tree_mod;
}
