//! Structured Git diffs: file patches, hunks, lines, and unified rendering.

const diff_mod = @import("ziggit-diff/Diff.zig");

pub const diffBlobs = diff_mod.diffBlobs;
pub const diffTrees = diff_mod.diffTrees;
pub const diffCommits = diff_mod.diffCommits;
pub const Diff = diff_mod.Diff;
pub const Patch = diff_mod.Patch;
pub const Hunk = diff_mod.Hunk;
pub const Line = diff_mod.Line;
pub const Origin = diff_mod.Origin;
pub const Status = diff_mod.Status;
pub const Options = diff_mod.Options;
pub const Error = diff_mod.Error;

test {
    _ = diff_mod;
}
