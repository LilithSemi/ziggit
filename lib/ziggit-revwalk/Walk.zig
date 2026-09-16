//! Commit graph walking: a set of starting points, a set of excluded
//! points, and the reverse chronological order between them; reachability
//! counting; and the bounded ancestry check a fast-forward decision needs.
//!
//! Every walk below reads the graph exactly once per object it ever
//! touches, tracked in a `seen` set, regardless of how many parents point
//! at it or whether some of those parent pointers form a cycle: a commit
//! graph read off disk came from whoever wrote that repository, so a
//! parent pointer forming a loop is corrupt data to walk safely past, not
//! an impossible state to assert against. An object this cannot read is a
//! dead end only when the shallow file names it, which is exactly what a
//! shallow clone's missing parent looks like. Anywhere else, an unreadable
//! object is corruption and fails the walk: a count of reachable commits
//! reaches Nix as `revCount`, so an under-count must not pass for an
//! answer.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Oid = oid_mod.Oid;
const Format = oid_mod.Format;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;

const object_mod = @import("ziggit-object");
const Commit = object_mod.Commit;

const repo_mod = @import("ziggit-repo");
const Repository = repo_mod.Repository;
const readShallowBoundary = repo_mod.readShallowBoundary;

const revparse_mod = @import("revparse.zig");
const Error = revparse_mod.Error;

/// Allocation budget for reading one commit object whole, while walking.
/// A commit's headers and message comfortably fit; this is a policy
/// ceiling against a hostile commit, not a spec limit.
const max_commit_object_len: usize = 1 << 20;

/// How many commits `isAncestor`'s bounded search visits before giving up
/// and reporting "not an ancestor". Generous headroom for a real history,
/// and a hard stop against a hostile or unbounded one. `Walk` and
/// `countReachable` need no such bound: their own `seen` set already caps
/// total work at the number of distinct objects actually in the graph,
/// and clipping a legitimate large history's exact count or membership
/// would make them wrong, not merely slow.
const max_ancestry_walk: usize = 100_000;

/// Reads every commit reachable from `roots` into `times` (oid -> commit
/// time), each recorded once no matter how many paths reach it or whether
/// the graph loops. A commit named in `shallow` is an expected dead end and
/// does not error when unreadable. A missing or corrupt commit anywhere
/// else is a fatal error: returns `error.CorruptObject`. Only
/// `error.OutOfMemory` escapes from allocator failures.
fn collectReachable(
    gpa: Allocator,
    repo: *Repository,
    roots: []const Oid,
    times: *std.AutoHashMapUnmanaged(Oid, i64),
    shallow: std.AutoHashMapUnmanaged(Oid, void),
    diag: ?*?Diagnostic,
) Error!void {
    var seen: std.AutoHashMapUnmanaged(Oid, void) = .empty;
    defer seen.deinit(gpa);
    var stack: std.ArrayList(Oid) = .empty;
    defer stack.deinit(gpa);

    for (roots) |r| {
        if (seen.contains(r)) continue;
        try seen.put(gpa, r, {});
        try stack.append(gpa, r);
    }

    while (stack.pop()) |current| {
        const bytes = repo.odb.readAlloc(gpa, current, max_commit_object_len, diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                if (shallow.contains(current)) continue;
                return error.CorruptObject;
            },
        };
        defer gpa.free(bytes);

        var commit = Commit.parse(gpa, repo.format, bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CorruptCommit => {
                if (shallow.contains(current)) continue;
                return error.CorruptObject;
            },
        };
        defer commit.deinit(gpa);

        try times.put(gpa, current, commit.committer.when);
        for (commit.parents) |p| {
            if (seen.contains(p)) continue;
            try seen.put(gpa, p, {});
            try stack.append(gpa, p);
        }
    }
}

const Entry = struct { oid: Oid, when: i64 };

fn newestFirst(_: void, a: Entry, b: Entry) bool {
    return a.when > b.when;
}

/// Walks the commit graph from a set of pushed starting points, excluding
/// anything reachable from a set of hidden points, newest first.
pub const Walk = struct {
    gpa: Allocator,
    repo: *Repository,
    pushed: std.ArrayList(Oid) = .empty,
    hidden: std.ArrayList(Oid) = .empty,
    /// Computed lazily, on the first call to `next`, and cached: every
    /// visible commit, newest first. Owned, freed by `deinit`.
    ordered: ?[]Oid = null,
    cursor: usize = 0,

    pub fn init(gpa: Allocator, repo: *Repository) Walk {
        return .{ .gpa = gpa, .repo = repo };
    }

    pub fn deinit(w: *Walk) void {
        w.pushed.deinit(w.gpa);
        w.hidden.deinit(w.gpa);
        if (w.ordered) |o| w.gpa.free(o);
        w.* = undefined;
    }

    /// Adds `oid` as a starting point: `next` will yield it, and every
    /// commit it can reach, unless `hide` also excludes it.
    pub fn push(w: *Walk, oid: Oid) Error!void {
        try w.pushed.append(w.gpa, oid);
    }

    /// Excludes `oid`, and everything it reaches, from `next`.
    pub fn hide(w: *Walk, oid: Oid) Error!void {
        try w.hidden.append(w.gpa, oid);
    }

    fn ensureComputed(w: *Walk) Error!void {
        if (w.ordered != null) return;

        var shallow = try readShallowBoundary(w.gpa, w.repo.io, w.repo.layout.common_dir, w.repo.format, null);
        defer shallow.deinit(w.gpa);

        var visible: std.AutoHashMapUnmanaged(Oid, i64) = .empty;
        defer visible.deinit(w.gpa);
        try collectReachable(w.gpa, w.repo, w.pushed.items, &visible, shallow, null);

        if (w.hidden.items.len > 0) {
            var excluded: std.AutoHashMapUnmanaged(Oid, i64) = .empty;
            defer excluded.deinit(w.gpa);
            try collectReachable(w.gpa, w.repo, w.hidden.items, &excluded, shallow, null);
            var it = excluded.keyIterator();
            while (it.next()) |k| _ = visible.remove(k.*);
        }

        var list: std.ArrayList(Entry) = .empty;
        defer list.deinit(w.gpa);
        var vit = visible.iterator();
        while (vit.next()) |e| {
            try list.append(w.gpa, .{ .oid = e.key_ptr.*, .when = e.value_ptr.* });
        }

        std.mem.sort(Entry, list.items, {}, newestFirst);

        const out = try w.gpa.alloc(Oid, list.items.len);
        for (list.items, 0..) |e, i| out[i] = e.oid;
        w.ordered = out;
    }

    /// The next commit in reverse chronological order, or null when done.
    pub fn next(w: *Walk) Error!?Oid {
        try w.ensureComputed();
        const items = w.ordered.?;
        if (w.cursor >= items.len) return null;
        const oid = items[w.cursor];
        w.cursor += 1;
        return oid;
    }
};

/// How many commits are reachable from `oid`, each counted once no matter
/// how many paths reach it. A commit named in the repository's shallow
/// boundary is an expected dead end and does not cause an error. A missing
/// or corrupt commit anywhere else is a fatal error: returns
/// `error.CorruptObject`.
pub fn countReachable(gpa: Allocator, repo: *Repository, oid: Oid) Error!u32 {
    var shallow = try readShallowBoundary(gpa, repo.io, repo.layout.common_dir, repo.format, null);
    defer shallow.deinit(gpa);

    var times: std.AutoHashMapUnmanaged(Oid, i64) = .empty;
    defer times.deinit(gpa);
    try collectReachable(gpa, repo, &.{oid}, &times, shallow, null);
    return @intCast(times.count());
}

/// True when `old` is `new` itself or is reachable by following `new`'s
/// parent chain, bounded by `max_ancestry_walk` so a hostile or corrupt
/// graph cannot make this run forever. Walks depth first, off an explicit
/// stack rather than recursion, since a hostile commit graph could nest
/// arbitrarily deep; a `visited` set bounds the total work regardless of
/// order and keeps a cycle from looping. An object the walk cannot read
/// or cannot parse as a commit simply dead-ends that branch of the
/// search rather than failing the whole check: it is evidence against a
/// fast forward, not a fault in this walk. `diag`, when given, carries
/// detail for whichever one of those reads or parses last failed.
///
/// Shared by `Fetcher.applyRefUpdates`'s fast-forward check, so this and
/// only this is what decides that question; it used to be a private copy
/// inside `ziggit-fetch`.
pub fn isAncestor(gpa: Allocator, repo: *Repository, old: Oid, new: Oid, diag: ?*?Diagnostic) Allocator.Error!bool {
    if (old.eql(new)) return true;

    var visited: std.AutoHashMapUnmanaged(Oid, void) = .empty;
    defer visited.deinit(gpa);
    var stack: std.ArrayList(Oid) = .empty;
    defer stack.deinit(gpa);

    try stack.append(gpa, new);
    try visited.put(gpa, new, {});

    var steps: usize = 0;
    while (stack.pop()) |current| {
        if (current.eql(old)) return true;
        steps += 1;
        if (steps > max_ancestry_walk) return false;

        const bytes = repo.odb.readAlloc(gpa, current, max_commit_object_len, diag) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer gpa.free(bytes);

        var commit = Commit.parse(gpa, repo.format, bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CorruptCommit => continue,
        };
        defer commit.deinit(gpa);

        for (commit.parents) |p| {
            if (visited.contains(p)) continue;
            try visited.put(gpa, p, {});
            try stack.append(gpa, p);
        }
    }
    return false;
}

// Test helpers shared by every test below.

const testing = std.testing;

const dummy_tree_hex = "4" ** 40;

fn buildMinimalRepo(io: std.Io, dir: std.Io.Dir) !void {
    try dir.createDirPath(io, "objects/pack");
    try dir.createDirPath(io, "refs/heads");
    try dir.writeFile(io, .{ .sub_path = "HEAD", .data = "ref: refs/heads/main\n" });
}

fn openTestRepo(gpa: Allocator, io: std.Io, dir: std.Io.Dir) !Repository {
    try buildMinimalRepo(io, dir);
    const layout = try repo_mod.discover(gpa, io, dir, .{}, null);
    return Repository.open(gpa, io, layout, .{}, null);
}

fn buildCommitPayload(gpa: Allocator, parent_hexes: []const []const u8, when: i64, message: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.print("tree {s}\n", .{dummy_tree_hex});
    for (parent_hexes) |p| try out.writer.print("parent {s}\n", .{p});
    try out.writer.print("author A U Thor <author@example.com> {d} +0000\n", .{when});
    try out.writer.print("committer A U Thor <author@example.com> {d} +0000\n", .{when});
    try out.writer.print("\n{s}\n", .{message});
    return out.toOwnedSlice();
}

fn hexOf(oid: Oid, buf: *[Oid.max_formatted_length]u8) []const u8 {
    return oid.toHex(buf);
}

// A hand-rolled pack and index, built without going through `ziggit-pack`
// (this module has no production dependency on it): the two id-to-offset
// entries below are supplied directly rather than computed from content,
// which is exactly what lets a test place two commits whose parent
// pointers name each other, something no genuinely hash-consistent pair
// of objects could ever do. `Odb`'s pack backend never re-verifies an
// object's content against the id it was looked up by (only its loose
// backend does that), so this is read back exactly as written.

const FakePack = struct {
    bytes: []u8,
    offsets: []u64,

    fn deinit(fp: *FakePack, gpa: Allocator) void {
        gpa.free(fp.bytes);
        gpa.free(fp.offsets);
    }
};

fn writeVarintHeader(w: *std.Io.Writer, entry_type: u3, size_in: u64) !void {
    var value = size_in;
    var first_byte: u8 = (@as(u8, entry_type) << 4) | @as(u8, @truncate(value & 0x0f));
    value >>= 4;
    if (value != 0) first_byte |= 0x80;
    try w.writeByte(first_byte);
    while (value != 0) {
        var b: u8 = @truncate(value & 0x7f);
        value >>= 7;
        if (value != 0) b |= 0x80;
        try w.writeByte(b);
    }
}

fn writeZlibPayload(w: *std.Io.Writer, payload: []const u8) !void {
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compress = try std.compress.flate.Compress.init(w, &window, .zlib, .default);
    try compress.writer.writeAll(payload);
    try compress.finish();
}

fn buildFakePackFile(gpa: Allocator, payloads: []const []const u8) !FakePack {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("PACK");
    try w.writeInt(u32, 2, .big);
    try w.writeInt(u32, @intCast(payloads.len), .big);

    const offsets = try gpa.alloc(u64, payloads.len);
    errdefer gpa.free(offsets);
    for (payloads, 0..) |payload, i| {
        offsets[i] = aw.writer.buffered().len;
        try writeVarintHeader(w, 1, payload.len); // entry type 1: commit
        try writeZlibPayload(w, payload);
    }
    // Neither `Pack.open` nor this project's normal read path verifies
    // the trailing checksum; a placeholder of the right length is enough.
    const zero_trailer = [_]u8{0} ** 20;
    try w.writeAll(&zero_trailer);

    const bytes = try aw.toOwnedSlice();
    return .{ .bytes = bytes, .offsets = offsets };
}

/// Writes a v2 `.idx` mapping each of `entries` (already sorted ascending
/// by `oid`) straight to its given offset, with no relation whatsoever
/// asked of the object stored there.
fn writeFakeIndex(gpa: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, entries: []const struct { oid: Oid, offset: u64 }) !void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("\xfftOc");
    try w.writeInt(u32, 2, .big);

    var fanout: [256]u32 = undefined;
    {
        var bucket: u16 = 0;
        var count: u32 = 0;
        for (entries) |e| {
            const key = e.oid.slice()[0];
            while (bucket < key) : (bucket += 1) fanout[bucket] = count;
            count += 1;
        }
        while (bucket <= 255) : (bucket += 1) fanout[bucket] = count;
    }
    for (fanout) |v| try w.writeInt(u32, v, .big);
    for (entries) |e| try w.writeAll(e.oid.slice());
    for (entries) |_| try w.writeInt(u32, 0, .big); // crc32, never checked on read
    for (entries) |e| try w.writeInt(u32, @intCast(e.offset), .big);
    const zero_digest = [_]u8{0} ** 20;
    try w.writeAll(&zero_digest); // pack checksum, unvalidated by Index.open
    try w.writeAll(&zero_digest); // index checksum, unvalidated by Index.open

    try dir.writeFile(io, .{ .sub_path = sub_path, .data = aw.written() });
}

/// Places two commits, `a` and `b`, that each name the other as their
/// sole parent, reachable from `a`. Real, content-addressed objects can
/// never form this shape; this is a stand-in for whatever a hostile or
/// damaged repository's on-disk graph could contain.
fn buildFakeCycle(gpa: Allocator, io: std.Io, dir: std.Io.Dir, repo: *Repository) !struct { a: Oid, b: Oid } {
    const oid_a: Oid = .{ .sha1 = [_]u8{0x11} ** 20 };
    const oid_b: Oid = .{ .sha1 = [_]u8{0x22} ** 20 };

    var a_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    var b_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const a_hex = hexOf(oid_a, &a_hex_buf);
    const b_hex = hexOf(oid_b, &b_hex_buf);

    const payload_a = try buildCommitPayload(gpa, &.{b_hex}, 1000, "a");
    defer gpa.free(payload_a);
    const payload_b = try buildCommitPayload(gpa, &.{a_hex}, 2000, "b");
    defer gpa.free(payload_b);

    var built = try buildFakePackFile(gpa, &.{ payload_a, payload_b });
    defer built.deinit(gpa);

    try dir.writeFile(io, .{ .sub_path = "objects/pack/pack-fake.pack", .data = built.bytes });
    try writeFakeIndex(gpa, io, dir, "objects/pack/pack-fake.idx", &.{
        .{ .oid = oid_a, .offset = built.offsets[0] },
        .{ .oid = oid_b, .offset = built.offsets[1] },
    });
    try repo.odb.refreshPacks();

    return .{ .a = oid_a, .b = oid_b };
}

// expected

test "Walk yields a linear history newest first" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const p1 = try buildCommitPayload(gpa, &.{}, 1000, "one");
    defer gpa.free(p1);
    const c1 = try repo.odb.write(.commit, p1, null);
    var c1_hex_buf: [Oid.max_formatted_length]u8 = undefined;

    const p2 = try buildCommitPayload(gpa, &.{hexOf(c1, &c1_hex_buf)}, 2000, "two");
    defer gpa.free(p2);
    const c2 = try repo.odb.write(.commit, p2, null);
    var c2_hex_buf: [Oid.max_formatted_length]u8 = undefined;

    const p3 = try buildCommitPayload(gpa, &.{hexOf(c2, &c2_hex_buf)}, 3000, "three");
    defer gpa.free(p3);
    const c3 = try repo.odb.write(.commit, p3, null);

    var walk: Walk = .init(gpa, &repo);
    defer walk.deinit();
    try walk.push(c3);

    try testing.expect((try walk.next()).?.eql(c3));
    try testing.expect((try walk.next()).?.eql(c2));
    try testing.expect((try walk.next()).?.eql(c1));
    try testing.expectEqual(@as(?Oid, null), try walk.next());
}

test "Walk yields every commit of a merge exactly once" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const base_payload = try buildCommitPayload(gpa, &.{}, 1000, "base");
    defer gpa.free(base_payload);
    const base = try repo.odb.write(.commit, base_payload, null);
    var base_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const base_hex = hexOf(base, &base_hex_buf);

    const p1_payload = try buildCommitPayload(gpa, &.{base_hex}, 2000, "p1");
    defer gpa.free(p1_payload);
    const p1 = try repo.odb.write(.commit, p1_payload, null);
    var p1_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const p1_hex = hexOf(p1, &p1_hex_buf);

    const p2_payload = try buildCommitPayload(gpa, &.{base_hex}, 3000, "p2");
    defer gpa.free(p2_payload);
    const p2 = try repo.odb.write(.commit, p2_payload, null);
    var p2_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const p2_hex = hexOf(p2, &p2_hex_buf);

    const merge_payload = try buildCommitPayload(gpa, &.{ p1_hex, p2_hex }, 4000, "merge");
    defer gpa.free(merge_payload);
    const merge = try repo.odb.write(.commit, merge_payload, null);

    var walk: Walk = .init(gpa, &repo);
    defer walk.deinit();
    try walk.push(merge);

    var seen: std.AutoHashMapUnmanaged(Oid, void) = .empty;
    defer seen.deinit(gpa);
    while (try walk.next()) |oid| {
        try testing.expect(!seen.contains(oid));
        try seen.put(gpa, oid, {});
    }
    try testing.expectEqual(@as(usize, 4), seen.count());
    try testing.expect(seen.contains(base));
    try testing.expect(seen.contains(p1));
    try testing.expect(seen.contains(p2));
    try testing.expect(seen.contains(merge));
}

test "hide excludes a commit and everything it reaches" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const p1 = try buildCommitPayload(gpa, &.{}, 1000, "one");
    defer gpa.free(p1);
    const c1 = try repo.odb.write(.commit, p1, null);
    var c1_hex_buf: [Oid.max_formatted_length]u8 = undefined;

    const p2 = try buildCommitPayload(gpa, &.{hexOf(c1, &c1_hex_buf)}, 2000, "two");
    defer gpa.free(p2);
    const c2 = try repo.odb.write(.commit, p2, null);
    var c2_hex_buf: [Oid.max_formatted_length]u8 = undefined;

    const p3 = try buildCommitPayload(gpa, &.{hexOf(c2, &c2_hex_buf)}, 3000, "three");
    defer gpa.free(p3);
    const c3 = try repo.odb.write(.commit, p3, null);
    var c3_hex_buf: [Oid.max_formatted_length]u8 = undefined;

    const p4 = try buildCommitPayload(gpa, &.{hexOf(c3, &c3_hex_buf)}, 4000, "four");
    defer gpa.free(p4);
    const c4 = try repo.odb.write(.commit, p4, null);

    var walk: Walk = .init(gpa, &repo);
    defer walk.deinit();
    try walk.push(c4);
    try walk.hide(c2);

    try testing.expect((try walk.next()).?.eql(c4));
    try testing.expect((try walk.next()).?.eql(c3));
    try testing.expectEqual(@as(?Oid, null), try walk.next());
}

test "countReachable counts a linear history" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const p1 = try buildCommitPayload(gpa, &.{}, 1000, "one");
    defer gpa.free(p1);
    const c1 = try repo.odb.write(.commit, p1, null);
    var c1_hex_buf: [Oid.max_formatted_length]u8 = undefined;

    const p2 = try buildCommitPayload(gpa, &.{hexOf(c1, &c1_hex_buf)}, 2000, "two");
    defer gpa.free(p2);
    const c2 = try repo.odb.write(.commit, p2, null);
    var c2_hex_buf: [Oid.max_formatted_length]u8 = undefined;

    const p3 = try buildCommitPayload(gpa, &.{hexOf(c2, &c2_hex_buf)}, 3000, "three");
    defer gpa.free(p3);
    const c3 = try repo.odb.write(.commit, p3, null);

    try testing.expectEqual(@as(u32, 3), try countReachable(gpa, &repo, c3));
}

// suspicious

test "Walk terminates on a history with a cycle rather than looping" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const cycle = try buildFakeCycle(gpa, io, tmp.dir, &repo);

    var walk: Walk = .init(gpa, &repo);
    defer walk.deinit();
    try walk.push(cycle.a);

    var count: usize = 0;
    while (try walk.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 2), count);
}

test "countReachable counts a commit reachable by two paths once" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const base_payload = try buildCommitPayload(gpa, &.{}, 1000, "base");
    defer gpa.free(base_payload);
    const base = try repo.odb.write(.commit, base_payload, null);
    var base_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const base_hex = hexOf(base, &base_hex_buf);

    const p1_payload = try buildCommitPayload(gpa, &.{base_hex}, 2000, "p1");
    defer gpa.free(p1_payload);
    const p1 = try repo.odb.write(.commit, p1_payload, null);
    var p1_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const p1_hex = hexOf(p1, &p1_hex_buf);

    const p2_payload = try buildCommitPayload(gpa, &.{base_hex}, 3000, "p2");
    defer gpa.free(p2_payload);
    const p2 = try repo.odb.write(.commit, p2_payload, null);
    var p2_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const p2_hex = hexOf(p2, &p2_hex_buf);

    const merge_payload = try buildCommitPayload(gpa, &.{ p1_hex, p2_hex }, 4000, "merge");
    defer gpa.free(merge_payload);
    const merge = try repo.odb.write(.commit, merge_payload, null);

    try testing.expectEqual(@as(u32, 4), try countReachable(gpa, &repo, merge));
}

// isAncestor: absorbed from `ziggit-fetch/Fetcher.zig`, where it lived as
// a private, inline copy `Fetcher.applyRefUpdates` used for its
// fast-forward check. These tests exercise the behaviour that copy
// documented and this file must preserve exactly; the ordinary
// true/false fast-forward cases stay covered end to end by
// `ziggit-fetch`'s own `applyRefUpdates` tests.

test "isAncestor is true when old is new itself" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const payload = try buildCommitPayload(gpa, &.{}, 1000, "solo");
    defer gpa.free(payload);
    const oid = try repo.odb.write(.commit, payload, null);

    try testing.expect(try isAncestor(gpa, &repo, oid, oid, null));
}

test "isAncestor treats a missing parent as a dead end, not a fault" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    // Names a parent that was never written to the odb at all: exactly
    // what a shallow clone's boundary looks like.
    const missing_hex = "f" ** 40;
    const tip_payload = try buildCommitPayload(gpa, &.{missing_hex}, 2000, "shallow tip");
    defer gpa.free(tip_payload);
    const tip = try repo.odb.write(.commit, tip_payload, null);

    const unrelated_payload = try buildCommitPayload(gpa, &.{}, 1000, "unrelated");
    defer gpa.free(unrelated_payload);
    const unrelated = try repo.odb.write(.commit, unrelated_payload, null);

    try testing.expect(!try isAncestor(gpa, &repo, unrelated, tip, null));
}

test "isAncestor stays false rather than looping when the graph has a cycle" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const cycle = try buildFakeCycle(gpa, io, tmp.dir, &repo);

    const unrelated_payload = try buildCommitPayload(gpa, &.{}, 500, "unrelated");
    defer gpa.free(unrelated_payload);
    const unrelated = try repo.odb.write(.commit, unrelated_payload, null);

    try testing.expect(!try isAncestor(gpa, &repo, unrelated, cycle.a, null));
}

// shallow boundary

test "a commit at the shallow boundary is a dead end, not an error" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const missing_parent_hex = "f" ** 40;
    const boundary_payload = try buildCommitPayload(gpa, &.{missing_parent_hex}, 1000, "boundary");
    defer gpa.free(boundary_payload);
    const boundary = try repo.odb.write(.commit, boundary_payload, null);
    var boundary_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const boundary_hex = hexOf(boundary, &boundary_hex_buf);

    const tip_payload = try buildCommitPayload(gpa, &.{boundary_hex}, 2000, "tip");
    defer gpa.free(tip_payload);
    const tip = try repo.odb.write(.commit, tip_payload, null);

    const shallow_content = try std.fmt.allocPrint(gpa, "{s}\n", .{missing_parent_hex});
    defer gpa.free(shallow_content);
    try repo.layout.common_dir.writeFile(io, .{ .sub_path = "shallow", .data = shallow_content });

    const count = try countReachable(gpa, &repo, tip);
    try testing.expectEqual(@as(u32, 2), count);
}

test "a missing commit that is not at the shallow boundary is an error" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const missing_parent_hex = "a" ** 40;
    const tip_payload = try buildCommitPayload(gpa, &.{missing_parent_hex}, 1000, "tip with missing parent");
    defer gpa.free(tip_payload);
    const tip = try repo.odb.write(.commit, tip_payload, null);

    const result = countReachable(gpa, &repo, tip);
    try testing.expectError(error.CorruptObject, result);
}

test "a sha256 repository's shallow file parses" {
    // The shallow file holds ids of the repository's own hash format. A
    // reader that understands sha1 alone reports every sha256 repository
    // as corrupt and fails its whole walk.
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const hex = "b" ** 64;
    try tmp.dir.writeFile(io, .{ .sub_path = "shallow", .data = hex ++ "\n" });

    var boundary = try readShallowBoundary(gpa, io, tmp.dir, .sha256, null);
    defer boundary.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), boundary.count());
    try testing.expect(boundary.contains(try Oid.parse(.sha256, hex)));
}

test "a shallow line of the wrong length for the repository is corrupt" {
    // The other side of the bound above: one repository has one hash
    // format, so a sha1 id in a sha256 repository is corruption, not a
    // second format to accept alongside the first.
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "shallow", .data = "c" ** 40 ++ "\n" });

    try testing.expectError(
        error.CorruptObject,
        readShallowBoundary(gpa, io, tmp.dir, .sha256, null),
    );
}

test "countReachable counts a full history exactly" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const p1 = try buildCommitPayload(gpa, &.{}, 1000, "one");
    defer gpa.free(p1);
    const c1 = try repo.odb.write(.commit, p1, null);
    var c1_hex_buf: [Oid.max_formatted_length]u8 = undefined;

    const p2 = try buildCommitPayload(gpa, &.{hexOf(c1, &c1_hex_buf)}, 2000, "two");
    defer gpa.free(p2);
    const c2 = try repo.odb.write(.commit, p2, null);
    var c2_hex_buf: [Oid.max_formatted_length]u8 = undefined;

    const p3 = try buildCommitPayload(gpa, &.{hexOf(c2, &c2_hex_buf)}, 3000, "three");
    defer gpa.free(p3);
    const c3 = try repo.odb.write(.commit, p3, null);

    try testing.expectEqual(@as(u32, 3), try countReachable(gpa, &repo, c3));
}

test "countReachable counts a commit reachable two ways once" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const base_payload = try buildCommitPayload(gpa, &.{}, 1000, "base");
    defer gpa.free(base_payload);
    const base = try repo.odb.write(.commit, base_payload, null);
    var base_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const base_hex = hexOf(base, &base_hex_buf);

    const p1_payload = try buildCommitPayload(gpa, &.{base_hex}, 2000, "p1");
    defer gpa.free(p1_payload);
    const p1 = try repo.odb.write(.commit, p1_payload, null);
    var p1_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const p1_hex = hexOf(p1, &p1_hex_buf);

    const p2_payload = try buildCommitPayload(gpa, &.{base_hex}, 3000, "p2");
    defer gpa.free(p2_payload);
    const p2 = try repo.odb.write(.commit, p2_payload, null);
    var p2_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const p2_hex = hexOf(p2, &p2_hex_buf);

    const merge_payload = try buildCommitPayload(gpa, &.{ p1_hex, p2_hex }, 4000, "merge");
    defer gpa.free(merge_payload);
    const merge = try repo.odb.write(.commit, merge_payload, null);

    try testing.expectEqual(@as(u32, 4), try countReachable(gpa, &repo, merge));
}
