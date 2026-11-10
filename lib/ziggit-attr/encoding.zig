//! `working-tree-encoding` conversion, for the encodings this can do
//! without a charset library.
//!
//! The blob always holds UTF-8. The worktree holds the named encoding.
//! Measured: a worktree file of UTF-16LE `hi\nthere\n` under
//! `working-tree-encoding=UTF-16LE text eol=crlf` stores the UTF-8 bytes
//! `hi\nthere\n`, and comes back as UTF-16LE with CRLF. So the line ending
//! step works on UTF-8 and this conversion is the outermost step on the
//! worktree side.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// An encoding name this cannot convert. Refused rather than guessed
    /// at, because writing the wrong bytes is worse than not writing them.
    UnsupportedEncoding,
    /// The content is not valid in the encoding it claims to be in.
    InvalidEncoding,
} || Allocator.Error;

pub const Encoding = enum {
    utf8,
    utf16_le,
    utf16_be,
    utf32_le,
    utf32_be,

    /// Matches git's spelling, ignoring case and any `-`, so `UTF-16LE`,
    /// `utf16le` and `UTF16LE` are one encoding.
    ///
    /// A bare `UTF-16` or `UTF-32` is refused rather than accepted: git
    /// requires a byte order mark for those, and guessing an order would
    /// write bytes a reader cannot interpret.
    pub fn parse(name: []const u8) ?Encoding {
        var buf: [32]u8 = undefined;
        var n: usize = 0;
        for (name) |c| {
            if (c == '-' or c == '_') continue;
            if (n == buf.len) return null;
            buf[n] = std.ascii.toUpper(c);
            n += 1;
        }
        const norm = buf[0..n];
        if (std.mem.eql(u8, norm, "UTF8")) return .utf8;
        if (std.mem.eql(u8, norm, "UTF16LE")) return .utf16_le;
        if (std.mem.eql(u8, norm, "UTF16BE")) return .utf16_be;
        if (std.mem.eql(u8, norm, "UTF32LE")) return .utf32_le;
        if (std.mem.eql(u8, norm, "UTF32BE")) return .utf32_be;
        return null;
    }

    fn unitSize(e: Encoding) usize {
        return switch (e) {
            .utf8 => 1,
            .utf16_le, .utf16_be => 2,
            .utf32_le, .utf32_be => 4,
        };
    }
};

/// Worktree bytes to the UTF-8 a blob holds. Answers null for `utf8`, so a
/// caller keeps the bytes it already has.
pub fn toUtf8(gpa: Allocator, e: Encoding, content: []const u8) Error!?[]u8 {
    if (e == .utf8) return null;
    if (content.len % e.unitSize() != 0) return error.InvalidEncoding;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [4]u8 = undefined;

    switch (e) {
        .utf8 => unreachable,
        .utf32_le, .utf32_be => {
            var i: usize = 0;
            while (i < content.len) : (i += 4) {
                const v = readUnit(u32, content[i..][0..4], e == .utf32_le);
                const cp = std.math.cast(u21, v) orelse return error.InvalidEncoding;
                const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidEncoding;
                try out.appendSlice(gpa, buf[0..n]);
            }
        },
        .utf16_le, .utf16_be => {
            const little = e == .utf16_le;
            var i: usize = 0;
            while (i < content.len) : (i += 2) {
                const unit = readUnit(u16, content[i..][0..2], little);
                if (unit >= 0xd800 and unit < 0xdc00) {
                    if (i + 4 > content.len) return error.InvalidEncoding;
                    const low = readUnit(u16, content[i + 2 ..][0..2], little);
                    if (low < 0xdc00 or low >= 0xe000) return error.InvalidEncoding;
                    const cp: u21 = 0x10000 +
                        (@as(u21, unit - 0xd800) << 10) +
                        @as(u21, low - 0xdc00);
                    const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidEncoding;
                    try out.appendSlice(gpa, buf[0..n]);
                    i += 2;
                } else {
                    if (unit >= 0xdc00 and unit < 0xe000) return error.InvalidEncoding;
                    const n = std.unicode.utf8Encode(unit, &buf) catch return error.InvalidEncoding;
                    try out.appendSlice(gpa, buf[0..n]);
                }
            }
        },
    }
    return try out.toOwnedSlice(gpa);
}

/// The UTF-8 a blob holds to the worktree's own encoding. Answers null for
/// `utf8`.
pub fn fromUtf8(gpa: Allocator, e: Encoding, content: []const u8) Error!?[]u8 {
    if (e == .utf8) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var view = std.unicode.Utf8View.init(content) catch return error.InvalidEncoding;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        switch (e) {
            .utf8 => unreachable,
            .utf32_le, .utf32_be => try appendUnit(gpa, &out, u32, cp, e == .utf32_le),
            .utf16_le, .utf16_be => {
                const little = e == .utf16_le;
                if (cp < 0x10000) {
                    try appendUnit(gpa, &out, u16, @intCast(cp), little);
                } else {
                    const v = cp - 0x10000;
                    try appendUnit(gpa, &out, u16, @intCast(0xd800 + (v >> 10)), little);
                    try appendUnit(gpa, &out, u16, @intCast(0xdc00 + (v & 0x3ff)), little);
                }
            },
        }
    }
    return try out.toOwnedSlice(gpa);
}

fn readUnit(comptime T: type, bytes: *const [@divExact(@typeInfo(T).int.bits, 8)]u8, little: bool) T {
    return std.mem.readInt(T, bytes, if (little) .little else .big);
}

fn appendUnit(gpa: Allocator, out: *std.ArrayList(u8), comptime T: type, value: T, little: bool) Allocator.Error!void {
    var buf: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, if (little) .little else .big);
    try out.appendSlice(gpa, &buf);
}

const testing = std.testing;

test "the names git writes parse, ignoring case and separators" {
    try testing.expectEqual(Encoding.utf16_le, Encoding.parse("UTF-16LE").?);
    try testing.expectEqual(Encoding.utf16_le, Encoding.parse("utf16le").?);
    try testing.expectEqual(Encoding.utf32_be, Encoding.parse("UTF_32BE").?);
    try testing.expectEqual(Encoding.utf8, Encoding.parse("UTF-8").?);
    // A bare UTF-16 needs a byte order mark, so it is refused.
    try testing.expect(Encoding.parse("UTF-16") == null);
    try testing.expect(Encoding.parse("SHIFT-JIS") == null);
}

test "utf-16le round trips the bytes git produced" {
    const gpa = testing.allocator;
    // Measured: the worktree held these bytes and the blob held `hi\nthere\n`.
    const wt = [_]u8{
        0x68, 0x00, 0x69, 0x00, 0x0a, 0x00, 0x74, 0x00, 0x68, 0x00,
        0x65, 0x00, 0x72, 0x00, 0x65, 0x00, 0x0a, 0x00,
    };
    const as_utf8 = (try toUtf8(gpa, .utf16_le, &wt)).?;
    defer gpa.free(as_utf8);
    try testing.expectEqualStrings("hi\nthere\n", as_utf8);

    const back = (try fromUtf8(gpa, .utf16_le, as_utf8)).?;
    defer gpa.free(back);
    try testing.expectEqualSlices(u8, &wt, back);
}

test "utf-8 asks for no conversion at all" {
    const gpa = testing.allocator;
    try testing.expect((try toUtf8(gpa, .utf8, "plain")) == null);
    try testing.expect((try fromUtf8(gpa, .utf8, "plain")) == null);
}

test "a surrogate pair survives both directions" {
    const gpa = testing.allocator;
    // U+1F600, which needs a surrogate pair in UTF-16.
    const utf8 = "\u{1F600}";
    const le = (try fromUtf8(gpa, .utf16_le, utf8)).?;
    defer gpa.free(le);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x3d, 0xd8, 0x00, 0xde }, le);
    const back = (try toUtf8(gpa, .utf16_le, le)).?;
    defer gpa.free(back);
    try testing.expectEqualStrings(utf8, back);
}

test "big endian differs from little by byte order alone" {
    const gpa = testing.allocator;
    const be = (try fromUtf8(gpa, .utf16_be, "hi")).?;
    defer gpa.free(be);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x68, 0x00, 0x69 }, be);
    const le = (try fromUtf8(gpa, .utf32_le, "h")).?;
    defer gpa.free(le);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x68, 0x00, 0x00, 0x00 }, le);
}

test "content of the wrong length for its encoding is refused" {
    const gpa = testing.allocator;
    try testing.expectError(error.InvalidEncoding, toUtf8(gpa, .utf16_le, "abc"));
    // A high surrogate with nothing behind it.
    try testing.expectError(
        error.InvalidEncoding,
        toUtf8(gpa, .utf16_le, &[_]u8{ 0x3d, 0xd8 }),
    );
}
