//! Resolves the read-only object directories `Odb` searches beyond its
//! primary directory: the directories named directly through
//! `Odb.Options.alternate_directories`, plus any further directory named,
//! transitively, by each location's own `objects/info/alternates` file.
//!
//! Every directory this file opens is handed back to the caller read-only
//! in spirit: nothing in `ziggit-odb` ever writes through a `Dir` this
//! module returns.

const std = @import("std");
const Allocator = std.mem.Allocator;

const core_mod = @import("ziggit-core");

pub const Error = error{
    AlternatesCycle,
    AlternatesTooDeep,
    IoFailed,
} || Allocator.Error;

/// Longest `objects/info/alternates` file this reads. A real one lists a
/// handful of paths; this is a defensive ceiling against a hostile one, not
/// a spec limit.
const max_alternates_file_len: std.Io.Limit = .limited(65536);

const Pending = struct { dir: std.Io.Dir, depth: usize };

/// Resolves every alternate object directory reachable from `primary`.
///
/// `extra` is a list of directory paths named directly (as
/// `GIT_ALTERNATE_OBJECT_DIRECTORIES` would supply), each relative to the
/// process's current directory unless it starts with `/`. `primary`'s own
/// `objects/info/alternates` file, and the same file in every directory
/// this call discovers, are read in turn: a relative path inside one of
/// those files resolves against the directory that named it, not against
/// the process working directory.
///
/// `max_depth` bounds how many `info/alternates` hops this follows before
/// giving up with `AlternatesTooDeep`. A directory whose chain names one
/// already counted, `primary` itself included, fails with
/// `AlternatesCycle` instead of looping forever.
///
/// Every `std.Io.Dir` in the returned slice is opened with
/// `.{ .iterate = true }`, matching what `loose_backend` and
/// `pack_backend` need to search it, and is owned by the caller from this
/// point on: close each one, then free the slice with `gpa`.
pub fn resolve(
    gpa: Allocator,
    io: std.Io,
    primary: std.Io.Dir,
    extra: []const []const u8,
    max_depth: usize,
) Error![]std.Io.Dir {
    var visited: std.ArrayList(std.Io.File.INode) = .empty;
    defer visited.deinit(gpa);
    try visited.append(gpa, try inodeOf(primary, io));

    var result: std.ArrayList(std.Io.Dir) = .empty;
    errdefer {
        for (result.items) |d| d.close(io);
        result.deinit(gpa);
    }

    var queue: std.ArrayList(Pending) = .empty;
    defer queue.deinit(gpa);

    for (extra) |path| {
        const dir = try openFromCwd(io, path);
        try admit(gpa, io, dir, 1, max_depth, &visited, &result, &queue);
    }

    try expandAlternatesFile(gpa, io, primary, 0, max_depth, &visited, &result, &queue);

    var i: usize = 0;
    while (i < queue.items.len) : (i += 1) {
        const item = queue.items[i];
        try expandAlternatesFile(gpa, io, item.dir, item.depth, max_depth, &visited, &result, &queue);
    }

    return result.toOwnedSlice(gpa);
}

/// Records a newly opened alternate directory `dir`: checks it against
/// `visited` and `max_depth`, then adds it to `result` and `queue`. Closes
/// `dir` and returns an error without adding it anywhere when either check
/// fails.
fn admit(
    gpa: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    depth: usize,
    max_depth: usize,
    visited: *std.ArrayList(std.Io.File.INode),
    result: *std.ArrayList(std.Io.Dir),
    queue: *std.ArrayList(Pending),
) Error!void {
    if (depth > max_depth) {
        dir.close(io);
        return error.AlternatesTooDeep;
    }
    const inode = inodeOf(dir, io) catch |err| {
        dir.close(io);
        return err;
    };
    if (contains(visited.items, inode)) {
        dir.close(io);
        return error.AlternatesCycle;
    }
    visited.append(gpa, inode) catch |err| {
        // `dir` is not yet in `result`, so the caller's own errdefer over
        // `result.items` cannot see it: this is the last chance to close
        // it before ownership was meant to pass to `result` below.
        dir.close(io);
        return err;
    };
    try result.append(gpa, dir);
    try queue.append(gpa, .{ .dir = dir, .depth = depth });
}

/// Cycle detection here compares inode numbers alone, with no device id:
/// `std.Io.File.Stat` carries no device id in Zig 0.16, and `std.posix` is
/// not available to this project, the same limitation `discover.zig`'s
/// `DiscoverOptions.cross_filesystem` documents. Two alternate directories
/// on different filesystems that happen to share an inode number are
/// reported as `AlternatesCycle` even though they are genuinely distinct
/// directories. This cannot be fixed without a device id to pair with the
/// inode; it can only be documented.
fn contains(items: []const std.Io.File.INode, needle: std.Io.File.INode) bool {
    for (items) |v| if (v == needle) return true;
    return false;
}

fn inodeOf(dir: std.Io.Dir, io: std.Io) Error!std.Io.File.INode {
    const st = dir.stat(io) catch return error.IoFailed;
    return st.inode;
}

fn openFromCwd(io: std.Io, path: []const u8) Error!std.Io.Dir {
    return core_mod.openDirRelative(io, null, path) catch return error.IoFailed;
}

fn openRelativeTo(base: std.Io.Dir, io: std.Io, path: []const u8) Error!std.Io.Dir {
    return core_mod.openDirRelative(io, base, path) catch return error.IoFailed;
}

/// Reads `dir`'s own `objects/info/alternates` file, if any, and admits
/// every directory it names.
fn expandAlternatesFile(
    gpa: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    depth: usize,
    max_depth: usize,
    visited: *std.ArrayList(std.Io.File.INode),
    result: *std.ArrayList(std.Io.Dir),
    queue: *std.ArrayList(Pending),
) Error!void {
    const content = dir.readFileAlloc(io, "info/alternates", gpa, max_alternates_file_len) catch |err| switch (err) {
        error.FileNotFound => return,
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.IoFailed,
    };
    defer gpa.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const child = try openRelativeTo(dir, io, line);
        try admit(gpa, io, child, depth + 1, max_depth, visited, result, queue);
    }
}

/// Closes every directory `resolve` returned and frees the slice. `resolve`
/// documents these as caller-owned; this is the paired teardown a caller
/// (in practice, `Odb.deinit` on an error path, and every test below)
/// reaches for.
pub fn freeAll(gpa: Allocator, io: std.Io, dirs: []std.Io.Dir) void {
    for (dirs) |d| d.close(io);
    gpa.free(dirs);
}

// expected

test "resolve finds a directory named by alternate_directories" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var primary_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer primary_tmp.cleanup();
    var alt_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer alt_tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const alt_path_len = try alt_tmp.dir.realPath(io, &path_buf);
    const alt_path = path_buf[0..alt_path_len];

    const resolved = try resolve(gpa, io, primary_tmp.dir, &.{alt_path}, 5);
    defer freeAll(gpa, io, resolved);
    try std.testing.expectEqual(@as(usize, 1), resolved.len);
}

test "resolve follows a relative path in an alternates file to a sibling directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var root = std.testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();

    try root.dir.createDirPath(io, "primary/info");
    try root.dir.createDirPath(io, "other");
    try root.dir.writeFile(io, .{ .sub_path = "primary/info/alternates", .data = "../other\n" });

    var primary_dir = try root.dir.openDir(io, "primary", .{ .iterate = true });
    defer primary_dir.close(io);

    const resolved = try resolve(gpa, io, primary_dir, &.{}, 5);
    defer freeAll(gpa, io, resolved);
    try std.testing.expectEqual(@as(usize, 1), resolved.len);

    // Prove it is genuinely "other", not merely any directory: write a
    // marker there directly and read it back through the resolved handle.
    try root.dir.writeFile(io, .{ .sub_path = "other/marker", .data = "hi" });
    const content = try resolved[0].readFileAlloc(io, "marker", gpa, .limited(64));
    defer gpa.free(content);
    try std.testing.expectEqualStrings("hi", content);
}

// suspicious

test "an alternates file naming its own directory fails with AlternatesCycle" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "info");
    try tmp.dir.writeFile(io, .{ .sub_path = "info/alternates", .data = ".\n" });

    try std.testing.expectError(error.AlternatesCycle, resolve(gpa, io, tmp.dir, &.{}, 5));
}

test "an alternates chain deeper than max_alternates_depth fails rather than recursing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var root = std.testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();

    // Six links: d0/info/alternates -> d1, d1 -> d2, ..., d5 -> d6. Starting
    // the search at d0 with max_depth 5 must fail once it tries to admit
    // d6, the sixth hop, since each link off `primary` itself already
    // counts as depth 1.
    var link: usize = 0;
    while (link <= 6) : (link += 1) {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "d{d}", .{link});
        try root.dir.createDirPath(io, name);
    }
    link = 0;
    while (link < 6) : (link += 1) {
        var alt_buf: [32]u8 = undefined;
        const alt_file = try std.fmt.bufPrint(&alt_buf, "d{d}/info", .{link});
        try root.dir.createDirPath(io, alt_file);
        var data_buf: [16]u8 = undefined;
        const data = try std.fmt.bufPrint(&data_buf, "../d{d}\n", .{link + 1});
        var path_buf: [32]u8 = undefined;
        const info_path = try std.fmt.bufPrint(&path_buf, "d{d}/info/alternates", .{link});
        try root.dir.writeFile(io, .{ .sub_path = info_path, .data = data });
    }

    var d0 = try root.dir.openDir(io, "d0", .{ .iterate = true });
    defer d0.close(io);

    try std.testing.expectError(error.AlternatesTooDeep, resolve(gpa, io, d0, &.{}, 5));
}

test "a five deep alternates chain succeeds at exactly max_alternates_depth" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var root = std.testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();

    var link: usize = 0;
    while (link <= 5) : (link += 1) {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "d{d}", .{link});
        try root.dir.createDirPath(io, name);
    }
    link = 0;
    while (link < 5) : (link += 1) {
        var alt_buf: [32]u8 = undefined;
        const alt_file = try std.fmt.bufPrint(&alt_buf, "d{d}/info", .{link});
        try root.dir.createDirPath(io, alt_file);
        var data_buf: [16]u8 = undefined;
        const data = try std.fmt.bufPrint(&data_buf, "../d{d}\n", .{link + 1});
        var path_buf: [32]u8 = undefined;
        const info_path = try std.fmt.bufPrint(&path_buf, "d{d}/info/alternates", .{link});
        try root.dir.writeFile(io, .{ .sub_path = info_path, .data = data });
    }

    var d0 = try root.dir.openDir(io, "d0", .{ .iterate = true });
    defer d0.close(io);

    const resolved = try resolve(gpa, io, d0, &.{}, 5);
    defer freeAll(gpa, io, resolved);
    try std.testing.expectEqual(@as(usize, 5), resolved.len);
}

test "resolve returns an empty slice when there is no alternates file and no extra directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const resolved = try resolve(gpa, io, tmp.dir, &.{}, 5);
    defer freeAll(gpa, io, resolved);
    try std.testing.expectEqual(@as(usize, 0), resolved.len);
}
