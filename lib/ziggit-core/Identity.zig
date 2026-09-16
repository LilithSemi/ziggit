//! One side of a commit's authorship: an author or a committer line.

const std = @import("std");

pub const Identity = struct {
    name: []const u8, // borrowed from the object buffer
    email: []const u8, // borrowed from the object buffer
    when: i64,
    tz_offset_minutes: i16,
    /// True only when the parsed offset was the literal `-0000`.
    /// `tz_offset_minutes` cannot carry a sign on a zero value, and `write`
    /// must reproduce this bit or the round trip changes the commit id.
    tz_negative_zero: bool = false,

    pub const ParseError = error{MalformedIdentity};

    /// Parses `Name <email> <when> <tz>`: git's authorship line with the
    /// leading `author `/`committer ` keyword already stripped by the
    /// caller. The name may be empty and the email may be empty; git
    /// permits both. Only the structure is mandatory: one space, one
    /// bracketed email, one space, a decimal timestamp, one space, and a
    /// signed four digit timezone offset.
    pub fn parse(line: []const u8) ParseError!Identity {
        const lt = std.mem.indexOfScalar(u8, line, '<') orelse return error.MalformedIdentity;
        if (lt == 0 or line[lt - 1] != ' ') return error.MalformedIdentity;
        const name = line[0 .. lt - 1];

        const gt = std.mem.indexOfScalarPos(u8, line, lt + 1, '>') orelse return error.MalformedIdentity;
        const email = line[lt + 1 .. gt];

        if (gt + 1 >= line.len or line[gt + 1] != ' ') return error.MalformedIdentity;
        const rest = line[gt + 2 ..];

        const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.MalformedIdentity;
        const when_str = rest[0..sp];
        const tz_str = rest[sp + 1 ..];

        const when = std.fmt.parseInt(i64, when_str, 10) catch return error.MalformedIdentity;

        if (tz_str.len != 5) return error.MalformedIdentity;
        const sign = tz_str[0];
        if (sign != '+' and sign != '-') return error.MalformedIdentity;
        const hh = std.fmt.parseInt(u16, tz_str[1..3], 10) catch return error.MalformedIdentity;
        const mm = std.fmt.parseInt(u16, tz_str[3..5], 10) catch return error.MalformedIdentity;
        // The rule to route untrusted arithmetic through a checked add does
        // not apply here. tz_str[1..3] and tz_str[3..5] are each exactly
        // two decimal digits, so hh and mm are each at most 99. The result
        // tops out at 99 * 60 + 99 = 6039, which fits a u16 with room to
        // spare, so no overflow can occur.
        const magnitude: i16 = @intCast(hh * 60 + mm);
        const negative = sign == '-';

        return .{
            .name = name,
            .email = email,
            .when = when,
            .tz_offset_minutes = if (negative) -magnitude else magnitude,
            .tz_negative_zero = negative and magnitude == 0,
        };
    }

    /// Writes `id` back out in the exact form `parse` reads. A commit id
    /// covers these bytes, so this must reproduce them exactly, including
    /// the sign of a zero offset.
    pub fn write(id: Identity, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(id.name);
        try w.writeAll(" <");
        try w.writeAll(id.email);
        try w.writeAll("> ");
        try w.print("{d}", .{id.when});
        try w.writeAll(" ");
        const negative = id.tz_offset_minutes < 0 or id.tz_negative_zero;
        try w.writeAll(if (negative) "-" else "+");
        const magnitude: u16 = @abs(id.tz_offset_minutes);
        try w.print("{d:0>2}{d:0>2}", .{ magnitude / 60, magnitude % 60 });
    }
};

// expected

test "Identity parse reads name email time and tz from an author line" {
    const id = try Identity.parse("A U Thor <author@example.com> 1234567890 +0100");
    try std.testing.expectEqualStrings("A U Thor", id.name);
    try std.testing.expectEqualStrings("author@example.com", id.email);
    try std.testing.expectEqual(@as(i64, 1234567890), id.when);
    try std.testing.expectEqual(@as(i16, 60), id.tz_offset_minutes);
}

test "Identity write reproduces the exact bytes it parsed" {
    const line = "A U Thor <author@example.com> 1234567890 +0100";
    const id = try Identity.parse(line);
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try id.write(&w);
    try std.testing.expectEqualStrings(line, w.buffered());
}

// suspicious

test "Identity parse accepts a negative tz offset" {
    const id = try Identity.parse("A U Thor <author@example.com> 1234567890 -0430");
    try std.testing.expectEqual(@as(i16, -270), id.tz_offset_minutes);
}

test "Identity parse rejects a line with no angle brackets" {
    try std.testing.expectError(
        error.MalformedIdentity,
        Identity.parse("A U Thor author@example.com 1234567890 +0100"),
    );
}

test "Identity parse accepts an empty name" {
    const id = try Identity.parse(" <author@example.com> 1234567890 +0100");
    try std.testing.expectEqualStrings("", id.name);
}

test "Identity parse accepts an empty email" {
    const id = try Identity.parse("A U Thor <> 1234567890 +0100");
    try std.testing.expectEqualStrings("", id.email);
}

// regression

test "Identity write preserves the sign of a negative zero tz offset" {
    const line = "A U Thor <author@example.com> 1234567890 -0000";
    const id = try Identity.parse(line);
    try std.testing.expectEqual(@as(i16, 0), id.tz_offset_minutes);
    try std.testing.expect(id.tz_negative_zero);
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try id.write(&w);
    try std.testing.expectEqualStrings(line, w.buffered());
}

test "Identity write preserves the sign of a positive zero tz offset" {
    const line = "A U Thor <author@example.com> 1234567890 +0000";
    const id = try Identity.parse(line);
    try std.testing.expectEqual(@as(i16, 0), id.tz_offset_minutes);
    try std.testing.expect(!id.tz_negative_zero);
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try id.write(&w);
    try std.testing.expectEqualStrings(line, w.buffered());
}
