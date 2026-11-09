//! Merging three trees into one index.
//!
//! The result is an index carrying conflict stages, which is what libgit2's
//! `git_merge_trees` returns. `write_tree.zig` turns it into the tree
//! `git merge-tree --write-tree` prints.
//!
//! Stage numbers come from `ziggit-index`, which already uses git's: 1 for
//! the ancestor, 2 for ours, 3 for theirs.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Oid = oid_mod.Oid;
const Format = oid_mod.Format;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;
const FileMode = core_mod.FileMode;

const object_mod = @import("ziggit-object");
const Tree = object_mod.Tree;

const odb_mod = @import("ziggit-odb");
const Odb = odb_mod.Odb;

const index_mod = @import("ziggit-index");
const Index = index_mod.Index;
const IndexEntry = index_mod.Entry;
const Stage = index_mod.Stage;

const merge_file_mod = @import("merge_file.zig");
const FileOptions = merge_file_mod.FileOptions;

/// Allocation budget for one tree object, matching `ziggit-checkout`.
const max_tree_object_len: usize = 1 << 20;
/// Allocation budget for one blob being merged. A blob past this conflicts
/// whole instead of failing the merge, the same answer the text driver
/// gives for content it will not touch.
const max_blob_len: usize = 64 * 1024 * 1024;

pub const Error = error{
    CorruptTree,
    /// A path name a tree must never carry, such as one holding a `/`.
    BadTreeEntryName,
} || merge_file_mod.Error || Odb.Error || Allocator.Error;

pub const ConflictKind = enum {
    /// Both sides changed the content differently.
    content,
    /// Neither side had it and both added it, differing.
    add_add,
    /// Ours changed it, theirs deleted it.
    modify_delete,
    /// Ours deleted it, theirs changed it.
    delete_modify,
    /// One side has a directory where the other has a file.
    directory_file,
};

pub const Conflict = struct {
    /// Owned.
    path: []const u8,
    kind: ConflictKind,
    /// The merged content with markers in it, written as a blob. Null for a
    /// conflict with no single content to write, such as modify/delete or a
    /// directory against a file.
    marked: ?Oid,

    pub fn deinit(c: *Conflict, gpa: Allocator) void {
        gpa.free(c.path);
        c.* = undefined;
    }
};

pub const Options = struct {
    /// Accepted and **not yet honoured**: rename detection is wired up in a
    /// later change. A renamed path currently reads as a delete plus an
    /// add, which conflicts where git merges cleanly. It never produces a
    /// wrong merge, only a pessimistic one.
    find_renames: bool = true,
    /// libgit2's defaults, used once renames are honoured.
    rename_threshold: u8 = 50,
    target_limit: usize = 200,
    /// Null is libgit2's unlimited.
    recursion_limit: ?usize = null,
    file: FileOptions = .{},
};

pub const Result = struct {
    /// Resolved paths at stage 0, and one entry per surviving side of a
    /// conflicted path at stages 1, 2 and 3. The shape git's own index has
    /// part way through a merge.
    index: Index,
    /// Owned.
    conflicts: []Conflict,

    pub fn hasConflicts(r: Result) bool {
        return r.conflicts.len > 0;
    }

    pub fn deinit(r: *Result, gpa: Allocator) void {
        r.index.deinit();
        for (r.conflicts) |*c| c.deinit(gpa);
        gpa.free(r.conflicts);
        r.* = undefined;
    }
};

/// Merges `ours` and `theirs` over `base`. A null `base` merges against an
/// empty tree, so every path on either side is an addition.
pub fn mergeTrees(
    gpa: Allocator,
    odb: *Odb,
    base: ?Oid,
    ours: Oid,
    theirs: Oid,
    options: Options,
    diag: ?*?Diagnostic,
) Error!Result {
    var entries: std.ArrayList(IndexEntry) = .empty;
    errdefer {
        for (entries.items) |*e| e.deinit(gpa);
        entries.deinit(gpa);
    }
    var conflicts: std.ArrayList(Conflict) = .empty;
    errdefer {
        for (conflicts.items) |*c| c.deinit(gpa);
        conflicts.deinit(gpa);
    }

    try walk(gpa, odb, base, ours, theirs, "", &entries, &conflicts, options, diag);

    const owned = try entries.toOwnedSlice(gpa);
    errdefer {
        for (owned) |*e| e.deinit(gpa);
        gpa.free(owned);
    }
    std.mem.sort(IndexEntry, owned, {}, lessThanEntry);

    return .{
        .index = .{ .gpa = gpa, .entries = owned },
        .conflicts = try conflicts.toOwnedSlice(gpa),
    };
}

fn walk(
    gpa: Allocator,
    odb: *Odb,
    base: ?Oid,
    ours: ?Oid,
    theirs: ?Oid,
    prefix: []const u8,
    entries: *std.ArrayList(IndexEntry),
    conflicts: *std.ArrayList(Conflict),
    options: Options,
    diag: ?*?Diagnostic,
) Error!void {
    var base_tree = try readTree(gpa, odb, base, diag);
    defer base_tree.deinit(gpa);
    var our_tree = try readTree(gpa, odb, ours, diag);
    defer our_tree.deinit(gpa);
    var their_tree = try readTree(gpa, odb, theirs, diag);
    defer their_tree.deinit(gpa);

    var names = try unionNames(gpa, base_tree.tree, our_tree.tree, their_tree.tree);
    defer names.deinit(gpa);

    for (names.items) |name| {
        const b = base_tree.tree.find(name);
        const o = our_tree.tree.find(name);
        const t = their_tree.tree.find(name);

        const path = if (prefix.len == 0)
            try gpa.dupe(u8, name)
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, name });
        var path_owned = true;
        defer if (path_owned) gpa.free(path);

        // A subtree on every side that has it is merged by recursing. Mixing
        // a directory with a file at one path is git's directory/file
        // conflict, which has no single content.
        const any_tree = isTree(b) or isTree(o) or isTree(t);
        if (any_tree) {
            const all_trees = (b == null or isTree(b)) and
                (o == null or isTree(o)) and
                (t == null or isTree(t));
            if (all_trees) {
                try walk(
                    gpa,
                    odb,
                    if (b) |e| e.oid else null,
                    if (o) |e| e.oid else null,
                    if (t) |e| e.oid else null,
                    path,
                    entries,
                    conflicts,
                    options,
                    diag,
                );
                continue;
            }
            try conflicts.append(gpa, .{ .path = path, .kind = .directory_file, .marked = null });
            path_owned = false;
            try appendStages(gpa, entries, path, b, o, t);
            continue;
        }

        const decided = try decide(gpa, odb, b, o, t, path, options, diag);
        switch (decided) {
            .nothing => {},
            .take => |entry| {
                try entries.append(gpa, .{
                    .path = path,
                    .oid = entry.oid,
                    .mode = entry.mode,
                    .stage = .merged,
                    .size = 0,
                    .stat = zeroStat(),
                });
                path_owned = false;
            },
            .conflict => |c| {
                try conflicts.append(gpa, .{ .path = path, .kind = c.kind, .marked = c.marked });
                path_owned = false;
                try appendStages(gpa, entries, path, b, o, t);
            },
        }
    }
}

const Decided = union(enum) {
    /// Both sides agree the path is gone.
    nothing,
    take: struct { oid: Oid, mode: FileMode },
    conflict: struct { kind: ConflictKind, marked: ?Oid },
};

fn decide(
    gpa: Allocator,
    odb: *Odb,
    b: ?Tree.Entry,
    o: ?Tree.Entry,
    t: ?Tree.Entry,
    path: []const u8,
    options: Options,
    diag: ?*?Diagnostic,
) Error!Decided {
    if (o == null and t == null) return .nothing;

    if (b == null) {
        const our_entry = o orelse return .{ .take = .{ .oid = t.?.oid, .mode = t.?.mode } };
        const their_entry = t orelse return .{ .take = .{ .oid = our_entry.oid, .mode = our_entry.mode } };
        if (same(our_entry, their_entry)) {
            return .{ .take = .{ .oid = our_entry.oid, .mode = our_entry.mode } };
        }
        const marked = try mergeContent(gpa, odb, null, our_entry, their_entry, path, options, diag);
        return .{ .conflict = .{ .kind = .add_add, .marked = marked } };
    }

    const base_entry = b.?;
    if (o == null) {
        // Ours deleted it. Theirs leaving it untouched agrees; theirs
        // changing it does not.
        if (same(base_entry, t.?)) return .nothing;
        return .{ .conflict = .{ .kind = .delete_modify, .marked = null } };
    }
    if (t == null) {
        if (same(base_entry, o.?)) return .nothing;
        return .{ .conflict = .{ .kind = .modify_delete, .marked = null } };
    }

    const our_entry = o.?;
    const their_entry = t.?;
    if (same(base_entry, our_entry)) return .{ .take = .{ .oid = their_entry.oid, .mode = their_entry.mode } };
    if (same(base_entry, their_entry)) return .{ .take = .{ .oid = our_entry.oid, .mode = our_entry.mode } };
    if (same(our_entry, their_entry)) return .{ .take = .{ .oid = our_entry.oid, .mode = our_entry.mode } };

    // A gitlink names a commit in another repository, so there is no text to
    // merge: two different commits is a conflict with no merged content.
    if (base_entry.mode == .gitlink or our_entry.mode == .gitlink or their_entry.mode == .gitlink) {
        return .{ .conflict = .{ .kind = .content, .marked = null } };
    }

    const merged = try mergeBlobs(gpa, odb, base_entry, our_entry, their_entry, path, options, diag);
    if (merged.clean) return .{ .take = .{ .oid = merged.oid, .mode = merged.mode } };
    return .{ .conflict = .{ .kind = .content, .marked = merged.oid } };
}

const Merged = struct { clean: bool, oid: Oid, mode: FileMode };

/// Runs the text merge over three blobs and writes the result, clean or
/// marked, as a blob.
fn mergeBlobs(
    gpa: Allocator,
    odb: *Odb,
    b: Tree.Entry,
    o: Tree.Entry,
    t: Tree.Entry,
    path: []const u8,
    options: Options,
    diag: ?*?Diagnostic,
) Error!Merged {
    const base_bytes = try odb.readAlloc(gpa, b.oid, max_blob_len, diag);
    defer gpa.free(base_bytes);
    const our_bytes = try odb.readAlloc(gpa, o.oid, max_blob_len, diag);
    defer gpa.free(our_bytes);
    const their_bytes = try odb.readAlloc(gpa, t.oid, max_blob_len, diag);
    defer gpa.free(their_bytes);

    var result = try merge_file_mod.mergeFile(
        gpa,
        .{ .path = path, .mode = b.mode, .content = base_bytes },
        .{ .path = path, .mode = o.mode, .content = our_bytes },
        .{ .path = path, .mode = t.mode, .content = their_bytes },
        options.file,
    );
    defer result.deinit(gpa);

    const oid = try odb.write(.blob, result.content, diag);
    return .{ .clean = result.automergeable, .oid = oid, .mode = result.mode };
}

/// The marked content for two sides with no common ancestor, which is what
/// an add/add conflict is.
fn mergeContent(
    gpa: Allocator,
    odb: *Odb,
    b: ?Tree.Entry,
    o: Tree.Entry,
    t: Tree.Entry,
    path: []const u8,
    options: Options,
    diag: ?*?Diagnostic,
) Error!?Oid {
    if (o.mode == .gitlink or t.mode == .gitlink) return null;

    const base_bytes: []const u8 = if (b) |e| try odb.readAlloc(gpa, e.oid, max_blob_len, diag) else "";
    defer if (b != null) gpa.free(@constCast(base_bytes));
    const our_bytes = try odb.readAlloc(gpa, o.oid, max_blob_len, diag);
    defer gpa.free(our_bytes);
    const their_bytes = try odb.readAlloc(gpa, t.oid, max_blob_len, diag);
    defer gpa.free(their_bytes);

    var result = try merge_file_mod.mergeFile(
        gpa,
        if (b) |e| .{ .path = path, .mode = e.mode, .content = base_bytes } else null,
        .{ .path = path, .mode = o.mode, .content = our_bytes },
        .{ .path = path, .mode = t.mode, .content = their_bytes },
        options.file,
    );
    defer result.deinit(gpa);

    return try odb.write(.blob, result.content, diag);
}

/// Writes one index entry per side that still has the path, at its own
/// stage, which is what git's index holds part way through a merge.
fn appendStages(
    gpa: Allocator,
    entries: *std.ArrayList(IndexEntry),
    path: []const u8,
    b: ?Tree.Entry,
    o: ?Tree.Entry,
    t: ?Tree.Entry,
) Error!void {
    const sides = [_]struct { entry: ?Tree.Entry, stage: Stage }{
        .{ .entry = b, .stage = .base },
        .{ .entry = o, .stage = .ours },
        .{ .entry = t, .stage = .theirs },
    };
    for (sides) |side| {
        const entry = side.entry orelse continue;
        try entries.append(gpa, .{
            .path = try gpa.dupe(u8, path),
            .oid = entry.oid,
            .mode = entry.mode,
            .stage = side.stage,
            .size = 0,
            .stat = zeroStat(),
        });
    }
}

fn same(a: Tree.Entry, b: Tree.Entry) bool {
    return a.oid.eql(b.oid) and a.mode == b.mode;
}

fn isTree(e: ?Tree.Entry) bool {
    const entry = e orelse return false;
    return entry.mode == .tree;
}

/// Every name any of the three trees has, in git's tree order, each once.
fn unionNames(gpa: Allocator, base: Tree, ours: Tree, theirs: Tree) Error!std.ArrayList([]const u8) {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    var names: std.ArrayList([]const u8) = .empty;
    errdefer names.deinit(gpa);

    for ([_]Tree{ base, ours, theirs }) |tree| {
        for (tree.entries) |entry| {
            if (std.mem.indexOfScalar(u8, entry.name, '/') != null) return error.BadTreeEntryName;
            const gop = try seen.getOrPut(gpa, entry.name);
            if (gop.found_existing) continue;
            try names.append(gpa, entry.name);
        }
    }
    std.mem.sort([]const u8, names.items, {}, lessThanName);
    return names;
}

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// A tree plus the bytes its entry names point into. `Tree.parse` borrows
/// every name from those bytes, so the two are freed together.
const OwnedTree = struct {
    bytes: []u8,
    tree: Tree,

    fn deinit(self: *OwnedTree, gpa: Allocator) void {
        self.tree.deinit(gpa);
        gpa.free(self.bytes);
    }
};

/// Reads the tree at `oid`, or an empty tree for null.
fn readTree(gpa: Allocator, odb: *Odb, oid: ?Oid, diag: ?*?Diagnostic) Error!OwnedTree {
    const id = oid orelse return .{ .bytes = try gpa.alloc(u8, 0), .tree = .{ .entries = &.{} } };
    const bytes = try odb.readAlloc(gpa, id, max_tree_object_len, diag);
    errdefer gpa.free(bytes);
    const tree = Tree.parse(gpa, odb.format, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CorruptTree => return error.CorruptTree,
    };
    return .{ .bytes = bytes, .tree = tree };
}

/// An index built by a merge has no file behind any entry, so there is
/// nothing to stat. `ziggit-status` treats a zeroed block as "read the
/// content", which is the right answer for an entry no checkout has
/// written yet.
fn zeroStat() index_mod.Stat {
    return .{
        .ctime_seconds = 0,
        .ctime_nanoseconds = 0,
        .mtime_seconds = 0,
        .mtime_nanoseconds = 0,
        .dev = 0,
        .ino = 0,
        .uid = 0,
        .gid = 0,
    };
}

/// Git's index order: by path, then by stage, so the three stages of a
/// conflicted path sit together in ancestor, ours, theirs order.
fn lessThanEntry(_: void, a: IndexEntry, b: IndexEntry) bool {
    return switch (std.mem.order(u8, a.path, b.path)) {
        .lt => true,
        .gt => false,
        .eq => @backingInt(a.stage) < @backingInt(b.stage),
    };
}

const testing = std.testing;

pub const TestRepo = struct {
    tmp: testing.TmpDir,
    objects: std.Io.Dir,
    odb: Odb,

    pub fn init(gpa: Allocator, io: std.Io) !TestRepo {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "objects");
        const objects = try tmp.dir.openDir(io, "objects", .{ .iterate = true });
        const odb = try Odb.init(gpa, io, objects, .sha1, .{});
        return .{ .tmp = tmp, .objects = objects, .odb = odb };
    }

    pub fn deinit(r: *TestRepo, io: std.Io) void {
        r.odb.deinit();
        r.objects.close(io);
        r.tmp.cleanup();
    }

    pub fn blob(r: *TestRepo, content: []const u8) !Oid {
        return r.odb.write(.blob, content, null);
    }

    pub fn tree(r: *TestRepo, gpa: Allocator, entries: []Tree.Entry) !Oid {
        Tree.sortEntries(entries);
        var aw = try std.Io.Writer.Allocating.initCapacity(gpa, 256);
        defer aw.deinit();
        const t: Tree = .{ .entries = entries };
        try t.write(&aw.writer);
        return r.odb.write(.tree, aw.writer.buffered(), null);
    }
};

/// The stage-0 entry for `path`, or null when the path is conflicted or
/// absent.
fn resolved(result: Result, path: []const u8) ?IndexEntry {
    for (result.index.entries) |e| {
        if (e.stage == .merged and std.mem.eql(u8, e.path, path)) return e;
    }
    return null;
}

fn conflictFor(result: Result, path: []const u8) ?Conflict {
    for (result.conflicts) |c| {
        if (std.mem.eql(u8, c.path, path)) return c;
    }
    return null;
}

test "a path only ours changed takes ours, and only theirs takes theirs" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try TestRepo.init(gpa, io);
    defer r.deinit(io);

    const b1 = try r.blob("base\n");
    const o1 = try r.blob("ours\n");
    const t1 = try r.blob("theirs\n");

    var base_e = [_]Tree.Entry{
        .{ .mode = .blob, .name = "a.txt", .oid = b1 },
        .{ .mode = .blob, .name = "b.txt", .oid = b1 },
    };
    const base = try r.tree(gpa, &base_e);
    var our_e = [_]Tree.Entry{
        .{ .mode = .blob, .name = "a.txt", .oid = o1 },
        .{ .mode = .blob, .name = "b.txt", .oid = b1 },
    };
    const ours = try r.tree(gpa, &our_e);
    var their_e = [_]Tree.Entry{
        .{ .mode = .blob, .name = "a.txt", .oid = b1 },
        .{ .mode = .blob, .name = "b.txt", .oid = t1 },
    };
    const theirs = try r.tree(gpa, &their_e);

    var result = try mergeTrees(gpa, &r.odb, base, ours, theirs, .{}, null);
    defer result.deinit(gpa);

    try testing.expect(!result.hasConflicts());
    try testing.expect(resolved(result, "a.txt").?.oid.eql(o1));
    try testing.expect(resolved(result, "b.txt").?.oid.eql(t1));
}

test "both sides making the same change take it once" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try TestRepo.init(gpa, io);
    defer r.deinit(io);

    const b1 = try r.blob("base\n");
    const same_oid = try r.blob("same\n");
    var base_e = [_]Tree.Entry{.{ .mode = .blob, .name = "a.txt", .oid = b1 }};
    const base = try r.tree(gpa, &base_e);
    var side_e = [_]Tree.Entry{.{ .mode = .blob, .name = "a.txt", .oid = same_oid }};
    const side = try r.tree(gpa, &side_e);

    var result = try mergeTrees(gpa, &r.odb, base, side, side, .{}, null);
    defer result.deinit(gpa);
    try testing.expect(!result.hasConflicts());
    try testing.expect(resolved(result, "a.txt").?.oid.eql(same_oid));
    try testing.expectEqual(@as(usize, 1), result.index.entries.len);
}

test "both sides editing far apart lines merge into one blob" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try TestRepo.init(gpa, io);
    defer r.deinit(io);

    const b1 = try r.blob("l1\nl2\nl3\nl4\nl5\nl6\nl7\n");
    const o1 = try r.blob("L1\nl2\nl3\nl4\nl5\nl6\nl7\n");
    const t1 = try r.blob("l1\nl2\nl3\nl4\nl5\nl6\nL7\n");

    var base_e = [_]Tree.Entry{.{ .mode = .blob, .name = "a.txt", .oid = b1 }};
    const base = try r.tree(gpa, &base_e);
    var our_e = [_]Tree.Entry{.{ .mode = .blob, .name = "a.txt", .oid = o1 }};
    const ours = try r.tree(gpa, &our_e);
    var their_e = [_]Tree.Entry{.{ .mode = .blob, .name = "a.txt", .oid = t1 }};
    const theirs = try r.tree(gpa, &their_e);

    var result = try mergeTrees(gpa, &r.odb, base, ours, theirs, .{}, null);
    defer result.deinit(gpa);

    try testing.expect(!result.hasConflicts());
    const merged = resolved(result, "a.txt").?;
    const bytes = try r.odb.readAlloc(gpa, merged.oid, 1 << 16, null);
    defer gpa.free(bytes);
    try testing.expectEqualStrings("L1\nl2\nl3\nl4\nl5\nl6\nL7\n", bytes);
}

test "a content conflict records the marked blob and all three stages" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try TestRepo.init(gpa, io);
    defer r.deinit(io);

    const b1 = try r.blob("one\ntwo\nthree\n");
    const o1 = try r.blob("one\nOURS\nthree\n");
    const t1 = try r.blob("one\nTHEIRS\nthree\n");

    var base_e = [_]Tree.Entry{.{ .mode = .blob, .name = "a.txt", .oid = b1 }};
    const base = try r.tree(gpa, &base_e);
    var our_e = [_]Tree.Entry{.{ .mode = .blob, .name = "a.txt", .oid = o1 }};
    const ours = try r.tree(gpa, &our_e);
    var their_e = [_]Tree.Entry{.{ .mode = .blob, .name = "a.txt", .oid = t1 }};
    const theirs = try r.tree(gpa, &their_e);

    var result = try mergeTrees(gpa, &r.odb, base, ours, theirs, .{}, null);
    defer result.deinit(gpa);

    try testing.expect(result.hasConflicts());
    const c = conflictFor(result, "a.txt").?;
    try testing.expectEqual(ConflictKind.content, c.kind);

    const marked = try r.odb.readAlloc(gpa, c.marked.?, 1 << 16, null);
    defer gpa.free(marked);
    try testing.expectEqualStrings(
        "one\n<<<<<<< ours\nOURS\n=======\nTHEIRS\n>>>>>>> theirs\nthree\n",
        marked,
    );

    // Stages 1, 2 and 3, in that order, and no stage 0.
    try testing.expectEqual(@as(usize, 3), result.index.entries.len);
    try testing.expectEqual(Stage.base, result.index.entries[0].stage);
    try testing.expectEqual(Stage.ours, result.index.entries[1].stage);
    try testing.expectEqual(Stage.theirs, result.index.entries[2].stage);
    try testing.expect(resolved(result, "a.txt") == null);
}

test "add against add with different content conflicts" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try TestRepo.init(gpa, io);
    defer r.deinit(io);

    const o1 = try r.blob("ours\n");
    const t1 = try r.blob("theirs\n");
    var empty: [0]Tree.Entry = .{};
    const base = try r.tree(gpa, &empty);
    var our_e = [_]Tree.Entry{.{ .mode = .blob, .name = "new.txt", .oid = o1 }};
    const ours = try r.tree(gpa, &our_e);
    var their_e = [_]Tree.Entry{.{ .mode = .blob, .name = "new.txt", .oid = t1 }};
    const theirs = try r.tree(gpa, &their_e);

    var result = try mergeTrees(gpa, &r.odb, base, ours, theirs, .{}, null);
    defer result.deinit(gpa);

    try testing.expect(result.hasConflicts());
    const c = conflictFor(result, "new.txt").?;
    try testing.expectEqual(ConflictKind.add_add, c.kind);
    try testing.expect(c.marked != null);
    // No ancestor, so stages 2 and 3 only.
    try testing.expectEqual(@as(usize, 2), result.index.entries.len);
    try testing.expectEqual(Stage.ours, result.index.entries[0].stage);
    try testing.expectEqual(Stage.theirs, result.index.entries[1].stage);
}

test "modify against delete conflicts, and delete against modify is the mirror" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try TestRepo.init(gpa, io);
    defer r.deinit(io);

    const b1 = try r.blob("base\n");
    const o1 = try r.blob("ours\n");
    var base_e = [_]Tree.Entry{.{ .mode = .blob, .name = "a.txt", .oid = b1 }};
    const base = try r.tree(gpa, &base_e);
    var our_e = [_]Tree.Entry{.{ .mode = .blob, .name = "a.txt", .oid = o1 }};
    const ours = try r.tree(gpa, &our_e);
    var empty: [0]Tree.Entry = .{};
    const gone = try r.tree(gpa, &empty);

    var forward = try mergeTrees(gpa, &r.odb, base, ours, gone, .{}, null);
    defer forward.deinit(gpa);
    try testing.expectEqual(ConflictKind.modify_delete, conflictFor(forward, "a.txt").?.kind);
    try testing.expect(conflictFor(forward, "a.txt").?.marked == null);

    var mirror = try mergeTrees(gpa, &r.odb, base, gone, ours, .{}, null);
    defer mirror.deinit(gpa);
    try testing.expectEqual(ConflictKind.delete_modify, conflictFor(mirror, "a.txt").?.kind);
}

test "a path both sides deleted is simply gone" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try TestRepo.init(gpa, io);
    defer r.deinit(io);

    const b1 = try r.blob("base\n");
    var base_e = [_]Tree.Entry{.{ .mode = .blob, .name = "a.txt", .oid = b1 }};
    const base = try r.tree(gpa, &base_e);
    var empty: [0]Tree.Entry = .{};
    const gone = try r.tree(gpa, &empty);

    var result = try mergeTrees(gpa, &r.odb, base, gone, gone, .{}, null);
    defer result.deinit(gpa);
    try testing.expect(!result.hasConflicts());
    try testing.expectEqual(@as(usize, 0), result.index.entries.len);
}

test "a directory on one side and a file on the other conflicts" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try TestRepo.init(gpa, io);
    defer r.deinit(io);

    const inner = try r.blob("inner\n");
    var inner_e = [_]Tree.Entry{.{ .mode = .blob, .name = "f.txt", .oid = inner }};
    const subtree = try r.tree(gpa, &inner_e);

    var empty: [0]Tree.Entry = .{};
    const base = try r.tree(gpa, &empty);
    var our_e = [_]Tree.Entry{.{ .mode = .tree, .name = "thing", .oid = subtree }};
    const ours = try r.tree(gpa, &our_e);
    var their_e = [_]Tree.Entry{.{ .mode = .blob, .name = "thing", .oid = inner }};
    const theirs = try r.tree(gpa, &their_e);

    var result = try mergeTrees(gpa, &r.odb, base, ours, theirs, .{}, null);
    defer result.deinit(gpa);
    try testing.expectEqual(ConflictKind.directory_file, conflictFor(result, "thing").?.kind);
    try testing.expect(conflictFor(result, "thing").?.marked == null);
}

test "subtrees merge by recursing, and paths come out prefixed" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try TestRepo.init(gpa, io);
    defer r.deinit(io);

    const b1 = try r.blob("base\n");
    const o1 = try r.blob("ours\n");
    const t1 = try r.blob("theirs\n");

    var base_inner = [_]Tree.Entry{
        .{ .mode = .blob, .name = "x.txt", .oid = b1 },
        .{ .mode = .blob, .name = "y.txt", .oid = b1 },
    };
    const base_sub = try r.tree(gpa, &base_inner);
    var base_e = [_]Tree.Entry{.{ .mode = .tree, .name = "dir", .oid = base_sub }};
    const base = try r.tree(gpa, &base_e);

    var our_inner = [_]Tree.Entry{
        .{ .mode = .blob, .name = "x.txt", .oid = o1 },
        .{ .mode = .blob, .name = "y.txt", .oid = b1 },
    };
    const our_sub = try r.tree(gpa, &our_inner);
    var our_e = [_]Tree.Entry{.{ .mode = .tree, .name = "dir", .oid = our_sub }};
    const ours = try r.tree(gpa, &our_e);

    var their_inner = [_]Tree.Entry{
        .{ .mode = .blob, .name = "x.txt", .oid = b1 },
        .{ .mode = .blob, .name = "y.txt", .oid = t1 },
    };
    const their_sub = try r.tree(gpa, &their_inner);
    var their_e = [_]Tree.Entry{.{ .mode = .tree, .name = "dir", .oid = their_sub }};
    const theirs = try r.tree(gpa, &their_e);

    var result = try mergeTrees(gpa, &r.odb, base, ours, theirs, .{}, null);
    defer result.deinit(gpa);

    try testing.expect(!result.hasConflicts());
    try testing.expect(resolved(result, "dir/x.txt").?.oid.eql(o1));
    try testing.expect(resolved(result, "dir/y.txt").?.oid.eql(t1));
}

test "two gitlinks moving to different commits conflict with no content" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try TestRepo.init(gpa, io);
    defer r.deinit(io);

    const b1 = try r.blob("pretend base commit\n");
    const o1 = try r.blob("pretend ours commit\n");
    const t1 = try r.blob("pretend theirs commit\n");

    var base_e = [_]Tree.Entry{.{ .mode = .gitlink, .name = "sub", .oid = b1 }};
    const base = try r.tree(gpa, &base_e);
    var our_e = [_]Tree.Entry{.{ .mode = .gitlink, .name = "sub", .oid = o1 }};
    const ours = try r.tree(gpa, &our_e);
    var their_e = [_]Tree.Entry{.{ .mode = .gitlink, .name = "sub", .oid = t1 }};
    const theirs = try r.tree(gpa, &their_e);

    var result = try mergeTrees(gpa, &r.odb, base, ours, theirs, .{}, null);
    defer result.deinit(gpa);
    const c = conflictFor(result, "sub").?;
    try testing.expectEqual(ConflictKind.content, c.kind);
    try testing.expect(c.marked == null);
}

test "a null base makes every path on both sides an addition" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try TestRepo.init(gpa, io);
    defer r.deinit(io);

    const o1 = try r.blob("ours\n");
    var our_e = [_]Tree.Entry{.{ .mode = .blob, .name = "a.txt", .oid = o1 }};
    const ours = try r.tree(gpa, &our_e);
    var their_e = [_]Tree.Entry{.{ .mode = .blob, .name = "b.txt", .oid = o1 }};
    const theirs = try r.tree(gpa, &their_e);

    var result = try mergeTrees(gpa, &r.odb, null, ours, theirs, .{}, null);
    defer result.deinit(gpa);
    try testing.expect(!result.hasConflicts());
    try testing.expect(resolved(result, "a.txt") != null);
    try testing.expect(resolved(result, "b.txt") != null);
}
