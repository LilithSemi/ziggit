//! Three-way merge.
//!
//! Shaped after libgit2's merge API, since this library replaces it:
//! `mergeFile` is `git_merge_file`, and its `automergeable` field carries
//! the same meaning. Defaults come from libgit2's own
//! `GIT_MERGE_FILE_OPTIONS_INIT`: seven-character markers and the two-way
//! marker style, with `ours` and `theirs` as the labels.

const merge_file_mod = @import("ziggit-merge/merge_file.zig");

pub const Error = merge_file_mod.Error;
pub const Input = merge_file_mod.Input;
pub const FileOptions = merge_file_mod.FileOptions;
pub const FileResult = merge_file_mod.FileResult;
pub const mergeFile = merge_file_mod.mergeFile;

test {
    _ = merge_file_mod;
}
