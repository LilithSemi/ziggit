//! The tree object: a flat list of entries, each a mode, a name, and the id
//! of the blob, tree, or gitlink the entry names.

const std = @import("std");
const Allocator = std.mem.Allocator;
const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;
const core_mod = @import("ziggit-core");
const FileMode = core_mod.FileMode;

pub const Tree = struct {
    pub const Entry = struct {
        mode: FileMode,
        name: []const u8, // borrowed from the source buffer
        oid: Oid,
    };

    entries: []const Entry, // owned, freed by Tree.deinit; entry names still borrow the source buffer

    pub const ParseError = error{CorruptTree} || Allocator.Error;

    /// Parses a tree object's payload: the bytes after the loose object
    /// header, not including it. Each entry is `<mode> <name>\0<raw oid>`
    /// with no separator between entries. `bytes` must outlive `Tree`,
    /// since every entry's `name` borrows it directly.
    pub fn parse(gpa: Allocator, f: Format, bytes: []const u8) ParseError!Tree {
        var list: std.ArrayList(Entry) = .empty;
        errdefer list.deinit(gpa);

        const oid_len = f.byteLength();
        var i: usize = 0;
        while (i < bytes.len) {
            const sp = std.mem.indexOfScalarPos(u8, bytes, i, ' ') orelse return error.CorruptTree;
            const mode_val = parseMode(bytes[i..sp]) orelse return error.CorruptTree;
            const mode = FileMode.fromOctal(mode_val) orelse return error.CorruptTree;

            const nul = std.mem.indexOfScalarPos(u8, bytes, sp + 1, 0) orelse return error.CorruptTree;
            const name = bytes[sp + 1 .. nul];
            if (name.len == 0) return error.CorruptTree;

            const oid_start = nul + 1;
            if (oid_start + oid_len > bytes.len) return error.CorruptTree;
            const oid = Oid.fromBytes(f, bytes[oid_start..][0..oid_len]);

            try list.append(gpa, .{ .mode = mode, .name = name, .oid = oid });
            i = oid_start + oid_len;
        }

        return .{ .entries = try list.toOwnedSlice(gpa) };
    }

    pub fn deinit(t: *Tree, gpa: Allocator) void {
        gpa.free(t.entries);
        t.entries = &.{};
    }

    /// Writes `t` back out in the exact form `parse` reads. `t.entries`
    /// must already be in git's order; call `sortEntries` first if they
    /// might not be, since a tree written out of order hashes differently
    /// from the same entries git would have written.
    pub fn write(t: Tree, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (t.entries) |entry| {
            try w.print("{o} ", .{@intFromEnum(entry.mode)});
            try w.writeAll(entry.name);
            try w.writeAll("\x00");
            try w.writeAll(entry.oid.slice());
        }
    }

    /// Sorts `entries` into the order git writes. Git compares names as
    /// though a tree's name carried a trailing slash, so a name that is a
    /// prefix of another sorts as if its next byte were '/': "a.b" sorts
    /// before the tree "a" (compared as "a/"), which sorts before "ab",
    /// because '.' (0x2e) < '/' (0x2f) < 'b' (0x62).
    pub fn sortEntries(entries: []Entry) void {
        std.mem.sort(Entry, entries, {}, lessThan);
    }

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        return order(a, b) == .lt;
    }

    fn order(a: Entry, b: Entry) std.math.Order {
        const min_len = @min(a.name.len, b.name.len);
        const common = std.mem.order(u8, a.name[0..min_len], b.name[0..min_len]);
        if (common != .eq) return common;

        const a_next = nextByte(a, min_len);
        const b_next = nextByte(b, min_len);
        if (a_next == null and b_next == null) return .eq;
        if (a_next == null) return .lt;
        if (b_next == null) return .gt;
        return std.math.order(a_next.?, b_next.?);
    }

    /// The byte that follows the shared prefix of length `min_len` in
    /// `entry.name`, or the trailing slash git treats a directory name as
    /// ending with when `entry.name` itself is exactly `min_len` long, or
    /// null when `entry.name` ends there and is not a directory.
    fn nextByte(entry: Entry, min_len: usize) ?u8 {
        if (entry.name.len > min_len) return entry.name[min_len];
        if (entry.mode.isTree()) return '/';
        return null;
    }

    pub fn find(t: Tree, name: []const u8) ?Entry {
        for (t.entries) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }
};

/// Parses a tree entry mode: octal digits with no leading zero, matching
/// how git writes one ("40000", never "040000"). Returns null for anything
/// else, including a value too large for a u32.
fn parseMode(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    if (s.len > 1 and s[0] == '0') return null;
    var value: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '7') return null;
        value = std.math.mul(u32, value, 8) catch return null;
        value = std.math.add(u32, value, c - '0') catch return null;
    }
    return value;
}

// Byte-exact vectors, hand verified with `git mktree` before any of the
// parsing or writing code above existed.

const empty_tree_sha1 = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

/// A tree with three entries: a regular blob, an executable blob, and a
/// subtree. Verified with:
///   printf '100644 blob <LICENSE oid>\tLICENSE\n100755 blob <run.sh oid>\trun.sh\n040000 tree 4b825dc6...\tsrc\n' | git mktree
const license_oid_hex = "a22a2da24d1ceeef3d0c2f1f4f68923f55b8d4cc";
const runsh_oid_hex = "4163036efa65bd4a469e752267498f01ea36a55c";
const three_entry_tree_sha1 = "154f6e706ab76fe778451f3cb35ea5d099392a2a";

fn hexToOid(hex: []const u8) Oid.ParseError!Oid {
    return Oid.parse(.sha1, hex);
}

fn buildThreeEntryTreeBytes(buf: []u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const t: Tree = .{ .entries = &.{
        .{ .mode = .blob, .name = "LICENSE", .oid = try hexToOid(license_oid_hex) },
        .{ .mode = .blob_executable, .name = "run.sh", .oid = try hexToOid(runsh_oid_hex) },
        .{ .mode = .tree, .name = "src", .oid = try hexToOid(empty_tree_sha1) },
    } };
    try t.write(&w);
    return w.buffered();
}

const loose_mod = @import("loose.zig");

// expected

test "Tree parse reads mode name and oid for every entry" {
    const gpa = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const bytes = try buildThreeEntryTreeBytes(&buf);

    const id = loose_mod.loose.hash(.sha1, .tree, bytes);
    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings(three_entry_tree_sha1, id.toHex(&hex_buf));

    var t = try Tree.parse(gpa, .sha1, bytes);
    defer t.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 3), t.entries.len);
    try std.testing.expectEqual(FileMode.blob, t.entries[0].mode);
    try std.testing.expectEqualStrings("LICENSE", t.entries[0].name);
    try std.testing.expect(t.entries[0].oid.eql(try hexToOid(license_oid_hex)));
    try std.testing.expectEqual(FileMode.blob_executable, t.entries[1].mode);
    try std.testing.expectEqualStrings("run.sh", t.entries[1].name);
    try std.testing.expectEqual(FileMode.tree, t.entries[2].mode);
    try std.testing.expectEqualStrings("src", t.entries[2].name);
}

test "Tree write reproduces the exact bytes it parsed" {
    const gpa = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const bytes = try buildThreeEntryTreeBytes(&buf);

    var t = try Tree.parse(gpa, .sha1, bytes);
    defer t.deinit(gpa);

    var out_buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out_buf);
    try t.write(&w);
    try std.testing.expectEqualStrings(bytes, w.buffered());
}

test "Tree find returns the entry with the given name" {
    const gpa = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const bytes = try buildThreeEntryTreeBytes(&buf);

    var t = try Tree.parse(gpa, .sha1, bytes);
    defer t.deinit(gpa);

    const found = t.find("run.sh") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(FileMode.blob_executable, found.mode);
    try std.testing.expect(found.oid.eql(try hexToOid(runsh_oid_hex)));
}

// suspicious

test "Tree find returns null for a name not in the tree" {
    const gpa = std.testing.allocator;
    var buf: [256]u8 = undefined;
    const bytes = try buildThreeEntryTreeBytes(&buf);

    var t = try Tree.parse(gpa, .sha1, bytes);
    defer t.deinit(gpa);

    try std.testing.expectEqual(@as(?Tree.Entry, null), t.find("missing"));
}

test "tree entries sort directories as if they end in a slash" {
    var entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = "ab", .oid = try hexToOid(empty_tree_sha1) },
        .{ .mode = .tree, .name = "a", .oid = try hexToOid(empty_tree_sha1) },
        .{ .mode = .blob, .name = "a.b", .oid = try hexToOid(empty_tree_sha1) },
    };
    Tree.sortEntries(&entries);
    try std.testing.expectEqualStrings("a.b", entries[0].name);
    try std.testing.expectEqualStrings("a", entries[1].name);
    try std.testing.expectEqual(FileMode.tree, entries[1].mode);
    try std.testing.expectEqualStrings("ab", entries[2].name);
}

test "Tree parse rejects an entry whose mode has a leading zero" {
    const gpa = std.testing.allocator;
    const bytes = "040000 src\x00" ++ ("\x00" ** 20);
    try std.testing.expectError(error.CorruptTree, Tree.parse(gpa, .sha1, bytes));
}

test "Tree parse rejects a truncated oid at the end of the buffer" {
    const gpa = std.testing.allocator;
    const bytes = "100644 a\x00" ++ ("\x00" ** 10); // 10 bytes, sha1 needs 20
    try std.testing.expectError(error.CorruptTree, Tree.parse(gpa, .sha1, bytes));
}

test "Tree parse accepts an empty tree" {
    const gpa = std.testing.allocator;
    var t = try Tree.parse(gpa, .sha1, "");
    defer t.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), t.entries.len);
}

// regression

test "Tree write never emits a leading zero on a subtree's mode" {
    const t: Tree = .{ .entries = &.{
        .{ .mode = .tree, .name = "src", .oid = try hexToOid(empty_tree_sha1) },
    } };
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try t.write(&w);
    // Writing "040000" instead of "40000" changes every byte after it in
    // the payload, which changes the tree's id even though the mode still
    // means the same thing.
    try std.testing.expect(std.mem.startsWith(u8, w.buffered(), "40000 src\x00"));
    try std.testing.expect(!std.mem.startsWith(u8, w.buffered(), "040000"));
}
