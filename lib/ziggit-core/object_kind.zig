//! What kind of git object a buffer holds: a commit, a tree, a blob, or a
//! tag.

const std = @import("std");

pub const ObjectKind = enum {
    commit,
    tree,
    blob,
    tag,

    /// Maps a loose object header's type word, or a tree entry's type, to
    /// an `ObjectKind`. Returns null for any other spelling.
    pub fn fromName(s: []const u8) ?ObjectKind {
        if (std.mem.eql(u8, s, "commit")) return .commit;
        if (std.mem.eql(u8, s, "tree")) return .tree;
        if (std.mem.eql(u8, s, "blob")) return .blob;
        if (std.mem.eql(u8, s, "tag")) return .tag;
        return null;
    }

    /// Returns the spelling `fromName` accepts for `k`.
    pub fn name(k: ObjectKind) []const u8 {
        return switch (k) {
            .commit => "commit",
            .tree => "tree",
            .blob => "blob",
            .tag => "tag",
        };
    }
};

// expected

test "ObjectKind round trips through its name" {
    try std.testing.expectEqual(ObjectKind.commit, ObjectKind.fromName("commit").?);
    try std.testing.expectEqual(ObjectKind.tree, ObjectKind.fromName("tree").?);
    try std.testing.expectEqual(ObjectKind.blob, ObjectKind.fromName("blob").?);
    try std.testing.expectEqual(ObjectKind.tag, ObjectKind.fromName("tag").?);
    try std.testing.expectEqualStrings("commit", ObjectKind.commit.name());
    try std.testing.expectEqualStrings("tree", ObjectKind.tree.name());
    try std.testing.expectEqualStrings("blob", ObjectKind.blob.name());
    try std.testing.expectEqualStrings("tag", ObjectKind.tag.name());
}
