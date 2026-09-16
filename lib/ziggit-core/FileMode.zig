//! The mode octal that a tree entry carries. Git writes these without a
//! leading zero, so `tree` serializes as "40000", not "040000".

const std = @import("std");

pub const FileMode = enum(u32) {
    tree = 0o040000,
    blob = 0o100644,
    blob_executable = 0o100755,
    symlink = 0o120000,
    gitlink = 0o160000,

    /// Maps a raw mode value to a `FileMode`. Returns null for any value
    /// git never writes, for example `0o100664`: git normalizes a
    /// group-writable blob to `0o100644` before it writes a tree, so a tree
    /// holding `0o100664` is corrupt, not a mode we should guess at.
    pub fn fromOctal(v: u32) ?FileMode {
        return std.enums.fromInt(FileMode, v);
    }

    pub fn isTree(m: FileMode) bool {
        return m == .tree;
    }

    pub fn isGitlink(m: FileMode) bool {
        return m == .gitlink;
    }
};

// expected

test "FileMode fromOctal accepts the five modes git writes" {
    try std.testing.expectEqual(FileMode.tree, FileMode.fromOctal(0o040000).?);
    try std.testing.expectEqual(FileMode.blob, FileMode.fromOctal(0o100644).?);
    try std.testing.expectEqual(FileMode.blob_executable, FileMode.fromOctal(0o100755).?);
    try std.testing.expectEqual(FileMode.symlink, FileMode.fromOctal(0o120000).?);
    try std.testing.expectEqual(FileMode.gitlink, FileMode.fromOctal(0o160000).?);
}

// suspicious

test "FileMode fromOctal rejects 100664" {
    try std.testing.expectEqual(@as(?FileMode, null), FileMode.fromOctal(0o100664));
}
