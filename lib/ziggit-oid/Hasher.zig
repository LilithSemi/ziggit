//! A streaming digest for one object id format.
//!
//! Wraps `std.crypto.hash.Sha1` and `std.crypto.hash.sha2.Sha256` behind one
//! union so a caller feeds bytes without branching on the format itself.

const std = @import("std");
const oid_mod = @import("Oid.zig");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;

pub const Hasher = union(Format) {
    sha1: std.crypto.hash.Sha1,
    sha256: std.crypto.hash.sha2.Sha256,

    pub fn init(f: Format) Hasher {
        return switch (f) {
            .sha1 => .{ .sha1 = std.crypto.hash.Sha1.init(.{}) },
            .sha256 => .{ .sha256 = std.crypto.hash.sha2.Sha256.init(.{}) },
        };
    }

    pub fn update(h: *Hasher, bytes: []const u8) void {
        switch (h.*) {
            inline else => |*hasher| hasher.update(bytes),
        }
    }

    /// Finishes the digest and returns it as an `Oid`. `h` must not be used
    /// again after this call.
    pub fn final(h: *Hasher) Oid {
        return switch (h.*) {
            inline else => |*hasher, tag| blk: {
                var digest: [tag.byteLength()]u8 = undefined;
                hasher.final(&digest);
                break :blk Oid.fromBytes(tag, &digest);
            },
        };
    }
};

test "Hasher sha1 of an empty input is da39a3ee5e6b4b0d3255bfef95601890afd80709" {
    var hasher = Hasher.init(.sha1);
    hasher.update("");
    const oid = hasher.final();
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings(
        "da39a3ee5e6b4b0d3255bfef95601890afd80709",
        oid.toHex(&buf),
    );
}

test "Hasher sha256 of an empty input is e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" {
    var hasher = Hasher.init(.sha256);
    hasher.update("");
    const oid = hasher.final();
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        oid.toHex(&buf),
    );
}
