//! Matches refspecs against the server's `ls-refs` listing: which objects
//! this fetch must ask for, and which local ref, if any, each one updates
//! once the pack lands.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Oid = oid_mod.Oid;
const Format = oid_mod.Format;

const proto = @import("ziggit-proto");
const RefLine = proto.RefLine;

const refspec_mod = @import("refspec.zig");
const Refspec = refspec_mod.Refspec;

/// One ref this fetch will update locally: a refspec matched a remote ref
/// line and named a local destination for it.
pub const PlannedUpdate = struct {
    /// Owned; freed by `deinit`.
    name: []u8,
    remote_oid: Oid,
    force: bool,
    /// The source ref name from the refspec that created this update. For
    /// branches, this is the short name like "main" from "refs/heads/main".
    /// For tags, this is the short name like "v1" from "refs/tags/v1".
    /// For raw object ids, this is the full hex oid. Owned; freed by `deinit`.
    src_name: []const u8,
    /// The full source ref (for matching against branch/tag patterns) or the
    /// object id (raw fetch source). Used to determine the kind for FETCH_HEAD.
    /// Owned; freed by `deinit`.
    src_full: []const u8,

    pub fn deinit(p: *PlannedUpdate, gpa: Allocator) void {
        gpa.free(p.name);
        gpa.free(p.src_name);
        gpa.free(p.src_full);
        p.* = undefined;
    }
};

pub const Plan = struct {
    /// Every distinct object id this fetch must ask the server for. Owned;
    /// freed by `deinit`.
    wants: []Oid,
    /// Every local ref this fetch will update once the pack lands. Owned;
    /// freed by `deinit`.
    updates: []PlannedUpdate,

    pub fn deinit(p: *Plan, gpa: Allocator) void {
        for (p.updates) |*u| u.deinit(gpa);
        gpa.free(p.updates);
        gpa.free(p.wants);
        p.* = undefined;
    }
};

pub const Error = error{ RefNotFound, ServerRefusesOidWant } || Allocator.Error;

/// Matches `refspecs` against `refs`, the server's `ls-refs` listing.
///
/// `error.RefNotFound` when a non-wildcard refspec's source names no ref
/// in `refs` at all: the remote does not have it, whether it never did or
/// it vanished between `ls-refs` and now, so there is nothing this fetch
/// could ask for. A wildcard refspec matching nothing is not an error: a
/// remote with no branches yet is normal. Object id sources bypass the
/// ref matching: a source that is `format`'s formatted length in lowercase
/// hex is treated as a direct want without requiring a matching advertised
/// ref.
pub fn buildPlan(gpa: Allocator, format: Format, refspecs: []const Refspec, refs: []const RefLine) Error!Plan {
    var wants: std.ArrayList(Oid) = .empty;
    errdefer wants.deinit(gpa);
    var updates: std.ArrayList(PlannedUpdate) = .empty;
    errdefer {
        for (updates.items) |*u| u.deinit(gpa);
        updates.deinit(gpa);
    }

    for (refspecs) |rs| {
        if (isObjectId(format, rs.src)) {
            const oid = Oid.parse(format, rs.src) catch return error.RefNotFound;
            if (!containsOid(wants.items, oid)) try wants.append(gpa, oid);
            if (rs.dst) |dst_pattern| {
                const dst = try gpa.dupe(u8, dst_pattern);
                const src_name = try gpa.dupe(u8, rs.src);
                const src_full = try gpa.dupe(u8, rs.src);
                updates.append(gpa, .{ .name = dst, .remote_oid = oid, .force = rs.force, .src_name = src_name, .src_full = src_full }) catch |err| {
                    gpa.free(dst);
                    gpa.free(src_name);
                    gpa.free(src_full);
                    return err;
                };
            }
            continue;
        }

        var matched_any = false;
        for (refs) |ref| {
            if (!refspec_mod.matchesSource(rs, ref.name)) continue;
            matched_any = true;

            if (!containsOid(wants.items, ref.oid)) try wants.append(gpa, ref.oid);

            if (try rs.match(gpa, ref.name)) |dst| {
                const short_name = shortRefName(ref.name);
                const src_name = try gpa.dupe(u8, short_name);
                const src_full = try gpa.dupe(u8, ref.name);
                updates.append(gpa, .{ .name = dst, .remote_oid = ref.oid, .force = rs.force, .src_name = src_name, .src_full = src_full }) catch |err| {
                    gpa.free(dst);
                    gpa.free(src_name);
                    gpa.free(src_full);
                    return err;
                };
            }
        }
        if (!matched_any and !endsWithStar(rs.src)) return error.RefNotFound;
    }

    return .{ .wants = try wants.toOwnedSlice(gpa), .updates = try updates.toOwnedSlice(gpa) };
}

fn containsOid(oids: []const Oid, oid: Oid) bool {
    for (oids) |o| {
        if (o.eql(oid)) return true;
    }
    return false;
}

fn endsWithStar(src: []const u8) bool {
    return std.mem.endsWith(u8, src, "*");
}

/// Extracts the short name from a refspec source. For a branch or tag ref,
/// this is the text after the last slash. For a raw object id, this is the
/// full hex string. For example:
///   "refs/heads/main" -> "main"
///   "refs/tags/v1" -> "v1"
///   "abc123..." -> "abc123..."
fn shortRefName(src: []const u8) []const u8 {
    // Object ids have no slashes; refs do. If there is no slash, it is an object id.
    if (std.mem.lastIndexOfScalar(u8, src, '/')) |idx| {
        return src[idx + 1 ..];
    }
    return src;
}

/// True when `src` is a valid object id in `format`: exactly
/// `format.formattedLength()` lowercase hex characters. A sha1 repository
/// and a sha256 repository disagree on that length, so the caller must
/// pass the repository's own format rather than a fixed length; this is
/// shared by both fetch strategies so the two cannot drift apart.
pub fn isObjectId(format: Format, src: []const u8) bool {
    if (src.len != format.formattedLength()) return false;
    for (src) |c| {
        if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) return false;
    }
    return true;
}

const testing = std.testing;

fn line(oid_hex: []const u8, name: []const u8) RefLine {
    return .{
        .oid = Oid.parse(.sha1, oid_hex) catch unreachable,
        .name = name,
        .peeled = null,
        .symref_target = null,
    };
}

// expected

test "buildPlan wants every ref a wildcard refspec matches, once each" {
    const gpa = testing.allocator;
    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    const refs = [_]RefLine{
        line("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "refs/heads/main"),
        line("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "refs/heads/dev"),
        line("cccccccccccccccccccccccccccccccccccccccc", "refs/tags/v1"),
    };

    var plan = try buildPlan(gpa, .sha1, &rs, &refs);
    defer plan.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), plan.wants.len);
    try testing.expectEqual(@as(usize, 2), plan.updates.len);
}

test "buildPlan names the mapped local destination for each update" {
    const gpa = testing.allocator;
    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    const refs = [_]RefLine{line("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "refs/heads/main")};

    var plan = try buildPlan(gpa, .sha1, &rs, &refs);
    defer plan.deinit(gpa);

    try testing.expectEqualStrings("refs/remotes/origin/main", plan.updates[0].name);
    try testing.expect(plan.updates[0].force);
}

// suspicious

test "buildPlan reports RefNotFound when a literal refspec's source is absent from the listing" {
    const gpa = testing.allocator;
    var rs = [_]Refspec{try Refspec.parse(gpa, "refs/heads/gone:refs/remotes/origin/gone")};
    defer for (&rs) |*r| r.deinit(gpa);
    const refs = [_]RefLine{line("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "refs/heads/main")};

    try testing.expectError(error.RefNotFound, buildPlan(gpa, .sha1, &rs, &refs));
}

test "buildPlan matching zero refs under a wildcard is not an error" {
    const gpa = testing.allocator;
    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    const refs = [_]RefLine{line("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "refs/tags/v1")};

    var plan = try buildPlan(gpa, .sha1, &rs, &refs);
    defer plan.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), plan.wants.len);
    try testing.expectEqual(@as(usize, 0), plan.updates.len);
}

test "buildPlan wants an object once even when two refspecs match the same ref" {
    const gpa = testing.allocator;
    var rs = [_]Refspec{
        try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*"),
        try Refspec.parse(gpa, "refs/heads/main:refs/heads/main"),
    };
    defer for (&rs) |*r| r.deinit(gpa);
    const refs = [_]RefLine{line("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "refs/heads/main")};

    var plan = try buildPlan(gpa, .sha1, &rs, &refs);
    defer plan.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), plan.wants.len);
    try testing.expectEqual(@as(usize, 2), plan.updates.len);
}

// OID refspec support tests

test "a refspec whose source is an object id sends a want for it" {
    const gpa = testing.allocator;
    var rs = [_]Refspec{try Refspec.parse(gpa, "+aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:refs/remotes/origin/pinned")};
    defer for (&rs) |*r| r.deinit(gpa);
    const refs = [_]RefLine{};

    var plan = try buildPlan(gpa, .sha1, &rs, &refs);
    defer plan.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), plan.wants.len);
    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    try testing.expectEqualStrings("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", plan.wants[0].toHex(&hex_buf));
    try testing.expectEqual(@as(usize, 1), plan.updates.len);
    try testing.expectEqualStrings("refs/remotes/origin/pinned", plan.updates[0].name);
}
