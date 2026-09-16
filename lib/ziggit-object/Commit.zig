//! The commit object: a tree, zero or more parents, two identities, any
//! header lines git itself does not standardize, and a free text message.

const std = @import("std");
const Allocator = std.mem.Allocator;
const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;
const core_mod = @import("ziggit-core");
const Identity = core_mod.Identity;

/// One preserved commit header line. `key` and `value` borrow the source
/// buffer `Commit.parse` was given. `value` holds continuation lines joined
/// exactly as they appeared, leading space included: a `gpgsig` value spans
/// several lines this way, and the commit id covers every one of those
/// bytes.
pub const ExtraHeader = struct {
    key: []const u8,
    value: []const u8,
};

pub const Commit = struct {
    tree: Oid,
    parents: []const Oid, // owned, freed by Commit.deinit
    author: Identity,
    committer: Identity,
    /// Every header line that is not tree, parent, author or committer, kept
    /// verbatim and in order. The commit id covers these bytes, so a round
    /// trip that drops them produces a different commit.
    extra_headers: []const ExtraHeader, // owned, freed by Commit.deinit
    message: []const u8, // borrowed from the source buffer

    pub const ParseError = error{CorruptCommit} || Allocator.Error;

    /// Parses a commit object's payload: the bytes after the loose object
    /// header, not including it. `bytes` must outlive `Commit`, since
    /// `message`, `extra_headers` and every `Identity` name and email borrow
    /// it directly.
    pub fn parse(gpa: Allocator, f: Format, bytes: []const u8) ParseError!Commit {
        var tree: ?Oid = null;
        var parents: std.ArrayList(Oid) = .empty;
        errdefer parents.deinit(gpa);
        var author: ?Identity = null;
        var committer: ?Identity = null;
        var extra: std.ArrayList(ExtraHeader) = .empty;
        errdefer extra.deinit(gpa);

        var i: usize = 0;
        while (true) {
            const nl = std.mem.indexOfScalarPos(u8, bytes, i, '\n') orelse return error.CorruptCommit;
            const line = bytes[i..nl];
            if (line.len == 0) {
                i = nl + 1;
                break;
            }

            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return error.CorruptCommit;
            const key = line[0..sp];
            const value_start = i + sp + 1;
            var value_end = nl;
            var next = nl + 1;
            while (next < bytes.len and bytes[next] == ' ') {
                const cont_nl = std.mem.indexOfScalarPos(u8, bytes, next, '\n') orelse
                    return error.CorruptCommit;
                value_end = cont_nl;
                next = cont_nl + 1;
            }
            const value = bytes[value_start..value_end];

            if (std.mem.eql(u8, key, "tree")) {
                if (tree != null) return error.CorruptCommit;
                tree = Oid.parse(f, value) catch return error.CorruptCommit;
            } else if (std.mem.eql(u8, key, "parent")) {
                const parent = Oid.parse(f, value) catch return error.CorruptCommit;
                try parents.append(gpa, parent);
            } else if (std.mem.eql(u8, key, "author")) {
                if (author != null) return error.CorruptCommit;
                author = Identity.parse(value) catch return error.CorruptCommit;
            } else if (std.mem.eql(u8, key, "committer")) {
                if (committer != null) return error.CorruptCommit;
                committer = Identity.parse(value) catch return error.CorruptCommit;
            } else {
                try extra.append(gpa, .{ .key = key, .value = value });
            }
            i = next;
        }

        const tree_id = tree orelse return error.CorruptCommit;
        const author_id = author orelse return error.CorruptCommit;
        const committer_id = committer orelse return error.CorruptCommit;

        const owned_parents = try parents.toOwnedSlice(gpa);
        errdefer gpa.free(owned_parents);
        const owned_extra = try extra.toOwnedSlice(gpa);

        return .{
            .tree = tree_id,
            .parents = owned_parents,
            .author = author_id,
            .committer = committer_id,
            .extra_headers = owned_extra,
            .message = bytes[i..],
        };
    }

    pub fn deinit(c: *Commit, gpa: Allocator) void {
        gpa.free(c.parents);
        gpa.free(c.extra_headers);
        c.parents = &.{};
        c.extra_headers = &.{};
    }

    /// Writes `c` back out in the exact form `parse` reads: tree, parents in
    /// order, author, committer, the extra headers in their captured order,
    /// a blank line, then the message. Real git commits never interleave
    /// extra headers among tree/parent/author/committer, so this fixed
    /// order reproduces every commit `parse` can produce.
    pub fn write(c: Commit, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("tree ");
        try c.tree.format(w);
        try w.writeAll("\n");
        for (c.parents) |parent| {
            try w.writeAll("parent ");
            try parent.format(w);
            try w.writeAll("\n");
        }
        try w.writeAll("author ");
        try c.author.write(w);
        try w.writeAll("\n");
        try w.writeAll("committer ");
        try c.committer.write(w);
        try w.writeAll("\n");
        for (c.extra_headers) |extra_header| {
            try w.writeAll(extra_header.key);
            try w.writeAll(" ");
            try w.writeAll(extra_header.value);
            try w.writeAll("\n");
        }
        try w.writeAll("\n");
        try w.writeAll(c.message);
    }
};

// Byte-exact vectors, hand verified with `git commit-tree`/`git hash-object`
// before any of the parsing or writing code above existed.

const empty_tree_sha1 = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

/// A commit with no parents. Verified with:
///   GIT_AUTHOR_DATE="1234567890 +0000" GIT_COMMITTER_DATE="1234567890 +0000" \
///   git commit-tree 4b825dc6... (author/committer name+email as below)
const plain_commit_bytes =
    "tree " ++ empty_tree_sha1 ++ "\n" ++
    "author A U Thor <author@example.com> 1234567890 +0000\n" ++
    "committer C O Mitter <committer@example.com> 1234567890 +0000\n" ++
    "\n" ++
    "Initial commit\n";
const plain_commit_sha1 = "93380873c09f3269d9f39789df269f3bdfee6bc8";

/// A commit carrying a `gpgsig` header whose value spans four continuation
/// lines, one of them empty but for its leading space. Round-tripped
/// through real `git hash-object -t commit -w` to confirm git accepts and
/// reproduces these exact bytes, independent of signature validity.
const gpgsig_commit_bytes =
    "tree " ++ empty_tree_sha1 ++ "\n" ++
    "author A U Thor <author@example.com> 1234567890 +0000\n" ++
    "committer C O Mitter <committer@example.com> 1234567890 +0000\n" ++
    "gpgsig -----BEGIN PGP SIGNATURE-----\n" ++
    " \n" ++
    " iQIzBAABCAAdFiEE0000000000000000000000000000000000\n" ++
    " =AAAA\n" ++
    " -----END PGP SIGNATURE-----\n" ++
    "\n" ++
    "Signed commit\n";
const gpgsig_commit_sha1 = "4d9f35eddf699660be577688e9eb1c4beec6ff19";

/// A merge commit with three parents.
const merge_commit_bytes =
    "tree " ++ empty_tree_sha1 ++ "\n" ++
    "parent 93380873c09f3269d9f39789df269f3bdfee6bc8\n" ++
    "parent 4d9f35eddf699660be577688e9eb1c4beec6ff19\n" ++
    "parent 154f6e706ab76fe778451f3cb35ea5d099392a2a\n" ++
    "author A U Thor <author@example.com> 1234567890 +0000\n" ++
    "committer C O Mitter <committer@example.com> 1234567890 +0000\n" ++
    "\n" ++
    "Merge three branches\n";
const merge_commit_sha1 = "aa2336e46ef9bc54cd295abd2ab20ca11f8a751a";

const loose_mod = @import("loose.zig");

fn expectHash(bytes: []const u8, expected_sha1: []const u8) !void {
    const id = loose_mod.loose.hash(.sha1, .commit, bytes);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings(expected_sha1, id.toHex(&buf));
}

// expected

test "Commit parse reads tree parents author committer and message" {
    const gpa = std.testing.allocator;
    try expectHash(merge_commit_bytes, merge_commit_sha1);

    var c = try Commit.parse(gpa, .sha1, merge_commit_bytes);
    defer c.deinit(gpa);

    var tree_buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings(empty_tree_sha1, c.tree.toHex(&tree_buf));
    try std.testing.expectEqual(@as(usize, 3), c.parents.len);
    try std.testing.expectEqualStrings("A U Thor", c.author.name);
    try std.testing.expectEqualStrings("C O Mitter", c.committer.name);
    try std.testing.expectEqualStrings("Merge three branches\n", c.message);
}

test "Commit write reproduces the exact bytes it parsed" {
    const gpa = std.testing.allocator;
    var c = try Commit.parse(gpa, .sha1, plain_commit_bytes);
    defer c.deinit(gpa);

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try c.write(&w);
    try std.testing.expectEqualStrings(plain_commit_bytes, w.buffered());
}

// suspicious

test "Commit parse keeps a gpgsig header verbatim and write puts it back" {
    const gpa = std.testing.allocator;
    try expectHash(gpgsig_commit_bytes, gpgsig_commit_sha1);

    var c = try Commit.parse(gpa, .sha1, gpgsig_commit_bytes);
    defer c.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), c.extra_headers.len);
    try std.testing.expectEqualStrings("gpgsig", c.extra_headers[0].key);
    try std.testing.expect(std.mem.indexOf(u8, c.extra_headers[0].value, "\n ") != null);

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try c.write(&w);
    try std.testing.expectEqualStrings(gpgsig_commit_bytes, w.buffered());
}

test "Commit parse accepts a commit with no parents" {
    const gpa = std.testing.allocator;
    try expectHash(plain_commit_bytes, plain_commit_sha1);

    var c = try Commit.parse(gpa, .sha1, plain_commit_bytes);
    defer c.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), c.parents.len);
}

test "Commit parse accepts a merge commit with three parents" {
    const gpa = std.testing.allocator;
    var c = try Commit.parse(gpa, .sha1, merge_commit_bytes);
    defer c.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), c.parents.len);
    const expected = [_][]const u8{
        "93380873c09f3269d9f39789df269f3bdfee6bc8",
        "4d9f35eddf699660be577688e9eb1c4beec6ff19",
        "154f6e706ab76fe778451f3cb35ea5d099392a2a",
    };
    for (c.parents, expected) |parent, want_hex| {
        var buf: [Oid.max_formatted_length]u8 = undefined;
        try std.testing.expectEqualStrings(want_hex, parent.toHex(&buf));
    }
}

test "Commit parse rejects a commit with two tree headers" {
    const gpa = std.testing.allocator;
    const bytes =
        "tree " ++ empty_tree_sha1 ++ "\n" ++
        "tree " ++ empty_tree_sha1 ++ "\n" ++
        "author A U Thor <author@example.com> 1234567890 +0000\n" ++
        "committer C O Mitter <committer@example.com> 1234567890 +0000\n" ++
        "\n" ++
        "Duplicate tree\n";
    try std.testing.expectError(error.CorruptCommit, Commit.parse(gpa, .sha1, bytes));
}

test "Commit parse rejects a commit with two author headers" {
    const gpa = std.testing.allocator;
    const bytes =
        "tree " ++ empty_tree_sha1 ++ "\n" ++
        "author A U Thor <author@example.com> 1234567890 +0000\n" ++
        "author A U Thor <author@example.com> 1234567890 +0000\n" ++
        "committer C O Mitter <committer@example.com> 1234567890 +0000\n" ++
        "\n" ++
        "Duplicate author\n";
    try std.testing.expectError(error.CorruptCommit, Commit.parse(gpa, .sha1, bytes));
}

test "Commit parse rejects a commit with two committer headers" {
    const gpa = std.testing.allocator;
    const bytes =
        "tree " ++ empty_tree_sha1 ++ "\n" ++
        "author A U Thor <author@example.com> 1234567890 +0000\n" ++
        "committer C O Mitter <committer@example.com> 1234567890 +0000\n" ++
        "committer C O Mitter <committer@example.com> 1234567890 +0000\n" ++
        "\n" ++
        "Duplicate committer\n";
    try std.testing.expectError(error.CorruptCommit, Commit.parse(gpa, .sha1, bytes));
}

// regression

test "Commit write preserves a committer's negative zero timezone offset" {
    const gpa = std.testing.allocator;
    const bytes =
        "tree " ++ empty_tree_sha1 ++ "\n" ++
        "author A U Thor <author@example.com> 1234567890 +0000\n" ++
        "committer C O Mitter <committer@example.com> 1234567890 -0000\n" ++
        "\n" ++
        "Negative zero committer offset\n";

    var c = try Commit.parse(gpa, .sha1, bytes);
    defer c.deinit(gpa);
    try std.testing.expect(c.committer.tz_negative_zero);

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try c.write(&w);
    // `Identity.tz_offset_minutes` alone cannot tell "+0000" from "-0000"
    // apart; a commit id built from the wrong sign is a different commit.
    try std.testing.expectEqualStrings(bytes, w.buffered());
}
