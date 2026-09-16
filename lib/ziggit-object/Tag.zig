//! The annotated tag object: the id and kind of the object it names, the
//! tag's own name, an optional tagger, and a free text message.

const std = @import("std");
const Allocator = std.mem.Allocator;
const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;
const core_mod = @import("ziggit-core");
const ObjectKind = core_mod.ObjectKind;
const Identity = core_mod.Identity;

pub const Tag = struct {
    object: Oid,
    kind: ObjectKind,
    name: []const u8, // borrowed from the source buffer
    tagger: ?Identity,
    message: []const u8, // borrowed from the source buffer

    pub const ParseError = error{CorruptTag} || Allocator.Error;

    /// Parses a tag object's payload: the bytes after the loose object
    /// header, not including it. `gpa` is accepted for the same shape as
    /// `Commit.parse` and `Tree.parse`, but a `Tag` owns nothing: every
    /// field either copies by value or borrows `bytes`, which must outlive
    /// `Tag`.
    pub fn parse(gpa: Allocator, f: Format, bytes: []const u8) ParseError!Tag {
        _ = gpa;
        var i: usize = 0;

        const object_kv = try takeKeyValue(bytes, &i);
        if (!std.mem.eql(u8, object_kv.key, "object")) return error.CorruptTag;
        const object = Oid.parse(f, object_kv.value) catch return error.CorruptTag;

        const type_kv = try takeKeyValue(bytes, &i);
        if (!std.mem.eql(u8, type_kv.key, "type")) return error.CorruptTag;
        const kind = ObjectKind.fromName(type_kv.value) orelse return error.CorruptTag;

        const tag_kv = try takeKeyValue(bytes, &i);
        if (!std.mem.eql(u8, tag_kv.key, "tag")) return error.CorruptTag;
        const name = tag_kv.value;

        // The next line is either "tagger ..." or the blank line that ends
        // the headers. Either way it is consumed here.
        const next_line = try takeLine(bytes, &i);
        var tagger: ?Identity = null;
        if (next_line.len != 0) {
            const sp = std.mem.indexOfScalar(u8, next_line, ' ') orelse return error.CorruptTag;
            if (!std.mem.eql(u8, next_line[0..sp], "tagger")) return error.CorruptTag;
            tagger = Identity.parse(next_line[sp + 1 ..]) catch return error.CorruptTag;

            const blank = try takeLine(bytes, &i);
            if (blank.len != 0) return error.CorruptTag;
        }

        return .{
            .object = object,
            .kind = kind,
            .name = name,
            .tagger = tagger,
            .message = bytes[i..],
        };
    }

    /// `Tag` owns nothing, so this has no bytes to free. It exists for the
    /// same lifecycle shape `Commit` and `Tree` use.
    pub fn deinit(t: *Tag, gpa: Allocator) void {
        _ = t;
        _ = gpa;
    }

    pub fn write(t: Tag, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("object ");
        try t.object.format(w);
        try w.writeAll("\ntype ");
        try w.writeAll(t.kind.name());
        try w.writeAll("\ntag ");
        try w.writeAll(t.name);
        try w.writeAll("\n");
        if (t.tagger) |tagger| {
            try w.writeAll("tagger ");
            try tagger.write(w);
            try w.writeAll("\n");
        }
        try w.writeAll("\n");
        try w.writeAll(t.message);
    }
};

fn takeLine(bytes: []const u8, i: *usize) error{CorruptTag}![]const u8 {
    const nl = std.mem.indexOfScalarPos(u8, bytes, i.*, '\n') orelse return error.CorruptTag;
    const line = bytes[i.*..nl];
    i.* = nl + 1;
    return line;
}

fn takeKeyValue(bytes: []const u8, i: *usize) error{CorruptTag}!struct {
    key: []const u8,
    value: []const u8,
} {
    const line = try takeLine(bytes, i);
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return error.CorruptTag;
    return .{ .key = line[0..sp], .value = line[sp + 1 ..] };
}

// Byte-exact vector, hand verified with `git hash-object -t tag` before any
// of the parsing or writing code above existed.

const tag_bytes =
    "object 93380873c09f3269d9f39789df269f3bdfee6bc8\n" ++
    "type commit\n" ++
    "tag v1.0.0\n" ++
    "tagger A U Thor <author@example.com> 1234567890 +0000\n" ++
    "\n" ++
    "Release 1.0.0\n";
const tag_sha1 = "6cf3e1be2e63af7f81ea7e276ea35068e35e5368";

const loose_mod = @import("loose.zig");

// expected

test "Tag parse reads object kind name tagger and message" {
    const gpa = std.testing.allocator;
    const id = loose_mod.loose.hash(.sha1, .tag, tag_bytes);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings(tag_sha1, id.toHex(&buf));

    var t = try Tag.parse(gpa, .sha1, tag_bytes);
    defer t.deinit(gpa);

    var object_buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings(
        "93380873c09f3269d9f39789df269f3bdfee6bc8",
        t.object.toHex(&object_buf),
    );
    try std.testing.expectEqual(ObjectKind.commit, t.kind);
    try std.testing.expectEqualStrings("v1.0.0", t.name);
    try std.testing.expectEqualStrings("A U Thor", t.tagger.?.name);
    try std.testing.expectEqualStrings("Release 1.0.0\n", t.message);
}

test "Tag write reproduces the exact bytes it parsed" {
    const gpa = std.testing.allocator;
    var t = try Tag.parse(gpa, .sha1, tag_bytes);
    defer t.deinit(gpa);

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try t.write(&w);
    try std.testing.expectEqualStrings(tag_bytes, w.buffered());
}

// suspicious

test "Tag parse accepts a tag with no tagger" {
    const gpa = std.testing.allocator;
    const bytes =
        "object 93380873c09f3269d9f39789df269f3bdfee6bc8\n" ++
        "type commit\n" ++
        "tag v1.0.0\n" ++
        "\n" ++
        "No tagger here\n";
    var t = try Tag.parse(gpa, .sha1, bytes);
    defer t.deinit(gpa);
    try std.testing.expect(t.tagger == null);
    try std.testing.expectEqualStrings("No tagger here\n", t.message);
}

// regression

test "Tag write preserves a tagger's negative zero timezone offset" {
    const gpa = std.testing.allocator;
    const bytes =
        "object 93380873c09f3269d9f39789df269f3bdfee6bc8\n" ++
        "type commit\n" ++
        "tag v1.0.0\n" ++
        "tagger A U Thor <author@example.com> 1234567890 -0000\n" ++
        "\n" ++
        "Negative zero tagger offset\n";

    var t = try Tag.parse(gpa, .sha1, bytes);
    defer t.deinit(gpa);
    try std.testing.expect(t.tagger.?.tz_negative_zero);

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try t.write(&w);
    try std.testing.expectEqualStrings(bytes, w.buffered());
}
