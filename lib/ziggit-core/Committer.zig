//! Who is writing, held apart from when: one `Committer` describes every
//! write a session makes, while the clock supplies the moment of each one
//! through `at`.

const identity_mod = @import("Identity.zig");
const Identity = identity_mod.Identity;

pub const Committer = struct {
    /// Borrowed. The caller keeps this alive for as long as it uses the
    /// `Committer`, and for as long as any `Identity` built from it is
    /// still in use.
    name: []const u8,
    /// Borrowed. Same lifetime rule as `name`.
    email: []const u8,
    /// Minutes east of UTC. `std.Io` and `std.time` carry no timezone
    /// API, and `std.tz` only parses a TZif stream, it does not locate
    /// the local zone file, so a caller that wants a local offset must
    /// find and read that file itself (`tzif.offsetFromTzif` turns the
    /// bytes into minutes) and supply the result here.
    tz_offset_minutes: i16 = 0,
    /// See `Identity.tz_negative_zero`: set this only to record a `-0000`
    /// offset, not a plain `+0000`.
    tz_negative_zero: bool = false,

    /// Builds the `Identity` for a write happening at `when`, in unix
    /// seconds.
    pub fn at(c: Committer, when: i64) Identity {
        return .{
            .name = c.name,
            .email = c.email,
            .when = when,
            .tz_offset_minutes = c.tz_offset_minutes,
            .tz_negative_zero = c.tz_negative_zero,
        };
    }
};

// expected

const std = @import("std");

test "Committer.at builds an Identity carrying the given time" {
    const committer: Committer = .{ .name = "A U Thor", .email = "author@example.com" };
    const id = committer.at(1234567890);
    try std.testing.expectEqualStrings("A U Thor", id.name);
    try std.testing.expectEqualStrings("author@example.com", id.email);
    try std.testing.expectEqual(@as(i64, 1234567890), id.when);
    try std.testing.expectEqual(@as(i16, 0), id.tz_offset_minutes);
}

test "Committer.at carries a non-zero tz offset into the Identity" {
    const committer: Committer = .{ .name = "A U Thor", .email = "author@example.com", .tz_offset_minutes = 330 };
    const id = committer.at(1234567890);
    try std.testing.expectEqual(@as(i16, 330), id.tz_offset_minutes);
}
