//! Parses and serializes `packed-refs`: git's single file holding many refs
//! at once, written far less often than it is read.
//!
//! This file does no I/O. It works over a buffer a caller already read off
//! disk, and hands back a buffer a caller already owns to write. git does
//! not promise this file is sorted, and only some of its writers emit the
//! header line, so this assumes neither.

const std = @import("std");
const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;

pub const packed_refs = struct {
    /// One ref as `packed-refs` records it: a direct id, never a symref.
    /// git only ever packs refs that already resolve to an object.
    pub const Entry = struct {
        /// Borrowed from the buffer passed to `Iterator.init`.
        name: []const u8,
        oid: Oid,
        /// The object an annotated tag's `oid` ultimately points at. Set
        /// only when a "^" line follows this entry's line in the file.
        peeled: ?Oid,
    };

    pub const Error = error{CorruptRefFile};

    /// Walks a `packed-refs` buffer line by line, in file order rather than
    /// sorted order. A line starting with "#" is a comment, the header
    /// included, and is skipped wherever it appears, not only as the first
    /// line. A line starting with "^" never starts an `Entry` on its own;
    /// it carries the peeled id for the entry the previous call to `next`
    /// returned.
    pub const Iterator = struct {
        lines: std.mem.SplitIterator(u8, .scalar),
        format: Format,

        pub fn init(content: []const u8, format: Format) Iterator {
            return .{ .lines = std.mem.splitScalar(u8, content, '\n'), .format = format };
        }

        pub fn next(it: *Iterator) Error!?Entry {
            while (it.lines.next()) |line| {
                if (line.len == 0) continue;
                if (line[0] == '#') continue;
                // A "^" line with nothing before it has no entry to peel.
                if (line[0] == '^') return error.CorruptRefFile;

                const space = std.mem.indexOfScalar(u8, line, ' ') orelse return error.CorruptRefFile;
                const oid = Oid.parse(it.format, line[0..space]) catch return error.CorruptRefFile;
                const name = line[space + 1 ..];
                if (name.len == 0) return error.CorruptRefFile;

                return .{ .name = name, .oid = oid, .peeled = try it.takePeeledLine() };
            }
            return null;
        }

        /// Consumes the next line only when it is a "^" peel line, returning
        /// its id. Leaves `it` untouched otherwise, so a ref line that
        /// follows is still there for the next call to `next`.
        fn takePeeledLine(it: *Iterator) Error!?Oid {
            var lookahead = it.lines;
            const line = lookahead.next() orelse return null;
            if (line.len == 0 or line[0] != '^') return null;
            const oid = Oid.parse(it.format, line[1..]) catch return error.CorruptRefFile;
            it.lines = lookahead;
            return oid;
        }
    };

    /// Writes `entries` in `packed-refs` format: the header line, then one
    /// line per entry with its "^" peeled line immediately after when
    /// present. Never reorders `entries`; a caller that wants a sorted file
    /// sorts before calling.
    pub fn write(w: *std.Io.Writer, entries: []const Entry) std.Io.Writer.Error!void {
        try w.writeAll("# pack-refs with: peeled fully-peeled sorted\n");
        for (entries) |e| {
            var oid_buf: [Oid.max_formatted_length]u8 = undefined;
            try w.print("{s} {s}\n", .{ e.oid.toHex(&oid_buf), e.name });
            if (e.peeled) |p| {
                var peeled_buf: [Oid.max_formatted_length]u8 = undefined;
                try w.print("^{s}\n", .{p.toHex(&peeled_buf)});
            }
        }
    }
};

// A byte-exact `packed-refs` file, held as a Zig source constant rather than
// a binary fixture: the header, one annotated tag with a "^" peeled line,
// and refs that are not in sorted order (`refs/heads/main` before
// `refs/heads/aaa-not-sorted`, and both after `refs/tags/...`), since not
// every git version promises sorting.
const vector =
    "# pack-refs with: peeled fully-peeled sorted\n" ++
    "111111111111111111111111111111111111111a refs/tags/v0.1.0\n" ++
    "^222222222222222222222222222222222222222b\n" ++
    "333333333333333333333333333333333333333c refs/heads/main\n" ++
    "444444444444444444444444444444444444444d refs/heads/aaa-not-sorted\n";

// expected

test "packed_refs Iterator yields every entry in file order, not sorted order" {
    var it = packed_refs.Iterator.init(vector, .sha1);

    const tag = (try it.next()).?;
    try std.testing.expectEqualStrings("refs/tags/v0.1.0", tag.name);
    var tag_oid_buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("111111111111111111111111111111111111111a", tag.oid.toHex(&tag_oid_buf));
    var tag_peeled_buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("222222222222222222222222222222222222222b", tag.peeled.?.toHex(&tag_peeled_buf));

    const main = (try it.next()).?;
    try std.testing.expectEqualStrings("refs/heads/main", main.name);
    try std.testing.expect(main.peeled == null);

    const aaa = (try it.next()).?;
    try std.testing.expectEqualStrings("refs/heads/aaa-not-sorted", aaa.name);
    try std.testing.expect(aaa.peeled == null);

    try std.testing.expect((try it.next()) == null);
}

test "packed_refs write then Iterator round trips" {
    const entries = [_]packed_refs.Entry{
        .{ .name = "refs/heads/main", .oid = try Oid.parse(.sha1, "333333333333333333333333333333333333333c"), .peeled = null },
        .{ .name = "refs/tags/v0.1.0", .oid = try Oid.parse(.sha1, "111111111111111111111111111111111111111a"), .peeled = try Oid.parse(.sha1, "222222222222222222222222222222222222222b") },
    };
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try packed_refs.write(&w, &entries);

    var it = packed_refs.Iterator.init(w.buffered(), .sha1);
    const first = (try it.next()).?;
    try std.testing.expectEqualStrings("refs/heads/main", first.name);
    const second = (try it.next()).?;
    try std.testing.expectEqualStrings("refs/tags/v0.1.0", second.name);
    var second_peeled_buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("222222222222222222222222222222222222222b", second.peeled.?.toHex(&second_peeled_buf));
    try std.testing.expect((try it.next()) == null);
}

// suspicious

test "packed-refs parsing ignores a comment line that is not the header" {
    const content =
        "# pack-refs with: peeled fully-peeled sorted\n" ++
        "# a stray comment in the middle of the file\n" ++
        "333333333333333333333333333333333333333c refs/heads/main\n";
    var it = packed_refs.Iterator.init(content, .sha1);
    const entry = (try it.next()).?;
    try std.testing.expectEqualStrings("refs/heads/main", entry.name);
    try std.testing.expect((try it.next()) == null);
}

test "packed_refs Iterator rejects a line with no space between id and name" {
    var it = packed_refs.Iterator.init("333333333333333333333333333333333333333c\n", .sha1);
    try std.testing.expectError(error.CorruptRefFile, it.next());
}

test "packed_refs Iterator rejects a peeled line with no entry before it" {
    var it = packed_refs.Iterator.init("^222222222222222222222222222222222222222b\n", .sha1);
    try std.testing.expectError(error.CorruptRefFile, it.next());
}
