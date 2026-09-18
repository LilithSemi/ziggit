//! What differs between HEAD, the index and the working tree.
//!
//! Two independent comparisons, which is what git's two porcelain columns
//! are. Measured against git 2.55 with
//! `git --no-optional-locks status --porcelain=v1 -z --untracked-files=all --no-renames`:
//!
//! ```
//! A  .gitignore       index differs from HEAD (added), worktree matches index
//!  D deleted.txt      worktree differs from index (gone)
//!  M modified.txt     worktree differs from index (contents)
//! ?? untracked.txt    git has never tracked this path
//! ```
//!
//! **A path that matches everywhere is not reported**, and neither is an
//! ignored one. Only differences appear.
//!
//! **The walk is driven from the union of the index and the working tree**,
//! never from the working tree alone. A deleted file is not on disk, so a
//! worktree walk cannot see it, and dropping it would lose exactly the change
//! a caller most needs to hear about.

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

const ignore_mod = @import("ziggit-ignore");

pub const Error = error{
    IoFailed,
    CorruptObject,
} || Odb.Error || index_mod.Error || Allocator.Error;

/// How the working tree compares to the index, which is git's second column.
pub const Worktree = enum { unchanged, modified, deleted };

/// How the index compares to HEAD, which is git's first column.
pub const Staged = enum { unchanged, added, modified, deleted };

pub const Change = struct {
    /// Relative to the worktree root, `/` separated. Owned.
    path: []const u8,
    /// Git has never tracked this path: it is in neither the index nor HEAD.
    /// This is the `??` column, and the one bit a caller that only wants
    /// "new or not" needs.
    untracked: bool,
    worktree: Worktree,
    staged: Staged,

    pub fn deinit(c: *Change, gpa: Allocator) void {
        gpa.free(c.path);
        c.* = undefined;
    }
};

pub const Result = struct {
    /// Sorted by path. Owned.
    changes: []Change,

    pub fn deinit(r: *Result, gpa: Allocator) void {
        for (r.changes) |*c| c.deinit(gpa);
        gpa.free(r.changes);
        r.* = undefined;
    }

    /// True when nothing differs anywhere, which is what a caller asking
    /// "is this worktree clean" wants.
    pub fn isClean(r: Result) bool {
        return r.changes.len == 0;
    }
};

pub const Options = struct {
    /// Honour gitignore while looking for untracked files, or null to report
    /// every untracked path. Null is not "no ignore file exists": it is
    /// "ignore rules do not apply", which lists build output.
    ///
    /// The walk adds each directory's own `.gitignore` as it descends and
    /// drops it again, so the matcher is left as it arrived.
    ignore: ?*ignore_mod.Matcher = null,
    /// The tree HEAD points at, or null for an unborn branch, where every
    /// index entry is newly added.
    head_tree: ?Oid = null,
};

/// Allocation budget for reading one worktree file to hash it, and for one
/// tree object. Defensive ceilings, not spec limits.
const max_file_len: usize = 1 << 30;
const max_tree_len: usize = 1 << 20;

/// Compares HEAD, the index and `work_tree`.
pub fn status(
    gpa: Allocator,
    io: std.Io,
    work_tree: std.Io.Dir,
    odb: *Odb,
    index: Index,
    f: Format,
    options: Options,
    diag: ?*?Diagnostic,
) Error!Result {
    // Every path any of the three sides knows about, and what each side says.
    var paths: std.StringArrayHashMapUnmanaged(Sides) = .empty;
    defer {
        for (paths.keys()) |k| gpa.free(k);
        paths.deinit(gpa);
    }

    for (index.entries) |e| {
        // An unmerged entry is a conflict, not a comparison this makes.
        if (e.stage != .merged) continue;
        const owned = try gpa.dupe(u8, e.path);
        errdefer gpa.free(owned);
        const gop = try paths.getOrPut(gpa, owned);
        if (gop.found_existing) {
            gpa.free(owned);
        } else {
            gop.value_ptr.* = .{};
        }
        gop.value_ptr.index = .{ .oid = e.oid, .mode = e.mode, .size = e.size };
    }

    if (options.head_tree) |tree_oid| {
        try collectTree(gpa, odb, tree_oid, "", &paths, diag);
    }

    var path_buf: [4096]u8 = undefined;
    try collectWorktree(gpa, io, work_tree, &path_buf, 0, &paths, options);

    var changes: std.ArrayList(Change) = .empty;
    errdefer {
        for (changes.items) |*c| c.deinit(gpa);
        changes.deinit(gpa);
    }

    for (paths.keys(), paths.values()) |path, sides| {
        const decided = try decide(gpa, io, work_tree, odb, f, path, sides);
        if (decided.untracked == false and decided.worktree == .unchanged and decided.staged == .unchanged) continue;
        const owned = try gpa.dupe(u8, path);
        errdefer gpa.free(owned);
        try changes.append(gpa, .{
            .path = owned,
            .untracked = decided.untracked,
            .worktree = decided.worktree,
            .staged = decided.staged,
        });
    }

    const owned = try changes.toOwnedSlice(gpa);
    // Tracked changes first, then untracked, each sorted by path. That is
    // git's own porcelain order, measured: sorting everything together by
    // path alone puts `?? d/also-new.txt` second rather than fifth.
    std.mem.sort(Change, owned, {}, struct {
        fn lessThan(_: void, a: Change, b: Change) bool {
            if (a.untracked != b.untracked) return b.untracked;
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.lessThan);
    return .{ .changes = owned };
}

const Entry = struct { oid: Oid, mode: FileMode, size: u32 };

/// What each of the three sides says about one path. A side that never
/// mentioned it stays null, which is how "absent here" is told apart from
/// "present and equal".
const Sides = struct {
    head: ?Entry = null,
    index: ?Entry = null,
    worktree: ?WorktreeFile = null,
};

const WorktreeFile = struct { size: u64, mode: FileMode };

const Decided = struct { untracked: bool, worktree: Worktree, staged: Staged };

fn decide(
    gpa: Allocator,
    io: std.Io,
    work_tree: std.Io.Dir,
    odb: *Odb,
    f: Format,
    path: []const u8,
    sides: Sides,
) Error!Decided {
    // Neither the index nor HEAD has ever heard of it.
    if (sides.index == null and sides.head == null) {
        return .{ .untracked = sides.worktree != null, .worktree = .unchanged, .staged = .unchanged };
    }

    const staged: Staged = blk: {
        const idx = sides.index orelse break :blk if (sides.head != null) .deleted else .unchanged;
        const head = sides.head orelse break :blk .added;
        if (!idx.oid.eql(head.oid) or idx.mode != head.mode) break :blk .modified;
        break :blk .unchanged;
    };

    const worktree: Worktree = blk: {
        const idx = sides.index orelse break :blk .unchanged;
        const wt = sides.worktree orelse break :blk .deleted;
        if (wt.mode != idx.mode) break :blk .modified;
        // Size is the cheap discriminator and settles most files. Only when
        // it matches is the content worth hashing.
        if (wt.size != idx.size) break :blk .modified;
        const actual = try hashWorktreeFile(gpa, io, work_tree, odb, f, path);
        break :blk if (actual.eql(idx.oid)) .unchanged else .modified;
    };

    return .{ .untracked = false, .worktree = worktree, .staged = staged };
}

/// Hashes the file's current bytes as a blob, without writing it. `status`
/// answers a question; it does not change the object database to do so.
fn hashWorktreeFile(
    gpa: Allocator,
    io: std.Io,
    work_tree: std.Io.Dir,
    odb: *Odb,
    f: Format,
    path: []const u8,
) Error!Oid {
    _ = odb;
    const bytes = work_tree.readFileAlloc(io, path, gpa, .limited(max_file_len)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.IoFailed,
    };
    defer gpa.free(bytes);
    return object_mod.loose.hash(f, .blob, bytes);
}

/// Flattens the tree at `tree_oid` into `paths`, recursing into subtrees.
fn collectTree(
    gpa: Allocator,
    odb: *Odb,
    tree_oid: Oid,
    prefix: []const u8,
    paths: *std.StringArrayHashMapUnmanaged(Sides),
    diag: ?*?Diagnostic,
) Error!void {
    const bytes = try odb.readAlloc(gpa, tree_oid, max_tree_len, diag);
    defer gpa.free(bytes);

    var tree = Tree.parse(gpa, odb.format, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CorruptTree => return error.CorruptObject,
    };
    defer tree.deinit(gpa);

    for (tree.entries) |e| {
        const full = if (prefix.len == 0)
            try gpa.dupe(u8, e.name)
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, e.name });
        errdefer gpa.free(full);

        switch (e.mode) {
            .tree => {
                defer gpa.free(full);
                try collectTree(gpa, odb, e.oid, full, paths, diag);
            },
            // A gitlink names a commit in another repository and is not a
            // file here, so it is not one of this comparison's paths.
            .gitlink => gpa.free(full),
            .blob, .blob_executable, .symlink => {
                const gop = try paths.getOrPut(gpa, full);
                if (gop.found_existing) {
                    gpa.free(full);
                } else {
                    gop.value_ptr.* = .{};
                }
                gop.value_ptr.head = .{ .oid = e.oid, .mode = e.mode, .size = 0 };
            },
        }
    }
}

fn collectWorktree(
    gpa: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path_buf: *[4096]u8,
    path_len: usize,
    paths: *std.StringArrayHashMapUnmanaged(Sides),
    options: Options,
) Error!void {
    var restore_to: usize = 0;
    if (options.ignore) |m| {
        restore_to = m.sourceCount();
        const base = path_buf[0..path_len];
        const trimmed = if (base.len > 0 and base[base.len - 1] == '/') base[0 .. base.len - 1] else base;
        m.addFile(io, dir, ".gitignore", trimmed) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.IoFailed => return error.IoFailed,
        };
    }
    defer if (options.ignore) |m| m.truncate(restore_to);

    var it = dir.iterate();
    while (it.next(io) catch return error.IoFailed) |entry| {
        if (core_mod.isDotGitName(entry.name)) continue;
        if (path_len + entry.name.len + 1 >= path_buf.len) return error.IoFailed;

        @memcpy(path_buf[path_len .. path_len + entry.name.len], entry.name);
        var len = path_len + entry.name.len;

        if (options.ignore) |m| {
            if (m.isIgnored(path_buf[0..len], entry.kind == .directory)) continue;
        }

        switch (entry.kind) {
            .directory => {
                path_buf[len] = '/';
                len += 1;
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch return error.IoFailed;
                defer sub.close(io);
                try collectWorktree(gpa, io, sub, path_buf, len, paths, options);
            },
            .file, .sym_link => {
                const stat = dir.statFile(io, entry.name, .{ .follow_symlinks = false }) catch return error.IoFailed;
                const mode: FileMode = if (entry.kind == .sym_link)
                    .symlink
                else if (@intFromEnum(stat.permissions) & 0o111 != 0)
                    .blob_executable
                else
                    .blob;

                const owned = try gpa.dupe(u8, path_buf[0..len]);
                errdefer gpa.free(owned);
                const gop = try paths.getOrPut(gpa, owned);
                if (gop.found_existing) {
                    gpa.free(owned);
                } else {
                    gop.value_ptr.* = .{};
                }
                gop.value_ptr.worktree = .{ .size = stat.size, .mode = mode };
            },
            else => {},
        }
    }
}

const testing = std.testing;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    odb_tmp: std.testing.TmpDir,
    work: std.Io.Dir,
    odb: Odb,

    fn init(gpa: Allocator, io: std.Io) !Fixture {
        var tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        var odb_tmp = std.testing.tmpDir(.{ .iterate = true });
        errdefer odb_tmp.cleanup();
        try odb_tmp.dir.createDirPath(io, "objects");
        const objects = try odb_tmp.dir.openDir(io, "objects", .{ .iterate = true });
        const odb = try Odb.init(gpa, io, objects, .sha1, .{});
        return .{ .tmp = tmp, .odb_tmp = odb_tmp, .work = tmp.dir, .odb = odb };
    }

    fn deinit(fx: *Fixture) void {
        fx.odb.deinit();
        fx.odb_tmp.cleanup();
        fx.tmp.cleanup();
    }
};

fn indexEntry(path: []const u8, oid: Oid, mode: FileMode, size: u32) index_mod.Entry {
    return .{
        .path = path,
        .oid = oid,
        .mode = mode,
        .stage = .merged,
        .size = size,
        .stat = .{
            .ctime_seconds = 0,
            .ctime_nanoseconds = 0,
            .mtime_seconds = 0,
            .mtime_nanoseconds = 0,
            .dev = 0,
            .ino = 0,
            .uid = 0,
            .gid = 0,
        },
    };
}

test "a worktree matching both its index and HEAD reports nothing" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init(gpa, io);
    defer fx.deinit();

    try fx.work.writeFile(io, .{ .sub_path = "a.txt", .data = "hello\n" });
    const oid = try fx.odb.write(.blob, "hello\n", null);

    var tree_entries = [_]Tree.Entry{.{ .mode = .blob, .name = "a.txt", .oid = oid }};
    const tree: Tree = .{ .entries = &tree_entries };
    var tree_buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&tree_buf);
    try tree.write(&w);
    const tree_oid = try fx.odb.write(.tree, w.buffered(), null);

    var entries = [_]index_mod.Entry{indexEntry("a.txt", oid, .blob, 6)};
    const index: Index = .{ .gpa = gpa, .entries = &entries };

    var result = try status(gpa, io, fx.work, &fx.odb, index, .sha1, .{ .head_tree = tree_oid }, null);
    defer result.deinit(gpa);
    try testing.expect(result.isClean());
}

test "with no HEAD, every index entry is newly added" {
    // An unborn branch. Git reports `A  file` here too: there is no commit
    // for the index to match, so everything staged is an addition.
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init(gpa, io);
    defer fx.deinit();

    try fx.work.writeFile(io, .{ .sub_path = "a.txt", .data = "hello\n" });
    const oid = object_mod.loose.hash(.sha1, .blob, "hello\n");

    var entries = [_]index_mod.Entry{indexEntry("a.txt", oid, .blob, 6)};
    const index: Index = .{ .gpa = gpa, .entries = &entries };

    var result = try status(gpa, io, fx.work, &fx.odb, index, .sha1, .{}, null);
    defer result.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), result.changes.len);
    try testing.expectEqual(Staged.added, result.changes[0].staged);
    try testing.expectEqual(Worktree.unchanged, result.changes[0].worktree);
}

test "a file gone from the worktree is reported as deleted, not dropped" {
    // A deleted file is not on disk, so a walk driven from the worktree
    // alone cannot see it. Driving from the union of the index and the
    // worktree is what keeps it. Losing it would lose exactly the change a
    // caller most needs to hear about.
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init(gpa, io);
    defer fx.deinit();

    const oid = object_mod.loose.hash(.sha1, .blob, "hello\n");
    var entries = [_]index_mod.Entry{indexEntry("gone.txt", oid, .blob, 6)};
    const index: Index = .{ .gpa = gpa, .entries = &entries };

    var result = try status(gpa, io, fx.work, &fx.odb, index, .sha1, .{}, null);
    defer result.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), result.changes.len);
    try testing.expectEqualStrings("gone.txt", result.changes[0].path);
    try testing.expectEqual(Worktree.deleted, result.changes[0].worktree);
    try testing.expect(!result.changes[0].untracked);
}

test "changed bytes of the same length are still reported as modified" {
    // Size is the cheap discriminator, so a change that keeps the length is
    // the case that catches an implementation which stops there.
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init(gpa, io);
    defer fx.deinit();

    try fx.work.writeFile(io, .{ .sub_path = "a.txt", .data = "world\n" });
    const stale = object_mod.loose.hash(.sha1, .blob, "hello\n");

    var entries = [_]index_mod.Entry{indexEntry("a.txt", stale, .blob, 6)};
    const index: Index = .{ .gpa = gpa, .entries = &entries };

    var result = try status(gpa, io, fx.work, &fx.odb, index, .sha1, .{}, null);
    defer result.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), result.changes.len);
    try testing.expectEqual(Worktree.modified, result.changes[0].worktree);
}

test "a path in neither the index nor HEAD is untracked" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init(gpa, io);
    defer fx.deinit();

    try fx.work.writeFile(io, .{ .sub_path = "new.txt", .data = "x\n" });
    const index: Index = .{ .gpa = gpa, .entries = &.{} };

    var result = try status(gpa, io, fx.work, &fx.odb, index, .sha1, .{}, null);
    defer result.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), result.changes.len);
    try testing.expect(result.changes[0].untracked);
    try testing.expectEqualStrings("new.txt", result.changes[0].path);
}

test "an ignored path is not reported as untracked" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init(gpa, io);
    defer fx.deinit();

    try fx.work.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.tmp\n" });
    try fx.work.writeFile(io, .{ .sub_path = "scratch.tmp", .data = "x\n" });

    var m = ignore_mod.Matcher.init(gpa);
    defer m.deinit();

    const index: Index = .{ .gpa = gpa, .entries = &.{} };
    var result = try status(gpa, io, fx.work, &fx.odb, index, .sha1, .{ .ignore = &m }, null);
    defer result.deinit(gpa);

    // `.gitignore` itself is an ordinary untracked file; the `.tmp` is not
    // reported at all.
    try testing.expectEqual(@as(usize, 1), result.changes.len);
    try testing.expectEqualStrings(".gitignore", result.changes[0].path);
}

test "tracked changes sort before untracked ones" {
    // Git's porcelain order, measured: sorting everything by path alone put
    // an untracked `d/...` second rather than last.
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init(gpa, io);
    defer fx.deinit();

    try fx.work.writeFile(io, .{ .sub_path = "aaa-untracked.txt", .data = "x\n" });
    const oid = object_mod.loose.hash(.sha1, .blob, "hello\n");
    var entries = [_]index_mod.Entry{indexEntry("zzz-gone.txt", oid, .blob, 6)};
    const index: Index = .{ .gpa = gpa, .entries = &entries };

    var result = try status(gpa, io, fx.work, &fx.odb, index, .sha1, .{}, null);
    defer result.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), result.changes.len);
    // `zzz` sorts after `aaa` by path, and still comes first because it is
    // tracked.
    try testing.expectEqualStrings("zzz-gone.txt", result.changes[0].path);
    try testing.expectEqualStrings("aaa-untracked.txt", result.changes[1].path);
}
