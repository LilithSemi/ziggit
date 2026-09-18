//! Entry name validation: directory tree entry names. This module validates
//! the names that appear in git tree objects and in worktree paths.

const std = @import("std");

/// Answers whether `name` is `.git`, compared without regard to case.
/// Nothing else.
///
/// This narrow check is in core because stageWorktree needs it, and
/// ziggit-index cannot import ziggit-checkout and must not gain that
/// dependency. ziggit-core is what the two layers share.
pub fn isDotGitName(name: []const u8) bool {
    if (name.len != 4) return false;
    return std.ascii.eqlIgnoreCase(name, ".git");
}

test "isDotGitName recognises .git in lowercase" {
    try std.testing.expect(isDotGitName(".git"));
}

test "isDotGitName recognises .git in uppercase" {
    try std.testing.expect(isDotGitName(".GIT"));
}

test "isDotGitName recognises .git in mixed case" {
    try std.testing.expect(isDotGitName(".Git"));
    try std.testing.expect(isDotGitName(".gIT"));
}

test "isDotGitName rejects names that are not .git" {
    try std.testing.expect(!isDotGitName(".gitmodules"));
    try std.testing.expect(!isDotGitName("git"));
    try std.testing.expect(!isDotGitName("."));
    try std.testing.expect(!isDotGitName(""));
    try std.testing.expect(!isDotGitName("git~1"));
}
