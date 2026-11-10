//! Which objects a push has to send, and how the pack writer reads them.
//!
//! The set is the closure of the new tips with the closure of what the
//! remote advertised taken out. A remote holding an object holds that
//! object's closure too, so an advertised id stops the walk instead of
//! only being left out of it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;
const ObjectKind = core_mod.ObjectKind;

const object_mod = @import("ziggit-object");

const odb_mod = @import("ziggit-odb");
const Odb = odb_mod.Odb;

const pack_mod = @import("ziggit-pack");

pub const Error = Odb.Error;

const OidSet = std.AutoHashMapUnmanaged(Oid, void);

/// The largest commit, tree or tag this reads whole to find what it points
/// at. A blob is never read here, so this bounds metadata alone.
const max_pointer_object: usize = 64 << 20;

/// The ids to put in the pack, caller owned.
///
/// `haves` are the ids the remote advertised. One the local database does
/// not hold is ignored: its closure cannot be walked from here, and the
/// remote keeping objects we never had costs us nothing.
pub fn collect(
    gpa: Allocator,
    odb: *Odb,
    f: Format,
    tips: []const Oid,
    haves: []const Oid,
    diag: ?*?Diagnostic,
) Error![]Oid {
    var remote_has: OidSet = .empty;
    defer remote_has.deinit(gpa);
    try walk(gpa, odb, f, haves, null, &remote_has, null, diag);

    var sending: OidSet = .empty;
    defer sending.deinit(gpa);
    var out: std.ArrayList(Oid) = .empty;
    errdefer out.deinit(gpa);
    try walk(gpa, odb, f, tips, &remote_has, &sending, &out, diag);

    return out.toOwnedSlice(gpa);
}

/// Walks every object reachable from `roots`, recording each in `visited`
/// and appending it to `out` when there is one. An id in `skip`, or
/// already in `visited`, ends that branch.
fn walk(
    gpa: Allocator,
    odb: *Odb,
    f: Format,
    roots: []const Oid,
    skip: ?*const OidSet,
    visited: *OidSet,
    out: ?*std.ArrayList(Oid),
    diag: ?*?Diagnostic,
) Error!void {
    var stack: std.ArrayList(Oid) = .empty;
    defer stack.deinit(gpa);

    for (roots) |root| {
        if (skip) |s| {
            if (s.contains(root)) continue;
        }
        if (visited.contains(root)) continue;
        // A ref can name an id this database does not hold: the remote
        // advertising its own history is the ordinary case.
        if (!try odb.exists(root)) continue;
        try visited.put(gpa, root, {});
        try stack.append(gpa, root);
    }

    while (stack.pop()) |current| {
        const info = try odb.stat(current);
        if (out) |o| try o.append(gpa, current);
        if (info.kind == .blob) continue;

        const payload = try odb.readAlloc(gpa, current, max_pointer_object, diag);
        defer gpa.free(payload);

        var children: std.ArrayList(Oid) = .empty;
        defer children.deinit(gpa);
        try pointsAt(gpa, f, info.kind, payload, &children);

        for (children.items) |child| {
            if (skip) |s| {
                if (s.contains(child)) continue;
            }
            if (visited.contains(child)) continue;
            if (!try odb.exists(child)) continue;
            try visited.put(gpa, child, {});
            try stack.append(gpa, child);
        }
    }
}

/// Every id an object names directly. A gitlink entry names a commit in
/// the submodule's own repository, which this one never holds and the
/// remote never wants in this pack, so it is left out.
fn pointsAt(
    gpa: Allocator,
    f: Format,
    kind: ObjectKind,
    payload: []const u8,
    out: *std.ArrayList(Oid),
) Error!void {
    switch (kind) {
        .blob => {},
        .tree => {
            var tree = object_mod.Tree.parse(gpa, f, payload) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.CorruptTree => return error.CorruptObject,
            };
            defer tree.deinit(gpa);
            for (tree.entries) |entry| {
                if (entry.mode.isGitlink()) continue;
                try out.append(gpa, entry.oid);
            }
        },
        .commit => {
            var commit = object_mod.Commit.parse(gpa, f, payload) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.CorruptCommit => return error.CorruptObject,
            };
            defer commit.deinit(gpa);
            try out.append(gpa, commit.tree);
            for (commit.parents) |p| try out.append(gpa, p);
        },
        .tag => {
            var tag = object_mod.Tag.parse(gpa, f, payload) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.CorruptObject,
            };
            defer tag.deinit(gpa);
            try out.append(gpa, tag.object);
        },
    }
}

/// Reads the pack writer's objects straight out of an `Odb`.
pub const OdbSource = struct {
    odb: *Odb,
    diag: ?*?Diagnostic = null,

    pub fn source(self: *OdbSource) pack_mod.ObjectSource {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    const vtable: pack_mod.ObjectSource.VTable = .{ .stat = statFn, .read = readFn };

    fn statFn(ctx: *anyopaque, oid: Oid) pack_mod.PackWriterError!pack_mod.ObjectSource.Stat {
        const self: *OdbSource = @ptrCast(@alignCast(ctx));
        const info = self.odb.stat(oid) catch |err| return mapError(err);
        return .{ .kind = info.kind, .size = info.size };
    }

    fn readFn(ctx: *anyopaque, oid: Oid, w: *std.Io.Writer) pack_mod.PackWriterError!void {
        const self: *OdbSource = @ptrCast(@alignCast(ctx));
        _ = self.odb.read(oid, w, self.diag) catch |err| return mapError(err);
    }

    /// The pack writer's error set is deliberately narrow, so an odb fault
    /// collapses to one of its three. The `diag` the caller passed in
    /// carries the detail that is lost here.
    fn mapError(err: Odb.Error) pack_mod.PackWriterError {
        return switch (err) {
            error.ObjectNotFound => error.ObjectMissing,
            error.IoFailed => error.IoFailed,
            else => error.ObjectUnreadable,
        };
    }
};

const testing = std.testing;
const Tree = object_mod.Tree;

const TestRepo = struct {
    tmp: testing.TmpDir,
    objects: std.Io.Dir,
    odb: Odb,

    fn init(gpa: Allocator, io: std.Io) !TestRepo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "objects");
        const objects = try tmp.dir.openDir(io, "objects", .{ .iterate = true });
        const odb = try Odb.init(gpa, io, objects, .sha1, .{});
        return .{ .tmp = tmp, .objects = objects, .odb = odb };
    }

    fn deinit(r: *TestRepo, io: std.Io) void {
        r.odb.deinit();
        r.objects.close(io);
        r.tmp.cleanup();
    }

    fn blob(r: *TestRepo, content: []const u8) !Oid {
        return r.odb.write(.blob, content, null);
    }

    fn tree(r: *TestRepo, gpa: Allocator, entries: []Tree.Entry) !Oid {
        Tree.sortEntries(entries);
        var aw = try std.Io.Writer.Allocating.initCapacity(gpa, 256);
        defer aw.deinit();
        const t: Tree = .{ .entries = entries };
        try t.write(&aw.writer);
        return r.odb.write(.tree, aw.writer.buffered(), null);
    }

    fn commit(r: *TestRepo, gpa: Allocator, tree_oid: Oid, parents: []const Oid) !Oid {
        var aw = try std.Io.Writer.Allocating.initCapacity(gpa, 256);
        defer aw.deinit();
        var hex: [Oid.max_formatted_length]u8 = undefined;
        try aw.writer.print("tree {s}\n", .{tree_oid.toHex(&hex)});
        for (parents) |p| try aw.writer.print("parent {s}\n", .{p.toHex(&hex)});
        try aw.writer.writeAll(
            \\author A <a@b.c> 0 +0000
            \\committer A <a@b.c> 0 +0000
            \\
            \\msg
            \\
        );
        return r.odb.write(.commit, aw.writer.buffered(), null);
    }
};

fn contains(oids: []const Oid, needle: Oid) bool {
    for (oids) |o| {
        if (o.eql(needle)) return true;
    }
    return false;
}

test "an initial push sends the whole closure of the tip" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try TestRepo.init(gpa, io);
    defer r.deinit(io);

    const b = try r.blob("content\n");
    var inner = [_]Tree.Entry{.{ .mode = .blob, .name = "f.txt", .oid = b }};
    const sub = try r.tree(gpa, &inner);
    var root_entries = [_]Tree.Entry{.{ .mode = .tree, .name = "sub", .oid = sub }};
    const root = try r.tree(gpa, &root_entries);
    const c = try r.commit(gpa, root, &.{});

    const oids = try collect(gpa, &r.odb, .sha1, &.{c}, &.{}, null);
    defer gpa.free(oids);

    try testing.expectEqual(@as(usize, 4), oids.len);
    for ([_]Oid{ c, root, sub, b }) |want| try testing.expect(contains(oids, want));
}

test "an advertised id stops the walk, so a shared object is left out" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try TestRepo.init(gpa, io);
    defer r.deinit(io);

    const shared = try r.blob("shared\n");
    var first = [_]Tree.Entry{.{ .mode = .blob, .name = "a.txt", .oid = shared }};
    const t1 = try r.tree(gpa, &first);
    const c1 = try r.commit(gpa, t1, &.{});

    const added = try r.blob("added\n");
    var second = [_]Tree.Entry{
        .{ .mode = .blob, .name = "a.txt", .oid = shared },
        .{ .mode = .blob, .name = "b.txt", .oid = added },
    };
    const t2 = try r.tree(gpa, &second);
    const c2 = try r.commit(gpa, t2, &.{c1});

    const oids = try collect(gpa, &r.odb, .sha1, &.{c2}, &.{c1}, null);
    defer gpa.free(oids);

    try testing.expect(contains(oids, c2));
    try testing.expect(contains(oids, t2));
    try testing.expect(contains(oids, added));
    // The remote already holds these through c1.
    try testing.expect(!contains(oids, c1));
    try testing.expect(!contains(oids, t1));
    try testing.expect(!contains(oids, shared));
}

test "a tip the remote already holds sends nothing" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try TestRepo.init(gpa, io);
    defer r.deinit(io);

    const b = try r.blob("x\n");
    var entries = [_]Tree.Entry{.{ .mode = .blob, .name = "f.txt", .oid = b }};
    const t = try r.tree(gpa, &entries);
    const c = try r.commit(gpa, t, &.{});

    const oids = try collect(gpa, &r.odb, .sha1, &.{c}, &.{c}, null);
    defer gpa.free(oids);
    try testing.expectEqual(@as(usize, 0), oids.len);
}

test "an advertised id this database does not hold is ignored" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try TestRepo.init(gpa, io);
    defer r.deinit(io);

    const b = try r.blob("x\n");
    var entries = [_]Tree.Entry{.{ .mode = .blob, .name = "f.txt", .oid = b }};
    const t = try r.tree(gpa, &entries);
    const c = try r.commit(gpa, t, &.{});

    // A remote ahead of us advertises history we never had.
    const unknown = Oid.fromBytes(.sha1, &@as([20]u8, @splat(0x5a)));
    const oids = try collect(gpa, &r.odb, .sha1, &.{c}, &.{unknown}, null);
    defer gpa.free(oids);
    try testing.expectEqual(@as(usize, 3), oids.len);
}

test "a gitlink entry is never sent, since its commit lives elsewhere" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try TestRepo.init(gpa, io);
    defer r.deinit(io);

    // The id a gitlink names is a commit in the submodule's own
    // repository. Writing a blob under it here proves the walk skips the
    // entry by mode rather than by whether the object happens to exist.
    const planted = try r.blob("would be the submodule's commit\n");
    var entries = [_]Tree.Entry{
        .{ .mode = .gitlink, .name = "vendor", .oid = planted },
        .{ .mode = .blob, .name = "f.txt", .oid = try r.blob("kept\n") },
    };
    const t = try r.tree(gpa, &entries);
    const c = try r.commit(gpa, t, &.{});

    const oids = try collect(gpa, &r.odb, .sha1, &.{c}, &.{}, null);
    defer gpa.free(oids);
    try testing.expect(!contains(oids, planted));
    try testing.expectEqual(@as(usize, 3), oids.len);
}

test "an annotated tag carries its target into the pack" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try TestRepo.init(gpa, io);
    defer r.deinit(io);

    const b = try r.blob("x\n");
    var entries = [_]Tree.Entry{.{ .mode = .blob, .name = "f.txt", .oid = b }};
    const t = try r.tree(gpa, &entries);
    const c = try r.commit(gpa, t, &.{});

    var aw = try std.Io.Writer.Allocating.initCapacity(gpa, 256);
    defer aw.deinit();
    var hex: [Oid.max_formatted_length]u8 = undefined;
    try aw.writer.print("object {s}\ntype commit\ntag v1\n\nmsg\n", .{c.toHex(&hex)});
    const tag = try r.odb.write(.tag, aw.writer.buffered(), null);

    const oids = try collect(gpa, &r.odb, .sha1, &.{tag}, &.{}, null);
    defer gpa.free(oids);
    try testing.expect(contains(oids, tag));
    try testing.expect(contains(oids, c));
    try testing.expectEqual(@as(usize, 4), oids.len);
}
