//! A git object id: a fixed-length digest tagged with the hash format that
//! produced it.
//!
//! This file does no I/O. It trusts nothing about a caller's hex string
//! until it has scanned every character.

const std = @import("std");

/// Which hash function produced an id's bytes.
pub const Format = enum {
    sha1,
    sha256,

    /// Length of the raw digest, in bytes.
    pub fn byteLength(f: Format) usize {
        return switch (f) {
            .sha1 => 20,
            .sha256 => 32,
        };
    }

    /// Length of the hex-encoded digest, in characters.
    pub fn formattedLength(f: Format) usize {
        return switch (f) {
            .sha1 => 40,
            .sha256 => 64,
        };
    }

    /// Maps git's `--object-format` spelling to a `Format`. Returns null for
    /// any other spelling.
    pub fn fromName(n: []const u8) ?Format {
        if (std.mem.eql(u8, n, "sha1")) return .sha1;
        if (std.mem.eql(u8, n, "sha256")) return .sha256;
        return null;
    }

    /// Returns the spelling `fromName` accepts for `f`.
    pub fn name(f: Format) []const u8 {
        return switch (f) {
            .sha1 => "sha1",
            .sha256 => "sha256",
        };
    }
};

/// A git object id: a digest tagged with the format that produced it.
pub const Oid = union(Format) {
    sha1: [20]u8,
    sha256: [32]u8,

    /// Byte length of the largest digest this union can hold.
    pub const max_byte_length: usize = 32;
    /// Hex length of the largest digest this union can hold.
    pub const max_formatted_length: usize = 64;

    /// `parse` and `parseAny` return this when the input is not a well
    /// formed hex id for the requested format.
    pub const ParseError = error{InvalidOid};

    /// The all-zero id for `f`. Git uses this to mean "no object".
    pub fn zero(f: Format) Oid {
        return switch (f) {
            .sha1 => .{ .sha1 = [_]u8{0} ** 20 },
            .sha256 => .{ .sha256 = [_]u8{0} ** 32 },
        };
    }

    pub fn isZero(oid: Oid) bool {
        return switch (oid) {
            inline else => |bytes| std.mem.allEqual(u8, &bytes, 0),
        };
    }

    /// Builds an id from raw digest bytes. Asserts `bytes.len` matches
    /// `f.byteLength()`; a caller with the wrong length has already picked
    /// the wrong format, which is a programmer error, not a data error.
    pub fn fromBytes(f: Format, bytes: []const u8) Oid {
        std.debug.assert(bytes.len == f.byteLength());
        return switch (f) {
            .sha1 => .{ .sha1 = bytes[0..20].* },
            .sha256 => .{ .sha256 = bytes[0..32].* },
        };
    }

    /// Decodes `s` as a hex id of format `f`. Rejects any length other than
    /// `f.formattedLength()`, any uppercase letter, and any non-hex byte.
    pub fn parse(f: Format, s: []const u8) ParseError!Oid {
        if (s.len != f.formattedLength()) return error.InvalidOid;
        var bytes: [max_byte_length]u8 = undefined;
        var i: usize = 0;
        while (i < f.byteLength()) : (i += 1) {
            const hi = try hexNibble(s[i * 2]);
            const lo = try hexNibble(s[i * 2 + 1]);
            bytes[i] = (hi << 4) | lo;
        }
        return fromBytes(f, bytes[0..f.byteLength()]);
    }

    /// Decodes `s`, picking the format from its length: 40 characters is
    /// sha1, 64 is sha256. Any other length is rejected.
    pub fn parseAny(s: []const u8) ParseError!Oid {
        return switch (s.len) {
            40 => parse(.sha1, s),
            64 => parse(.sha256, s),
            else => error.InvalidOid,
        };
    }

    /// Raw digest bytes, borrowed from `oid`. Valid as long as `oid` is.
    pub fn slice(oid: *const Oid) []const u8 {
        return switch (oid.*) {
            inline else => |*bytes| bytes,
        };
    }

    /// Writes the lowercase hex digest to `w`.
    pub fn format(oid: Oid, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [max_formatted_length]u8 = undefined;
        try w.writeAll(oid.toHex(&buf));
    }

    /// Writes the lowercase hex digest into `buf` and returns the written
    /// part of `buf`, `oid`'s format's `formattedLength()` bytes long.
    pub fn toHex(oid: Oid, buf: *[max_formatted_length]u8) []const u8 {
        const digits = "0123456789abcdef";
        return switch (oid) {
            inline else => |bytes| blk: {
                for (bytes, 0..) |byte, i| {
                    buf[i * 2] = digits[byte >> 4];
                    buf[i * 2 + 1] = digits[byte & 0x0f];
                }
                break :blk buf[0 .. bytes.len * 2];
            },
        };
    }

    /// True when `a` and `b` hold the same format and the same bytes. Ids of
    /// different formats are simply unequal, never an error.
    pub fn eql(a: Oid, b: Oid) bool {
        if (@as(Format, a) != @as(Format, b)) return false;
        return switch (a) {
            inline else => |bytes, tag| std.mem.eql(u8, &bytes, &@field(b, @tagName(tag))),
        };
    }

    /// Byte-wise order of `a` and `b`. Asserts `a` and `b` share a format;
    /// comparing ids across formats is a caller mistake, not a data error.
    pub fn order(a: Oid, b: Oid) std.math.Order {
        std.debug.assert(@as(Format, a) == @as(Format, b));
        return switch (a) {
            inline else => |bytes, tag| std.mem.order(u8, &bytes, &@field(b, @tagName(tag))),
        };
    }

    /// True when the hex digest of `oid` starts with `hex_prefix`.
    /// `hex_prefix` may have odd length; an empty prefix always matches.
    /// A prefix longer than the digest never matches.
    pub fn hasPrefix(oid: Oid, hex_prefix: []const u8) bool {
        const f: Format = oid;
        if (hex_prefix.len > f.formattedLength()) return false;
        var buf: [max_formatted_length]u8 = undefined;
        const hex = oid.toHex(&buf);
        return std.mem.eql(u8, hex[0..hex_prefix.len], hex_prefix);
    }
};

/// Decodes one hex digit. Rejects uppercase explicitly rather than
/// case-folding first, so `Oid.parse` never accepts two spellings of one id.
fn hexNibble(c: u8) Oid.ParseError!u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => error.InvalidOid,
    };
}

const sha1_empty = "da39a3ee5e6b4b0d3255bfef95601890afd80709";
const sha256_empty = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

// expected

test "parse accepts a 40 character lowercase sha1" {
    const oid = try Oid.parse(.sha1, sha1_empty);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings(sha1_empty, oid.toHex(&buf));
}

test "parse accepts a 64 character sha256" {
    const oid = try Oid.parse(.sha256, sha256_empty);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings(sha256_empty, oid.toHex(&buf));
}

test "format writes lowercase hex of the full digest" {
    const oid = try Oid.parse(.sha1, sha1_empty);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try oid.format(&w);
    try std.testing.expectEqualStrings(sha1_empty, w.buffered());
}

test "parseAny picks sha1 for 40 characters and sha256 for 64" {
    const sha1_oid = try Oid.parseAny(sha1_empty);
    const sha256_oid = try Oid.parseAny(sha256_empty);
    try std.testing.expectEqual(Format.sha1, @as(Format, sha1_oid));
    try std.testing.expectEqual(Format.sha256, @as(Format, sha256_oid));
}

test "fromBytes then slice returns the same bytes" {
    const bytes = [_]u8{0xab} ** 20;
    const oid = Oid.fromBytes(.sha1, &bytes);
    try std.testing.expectEqualSlices(u8, &bytes, oid.slice());
}

// suspicious

test "parse rejects uppercase hex" {
    try std.testing.expectError(
        error.InvalidOid,
        Oid.parse(.sha1, "DA39A3EE5E6B4B0D3255BFEF95601890AFD80709"),
    );
}

test "parse rejects a 39 character string" {
    try std.testing.expectError(error.InvalidOid, Oid.parse(.sha1, sha1_empty[0..39]));
}

test "parse rejects a 41 character string" {
    try std.testing.expectError(error.InvalidOid, Oid.parse(.sha1, sha1_empty ++ "0"));
}

test "parse rejects a non hex character" {
    try std.testing.expectError(
        error.InvalidOid,
        Oid.parse(.sha1, "gg39a3ee5e6b4b0d3255bfef95601890afd80709"),
    );
}

test "parseAny rejects a length that is neither 40 nor 64" {
    try std.testing.expectError(error.InvalidOid, Oid.parseAny(sha1_empty[0..39]));
}

test "eql is false for a sha1 and a sha256 holding the same leading bytes" {
    const bytes20 = [_]u8{0xaa} ** 20;
    const bytes32 = [_]u8{0xaa} ** 32;
    const sha1_oid = Oid.fromBytes(.sha1, &bytes20);
    const sha256_oid = Oid.fromBytes(.sha256, &bytes32);
    try std.testing.expect(!sha1_oid.eql(sha256_oid));
}

test "zero is all zero bytes and isZero agrees" {
    const oid = Oid.zero(.sha256);
    try std.testing.expect(oid.isZero());
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), oid.slice());
}

test "hasPrefix accepts an odd length prefix" {
    const oid = try Oid.parse(.sha1, sha1_empty);
    try std.testing.expect(oid.hasPrefix(sha1_empty[0..3]));
}

test "hasPrefix rejects a prefix longer than the digest" {
    const oid = try Oid.parse(.sha1, sha1_empty);
    try std.testing.expect(!oid.hasPrefix(sha1_empty ++ "0"));
}
