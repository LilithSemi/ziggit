//! Refspecs: the "+src:dst" syntax fetch uses to say which remote refs to
//! ask for, and which local ref, if any, each one updates.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Refspec = struct {
    force: bool,
    /// Owned; freed by deinit.
    src: []const u8,
    /// Owned; freed by deinit. Null for a fetch with no local destination:
    /// the object still gets fetched, but no ref in this repository is
    /// updated for it.
    dst: ?[]const u8,

    pub const ParseError = error{InvalidRefspec} || Allocator.Error;

    /// Parses one refspec: an optional leading "+" for force, a source,
    /// and an optional ":destination". Dupes both strings; the caller
    /// owns the returned `Refspec` and frees it with `deinit`.
    pub fn parse(gpa: Allocator, text: []const u8) ParseError!Refspec {
        var rest = text;
        var force = false;
        if (rest.len > 0 and rest[0] == '+') {
            force = true;
            rest = rest[1..];
        }

        const colon = std.mem.indexOfScalar(u8, rest, ':');
        const src_slice = if (colon) |c| rest[0..c] else rest;
        if (src_slice.len == 0) return error.InvalidRefspec;

        const dst_slice: ?[]const u8 = if (colon) |c| blk: {
            const d = rest[c + 1 ..];
            break :blk if (d.len == 0) null else d;
        } else null;

        const src = try gpa.dupe(u8, src_slice);
        errdefer gpa.free(src);
        const dst = if (dst_slice) |d| try gpa.dupe(u8, d) else null;
        errdefer if (dst) |d| gpa.free(d);

        return .{ .force = force, .src = src, .dst = dst };
    }

    /// Frees the src and dst strings this refspec owns.
    pub fn deinit(r: *Refspec, gpa: Allocator) void {
        gpa.free(r.src);
        if (r.dst) |d| gpa.free(d);
        r.* = undefined;
    }

    /// The local destination `ref_name` maps to through `r`, or null when
    /// `r`'s source does not name `ref_name`, or `r` names no local
    /// destination at all. On a match, the caller owns the returned slice
    /// and frees it with `gpa`.
    pub fn match(r: Refspec, gpa: Allocator, ref_name: []const u8) Allocator.Error!?[]u8 {
        if (!matchesSource(r, ref_name)) return null;
        const dst = r.dst orelse return null;

        if (isWildcard(r.src)) {
            // `matchesSource` already confirmed `ref_name` carries `src`'s
            // fixed prefix; `dst` must carry a matching wildcard of its
            // own for a suffix to have anywhere to go.
            if (!isWildcard(dst)) return null;
            const suffix = ref_name[r.src.len - 1 ..];
            return try std.fmt.allocPrint(gpa, "{s}{s}", .{ dst[0 .. dst.len - 1], suffix });
        }
        return try gpa.dupe(u8, dst);
    }
};

/// True when `r`'s source pattern names `ref_name`: an exact match when
/// `src` has no wildcard, a shared prefix up to the trailing "*"
/// otherwise. Exposed at file scope, not as a method on `Refspec`, since
/// deciding which remote refs a fetch wants (`remote.zig`) needs this
/// independent of whether `r` also names a local destination, and the
/// brief fixes `Refspec`'s own public surface to `parse` and `match`.
pub fn matchesSource(r: Refspec, ref_name: []const u8) bool {
    if (isWildcard(r.src)) {
        return std.mem.startsWith(u8, ref_name, r.src[0 .. r.src.len - 1]);
    }
    return std.mem.eql(u8, r.src, ref_name);
}

fn isWildcard(pattern: []const u8) bool {
    return std.mem.endsWith(u8, pattern, "*");
}

const testing = std.testing;

// expected

test "a parsed refspec outlives the buffer it was parsed from" {
    const gpa = testing.allocator;
    const text = try gpa.dupe(u8, "+refs/heads/main:refs/remotes/origin/main");

    var r = try Refspec.parse(gpa, text);
    // Buffer is freed; the refspec should still own its own copy
    gpa.free(text);

    try testing.expect(r.force);
    try testing.expectEqualStrings("refs/heads/main", r.src);
    try testing.expectEqualStrings("refs/remotes/origin/main", r.dst.?);

    r.deinit(gpa);
}

test "refspec parse reads force, source and destination" {
    const gpa = testing.allocator;
    var r = try Refspec.parse(gpa, "+refs/heads/main:refs/remotes/origin/main");
    defer r.deinit(gpa);
    try testing.expect(r.force);
    try testing.expectEqualStrings("refs/heads/main", r.src);
    try testing.expectEqualStrings("refs/remotes/origin/main", r.dst.?);
}

test "refspec match maps refs/heads/main through a wildcard" {
    const gpa = testing.allocator;
    var r = try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*");
    defer r.deinit(gpa);

    const dst = try r.match(gpa, "refs/heads/main");
    defer gpa.free(dst.?);
    try testing.expectEqualStrings("refs/remotes/origin/main", dst.?);
}

// suspicious

test "refspec parse rejects a spec with no source" {
    const gpa = testing.allocator;
    try testing.expectError(error.InvalidRefspec, Refspec.parse(gpa, ":refs/heads/main"));
}

test "refspec match returns null for a ref the spec does not cover" {
    const gpa = testing.allocator;
    var r = try Refspec.parse(gpa, "refs/heads/main:refs/heads/main");
    defer r.deinit(gpa);

    const dst = try r.match(gpa, "refs/heads/other");
    try testing.expect(dst == null);
}

test "refspec parse accepts a plain source with no colon and no destination" {
    const gpa = testing.allocator;
    var r = try Refspec.parse(gpa, "refs/heads/main");
    defer r.deinit(gpa);
    try testing.expect(!r.force);
    try testing.expectEqualStrings("refs/heads/main", r.src);
    try testing.expect(r.dst == null);
}

test "refspec match returns null when the spec names no local destination" {
    const gpa = testing.allocator;
    var r = try Refspec.parse(gpa, "refs/heads/main");
    defer r.deinit(gpa);

    const dst = try r.match(gpa, "refs/heads/main");
    try testing.expect(dst == null);
}

test "matchesSource is true for a ref covered only by a wildcard with no destination" {
    const gpa = testing.allocator;
    var r = try Refspec.parse(gpa, "refs/heads/*");
    defer r.deinit(gpa);
    try testing.expect(matchesSource(r, "refs/heads/main"));
    try testing.expect(!matchesSource(r, "refs/tags/v1"));
}
