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

/// Visit budget for walks that must cover the whole graph they are given.
const unbounded_walk: usize = std.math.maxInt(usize);

/// Reads every commit reachable from `roots` into `times` (oid -> commit
/// time), each recorded once no matter how many paths reach it or whether
/// the graph loops. A commit named in `shallow` is an expected dead end and
/// does not error when unreadable. A missing or corrupt commit anywhere
/// else is a fatal error: returns `error.CorruptObject`. Only
/// `error.OutOfMemory` escapes from allocator failures. Recording more than
/// `max_visits` commits returns `error.HistoryTooDeep`, which says the walk
/// ran out of budget rather than blaming the objects.
fn collectReachable(
    gpa: Allocator,
    repo: *Repository,
    roots: []const Oid,
    times: *std.AutoHashMapUnmanaged(Oid, i64),
    shallow: std.AutoHashMapUnmanaged(Oid, void),
    max_visits: usize,
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
        if (times.count() > max_visits) return error.HistoryTooDeep;
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
        try collectReachable(w.gpa, w.repo, w.pushed.items, &visible, shallow, unbounded_walk, null);

        if (w.hidden.items.len > 0) {
            var excluded: std.AutoHashMapUnmanaged(Oid, i64) = .empty;
            defer excluded.deinit(w.gpa);
            try collectReachable(w.gpa, w.repo, w.hidden.items, &excluded, shallow, unbounded_walk, null);
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
    try collectReachable(gpa, repo, &.{oid}, &times, shallow, unbounded_walk, null);
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
/// Reaching the bound returns `false`, which is fail closed rather than a
/// claim about the graph: the caller then refuses to move a ref it could
/// not prove is a fast forward. `mergeBases` errors in the same situation
/// because a partial answer there is a wrong answer, while here the
/// conservative action and the unproven one agree. Exhausting the budget
/// also usually does mean `old` is unreachable, since a real fast forward
/// finds its target within a few commits.
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

/// The best common ancestors of `a` and `b`, newest first. Two or more
/// results mean a criss-cross history. An empty slice means unrelated
/// histories. The caller frees the slice with `gpa`. A walk that exceeds
/// `max_ancestry_walk` commits fails with `error.HistoryTooDeep` rather
/// than return a base that might be wrong.
pub fn mergeBases(gpa: Allocator, repo: *Repository, a: Oid, b: Oid, diag: ?*?Diagnostic) Error![]Oid {
    return mergeBasesBounded(gpa, repo, a, b, max_ancestry_walk, diag);
}

/// The first of `mergeBases`, or null for unrelated histories.
pub fn mergeBase(gpa: Allocator, repo: *Repository, a: Oid, b: Oid, diag: ?*?Diagnostic) Error!?Oid {
    const bases = try mergeBases(gpa, repo, a, b, diag);
    defer gpa.free(bases);
    return if (bases.len == 0) null else bases[0];
}

/// `mergeBases` with an explicit visit budget for each of its walks.
fn mergeBasesBounded(gpa: Allocator, repo: *Repository, a: Oid, b: Oid, max_visits: usize, diag: ?*?Diagnostic) Error![]Oid {
    var shallow = try readShallowBoundary(gpa, repo.io, repo.layout.common_dir, repo.format, null);
    defer shallow.deinit(gpa);

    var from_a: std.AutoHashMapUnmanaged(Oid, i64) = .empty;
    defer from_a.deinit(gpa);
    try collectReachable(gpa, repo, &.{a}, &from_a, shallow, max_visits, diag);

    var from_b: std.AutoHashMapUnmanaged(Oid, i64) = .empty;
    defer from_b.deinit(gpa);
    try collectReachable(gpa, repo, &.{b}, &from_b, shallow, max_visits, diag);

    var common: std.ArrayList(Oid) = .empty;
    defer common.deinit(gpa);
    var it = from_a.iterator();
    while (it.next()) |e| {
        if (!from_b.contains(e.key_ptr.*)) continue;
        try common.append(gpa, e.key_ptr.*);
    }

    // A common commit is redundant when another common commit reaches it.
    // Every such commit is an ancestor of some parent of a common commit.
    var parents: std.ArrayList(Oid) = .empty;
    defer parents.deinit(gpa);
    for (common.items) |c| {
        const ps = try parentsOf(gpa, repo, c, diag);
        defer gpa.free(ps);
        try parents.appendSlice(gpa, ps);
    }
    var redundant: std.AutoHashMapUnmanaged(Oid, i64) = .empty;
    defer redundant.deinit(gpa);
    try collectReachable(gpa, repo, parents.items, &redundant, shallow, max_visits, diag);

    var bases: std.ArrayList(Oid) = .empty;
    defer bases.deinit(gpa);
    for (common.items) |c| {
        if (redundant.contains(c)) continue;
        try bases.append(gpa, c);
    }
    try rankBases(gpa, repo, a, b, &from_a, &from_b, bases.items, diag);

    return gpa.dupe(Oid, bases.items);
}

/// The parent ids of one commit. The caller frees the slice with `gpa`.
fn parentsOf(gpa: Allocator, repo: *Repository, oid: Oid, diag: ?*?Diagnostic) Error![]Oid {
    const bytes = try repo.odb.readAlloc(gpa, oid, max_commit_object_len, diag);
    defer gpa.free(bytes);

    var commit = Commit.parse(gpa, repo.format, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CorruptCommit => return error.CorruptObject,
    };
    defer commit.deinit(gpa);
    return gpa.dupe(Oid, commit.parents);
}

const paint_first: u8 = 1 << 0;
const paint_second: u8 = 1 << 1;
const paint_stale: u8 = 1 << 2;
const paint_result: u8 = 1 << 3;

const Pending = struct { oid: Oid, when: i64, seq: usize };

/// Newest first. On equal times, the entry pushed first comes first.
fn pendingFirst(_: void, x: Pending, y: Pending) std.math.Order {
    if (x.when != y.when) return std.math.order(y.when, x.when);
    return std.math.order(x.seq, y.seq);
}

fn committedAt(from_a: *const std.AutoHashMapUnmanaged(Oid, i64), from_b: *const std.AutoHashMapUnmanaged(Oid, i64), oid: Oid) ?i64 {
    return from_a.get(oid) orelse from_b.get(oid);
}

fn paintPush(
    gpa: Allocator,
    flags: *std.AutoHashMapUnmanaged(Oid, u8),
    queue: *std.PriorityQueue(Pending, void, pendingFirst),
    oid: Oid,
    bits: u8,
    when: i64,
    seq: *usize,
) Allocator.Error!void {
    try flags.put(gpa, oid, (flags.get(oid) orelse 0) | bits);
    try queue.push(gpa, .{ .oid = oid, .when = when, .seq = seq.* });
    seq.* += 1;
}

/// Sorts `bases` the way git's `merge-base` lists them: newest first, with
/// the order the paint reaches each base breaking ties. The paint pops the
/// newest commit first, starting from `a` and `b`. The sort is in place.
/// Every base must be one of the common commits `a` and `b` reach.
fn rankBases(
    gpa: Allocator,
    repo: *Repository,
    a: Oid,
    b: Oid,
    from_a: *const std.AutoHashMapUnmanaged(Oid, i64),
    from_b: *const std.AutoHashMapUnmanaged(Oid, i64),
    bases: []Oid,
    diag: ?*?Diagnostic,
) Error!void {
    if (bases.len < 2) return;

    var flags: std.AutoHashMapUnmanaged(Oid, u8) = .empty;
    defer flags.deinit(gpa);
    var rank: std.AutoHashMapUnmanaged(Oid, Ranked) = .empty;
    defer rank.deinit(gpa);
    var queue: std.PriorityQueue(Pending, void, pendingFirst) = .empty;
    defer queue.deinit(gpa);

    var seq: usize = 0;
    if (committedAt(from_a, from_b, a)) |when| try paintPush(gpa, &flags, &queue, a, paint_first, when, &seq);
    if (committedAt(from_a, from_b, b)) |when| try paintPush(gpa, &flags, &queue, b, paint_second, when, &seq);

    while (queue.pop()) |cur| {
        const have = flags.get(cur.oid).?;
        var bits = have & (paint_first | paint_second | paint_stale);
        if (bits == (paint_first | paint_second)) {
            if (have & paint_result == 0) {
                try flags.put(gpa, cur.oid, have | paint_result);
                try rank.put(gpa, cur.oid, .{ .when = cur.when, .seq = rank.count() });
            }
            bits |= paint_stale;
        }

        const ps = try parentsOf(gpa, repo, cur.oid, diag);
        defer gpa.free(ps);
        for (ps) |p| {
            const when = committedAt(from_a, from_b, p) orelse continue;
            if ((flags.get(p) orelse 0) & bits == bits) continue;
            try paintPush(gpa, &flags, &queue, p, bits, when, &seq);
        }
    }

    std.mem.sort(Oid, bases, &rank, rankedBefore);
}

/// A base's committer time, and how many bases the paint found before it.
const Ranked = struct { when: i64, seq: usize };

/// Newest first. On equal times, the base the paint found first comes first.
fn rankedBefore(rank: *std.AutoHashMapUnmanaged(Oid, Ranked), x: Oid, y: Oid) bool {
    const rx = rank.get(x).?;
    const ry = rank.get(y).?;
    if (rx.when != ry.when) return rx.when > ry.when;
    return rx.seq < ry.seq;
}

// Test helpers shared by every test below.

const testing = std.testing;

const dummy_tree_hex = &@as([40]u8, @splat('4'));

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
    const zero_trailer: [20]u8 = @splat(0);
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
    const zero_digest: [20]u8 = @splat(0);
    try w.writeAll(&zero_digest); // pack checksum, unvalidated by Index.open
    try w.writeAll(&zero_digest); // index checksum, unvalidated by Index.open

    try dir.writeFile(io, .{ .sub_path = sub_path, .data = aw.written() });
}

/// Places two commits, `a` and `b`, that each name the other as their
/// sole parent, reachable from `a`. Real, content-addressed objects can
/// never form this shape; this is a stand-in for whatever a hostile or
/// damaged repository's on-disk graph could contain.
fn buildFakeCycle(gpa: Allocator, io: std.Io, dir: std.Io.Dir, repo: *Repository) !struct { a: Oid, b: Oid } {
    const oid_a: Oid = .{ .sha1 = @splat(0x11) };
    const oid_b: Oid = .{ .sha1 = @splat(0x22) };

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
    const missing_hex = &@as([40]u8, @splat('f'));
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

    const missing_parent_hex = &@as([40]u8, @splat('f'));
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

    const missing_parent_hex = &@as([40]u8, @splat('a'));
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

    const hex = &@as([64]u8, @splat('b'));
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

    try tmp.dir.writeFile(io, .{ .sub_path = "shallow", .data = &@as([40]u8, @splat('c')) ++ "\n" });

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

// merge bases

/// Writes a commit with the given parents and committer time, and returns
/// its id. Each caller passes a distinct `when`, so no two commits collide.
fn commitWithParents(gpa: Allocator, repo: *Repository, parents: []const Oid, when: i64) !Oid {
    const hex_bufs = try gpa.alloc([Oid.max_formatted_length]u8, parents.len);
    defer gpa.free(hex_bufs);
    const hexes = try gpa.alloc([]const u8, parents.len);
    defer gpa.free(hexes);
    for (parents, hex_bufs, hexes) |p, *buf, *h| h.* = hexOf(p, buf);

    const payload = try buildCommitPayload(gpa, hexes, when, "merge base fixture");
    defer gpa.free(payload);
    return repo.odb.write(.commit, payload, null);
}

fn containsOid(oids: []const Oid, want: Oid) bool {
    for (oids) |o| if (o.eql(want)) return true;
    return false;
}

test "mergeBases returns the older side when it is the base of the other" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const c1 = try commitWithParents(gpa, &repo, &.{}, 1000);
    const c2 = try commitWithParents(gpa, &repo, &.{c1}, 2000);
    const c3 = try commitWithParents(gpa, &repo, &.{c2}, 3000);

    const bases = try mergeBases(gpa, &repo, c1, c3, null);
    defer gpa.free(bases);
    try testing.expectEqual(@as(usize, 1), bases.len);
    try testing.expect(bases[0].eql(c1));

    const flipped = try mergeBases(gpa, &repo, c3, c1, null);
    defer gpa.free(flipped);
    try testing.expectEqual(@as(usize, 1), flipped.len);
    try testing.expect(flipped[0].eql(c1));
}

test "mergeBases finds the fork point of two branches off one root" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const root = try commitWithParents(gpa, &repo, &.{}, 1000);
    const x1 = try commitWithParents(gpa, &repo, &.{root}, 2000);
    const x2 = try commitWithParents(gpa, &repo, &.{x1}, 3000);
    const y1 = try commitWithParents(gpa, &repo, &.{root}, 2500);

    const bases = try mergeBases(gpa, &repo, x2, y1, null);
    defer gpa.free(bases);
    try testing.expectEqual(@as(usize, 1), bases.len);
    try testing.expect(bases[0].eql(root));

    const base = (try mergeBase(gpa, &repo, x2, y1, null)).?;
    try testing.expect(base.eql(root));
}

test "mergeBases is empty and mergeBase is null for unrelated histories" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const r1 = try commitWithParents(gpa, &repo, &.{}, 1000);
    const r2 = try commitWithParents(gpa, &repo, &.{}, 2000);

    const bases = try mergeBases(gpa, &repo, r1, r2, null);
    defer gpa.free(bases);
    try testing.expectEqual(@as(usize, 0), bases.len);
    try testing.expectEqual(@as(?Oid, null), try mergeBase(gpa, &repo, r1, r2, null));
}

test "mergeBases returns both bases of a criss-cross history" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const root = try commitWithParents(gpa, &repo, &.{}, 1000);
    const a = try commitWithParents(gpa, &repo, &.{root}, 2000);
    const b = try commitWithParents(gpa, &repo, &.{root}, 2100);
    const a2 = try commitWithParents(gpa, &repo, &.{ a, b }, 3000);
    const b2 = try commitWithParents(gpa, &repo, &.{ b, a }, 3100);

    const bases = try mergeBases(gpa, &repo, a2, b2, null);
    defer gpa.free(bases);
    try testing.expectEqual(@as(usize, 2), bases.len);
    try testing.expect(containsOid(bases, a));
    try testing.expect(containsOid(bases, b));
    try testing.expect(!containsOid(bases, root));
    try testing.expect(bases[0].eql(b));
}

test "mergeBases reports the bound instead of a partial answer" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const c1 = try commitWithParents(gpa, &repo, &.{}, 1000);
    const c2 = try commitWithParents(gpa, &repo, &.{c1}, 2000);
    const c3 = try commitWithParents(gpa, &repo, &.{c2}, 3000);
    const c4 = try commitWithParents(gpa, &repo, &.{c3}, 4000);
    const c5 = try commitWithParents(gpa, &repo, &.{c4}, 5000);

    try testing.expectError(error.HistoryTooDeep, mergeBasesBounded(gpa, &repo, c1, c5, 3, null));

    const bases = try mergeBasesBounded(gpa, &repo, c1, c5, 100, null);
    defer gpa.free(bases);
    try testing.expectEqual(@as(usize, 1), bases.len);
    try testing.expect(bases[0].eql(c1));
}

test "mergeBases lists the newest base first" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const root = try commitWithParents(gpa, &repo, &.{}, 1000);
    var side: [5]Oid = undefined;
    for (&side, 0..) |*s, i| {
        s.* = try commitWithParents(gpa, &repo, &.{root}, 2000 + @as(i64, @intCast(i)) * 100);
    }
    const x1 = try commitWithParents(gpa, &repo, &.{ side[0], side[1], side[2], side[3], side[4] }, 3000);
    const x2 = try commitWithParents(gpa, &repo, &.{ side[2], side[4], side[0], side[3], side[1] }, 3100);

    const bases = try mergeBases(gpa, &repo, x1, x2, null);
    defer gpa.free(bases);
    try testing.expectEqual(@as(usize, 5), bases.len);
    for (bases, 0..) |got, i| {
        try testing.expect(got.eql(side[4 - i]));
    }
}
