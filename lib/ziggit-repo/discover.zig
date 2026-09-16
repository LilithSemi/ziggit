//! Repository discovery: walking up from a starting directory to find a
//! `.git` directory or a `.git` file, with no knowledge of config or the
//! object hash format.
//!
//! This file never reads `core.repositoryformatversion` or
//! `extensions.objectFormat`: doing that means reading config, and reading
//! config is `Repository.open`'s job, not this one's. Keeping that seam
//! clean is what lets `Layout` be a plain struct instead of a half-built
//! `Repository`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;

const layout_mod = @import("Layout.zig");
pub const Layout = layout_mod.Layout;

/// Narrower than `Repository.Error`: `discover` never opens a config file,
/// so it cannot return `Config.Error`, `Odb.Error`, or `Store.Error`. That
/// is this module's own design, stated in the file comment above, not an
/// oversight left over from a wider set.
pub const Error = error{
    NotARepository,
    CorruptGitFile,
    IoFailed,
} || Allocator.Error;

pub const DiscoverOptions = struct {
    /// Not honored today. `git`'s own default refuses to walk up past a
    /// filesystem boundary; this build differs, and crosses one silently.
    /// `true` and `false` produce identical behavior right now.
    ///
    /// `discover` cannot detect a genuine mid-tree filesystem boundary:
    /// `std.Io.File.Stat` carries no device id in Zig 0.16, and
    /// `std.posix` is not available to this project. The one check the
    /// walk does perform, comparing `current`'s inode to its parent's, at
    /// `discover`'s own loop below, catches only the case where `..`
    /// resolves back to `current` itself, the top of the whole directory
    /// tree. A real boundary crossing has two unrelated inode numbers on
    /// two different devices, and that check does not see the device
    /// half, so the walk passes straight through it.
    cross_filesystem: bool = false,
    /// GIT_DIR. When set, discovery opens this directory directly and does
    /// not walk upward at all.
    git_dir_override: ?[]const u8 = null,
    /// GIT_WORK_TREE. Only consulted when `git_dir_override` is also set:
    /// an upward walk always finds its own work tree, the directory that
    /// held the `.git` entry it found.
    work_tree_override: ?[]const u8 = null,
};

/// Longest `.git` file or `commondir` file this reads. Both name a single
/// filesystem path; this is a defensive ceiling against a hostile or
/// corrupt one, not a spec limit.
const max_link_file_len: std.Io.Limit = .limited(4096);

/// How many directories the upward walk visits before giving up. A
/// defensive ceiling against a symlink loop defeating the
/// reached-the-top check below, not a realistic directory depth.
const max_walk_depth: usize = 4096;

/// Walks up from `start` looking for a `.git` directory or a `.git` file
/// holding `gitdir: <path>`. Never reads config; never knows the object
/// hash format.
pub fn discover(gpa: Allocator, io: std.Io, start: std.Io.Dir, options: DiscoverOptions, diag: ?*?Diagnostic) Error!Layout {
    if (options.git_dir_override) |override_path| {
        return discoverFromOverride(gpa, io, start, override_path, options, diag);
    }

    var current = dupDir(io, start) catch return error.IoFailed;

    var depth: usize = 0;
    while (true) {
        const entry = findGitEntry(gpa, io, current, diag) catch |err| {
            current.close(io);
            return err;
        };
        if (entry) |e| {
            switch (e) {
                .directory => return buildFromGitDirEntry(gpa, io, current, diag),
                .file => |gitdir_path| {
                    defer gpa.free(gitdir_path);
                    return buildFromGitFile(gpa, io, current, gitdir_path, diag);
                },
            }
        }

        const bare = looksLikeBareGitDir(io, current) catch |err| {
            current.close(io);
            return err;
        };
        if (bare) return buildFromBareDir(gpa, io, current, diag);

        depth += 1;
        if (depth > max_walk_depth) {
            current.close(io);
            return error.NotARepository;
        }

        var parent = current.openDir(io, "..", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                current.close(io);
                return error.NotARepository;
            },
            else => {
                current.close(io);
                return error.IoFailed;
            },
        };
        const cur_stat = current.stat(io) catch {
            current.close(io);
            parent.close(io);
            return error.IoFailed;
        };
        const parent_stat = parent.stat(io) catch {
            current.close(io);
            parent.close(io);
            return error.IoFailed;
        };
        current.close(io);
        if (cur_stat.inode == parent_stat.inode) {
            // `..` resolved back to `current` itself: the top of the
            // whole directory tree, not a filesystem boundary. This does
            // not detect a boundary; see
            // `DiscoverOptions.cross_filesystem` for why it cannot.
            parent.close(io);
            return error.NotARepository;
        }
        current = parent;
    }
}

const GitEntry = union(enum) {
    directory,
    /// The path text after `gitdir: `, trimmed. Owned; freed by the
    /// caller.
    file: []u8,
};

/// Checks `dir` for its own `.git` entry, without opening it as anything
/// more than a stat: the real open, and the ownership decision that comes
/// with it, belongs to whichever `build*` function handles the result.
fn findGitEntry(gpa: Allocator, io: std.Io, dir: std.Io.Dir, diag: ?*?Diagnostic) Error!?GitEntry {
    const st = dir.statFile(io, ".git", .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return error.IoFailed,
    };
    return switch (st.kind) {
        .directory => .directory,
        .file => .{ .file = try readGitFile(gpa, io, dir, diag) },
        // A `.git` entry that is neither a directory nor a file (a socket,
        // a device, ...) is not a shape this build understands. Refusing
        // beats guessing which of the two it should be treated as.
        else => {
            reportCorruptGitFile(diag, gpa, ".git");
            return error.CorruptGitFile;
        },
    };
}

fn readGitFile(gpa: Allocator, io: std.Io, dir: std.Io.Dir, diag: ?*?Diagnostic) Error![]u8 {
    const content = dir.readFileAlloc(io, ".git", gpa, max_link_file_len) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.IoFailed,
    };
    defer gpa.free(content);

    const prefix = "gitdir: ";
    if (!std.mem.startsWith(u8, content, prefix)) {
        reportCorruptGitFile(diag, gpa, ".git");
        return error.CorruptGitFile;
    }
    const rest = std.mem.trim(u8, content[prefix.len..], " \t\r\n");
    if (rest.len == 0) {
        reportCorruptGitFile(diag, gpa, ".git");
        return error.CorruptGitFile;
    }
    return gpa.dupe(u8, rest);
}

/// Reports a `.git` or `commondir` file that failed to parse. `path`
/// names the file relative to the directory holding it, since this file
/// never knows the discovered repository's full path.
fn reportCorruptGitFile(diag: ?*?Diagnostic, gpa: Allocator, path: []const u8) void {
    if (!core_mod.wants(diag)) return;
    const owned = gpa.dupe(u8, path) catch null;
    core_mod.report(diag, gpa, .{ .kind = .corrupt_gitfile, .path = owned, .detail = null });
}

/// `work_tree` looks like a bare git directory in its own right: no `.git`
/// entry, but a `HEAD` file and `objects` and `refs` directories directly
/// inside it. This is a heuristic, the same one git itself uses; there is
/// no config to consult yet, since reading config is `Repository.open`'s
/// job.
fn looksLikeBareGitDir(io: std.Io, dir: std.Io.Dir) Error!bool {
    const head_stat = dir.statFile(io, "HEAD", .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return error.IoFailed,
    };
    if (head_stat.kind != .file) return false;

    var objects_dir = dir.openDir(io, "objects", .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return error.IoFailed,
    };
    objects_dir.close(io);

    var refs_dir = dir.openDir(io, "refs", .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => return error.IoFailed,
    };
    refs_dir.close(io);

    return true;
}

/// `work_tree` held a `.git` directory. Consumes `work_tree`: closed on
/// every error path, stored into the returned `Layout` on success.
fn buildFromGitDirEntry(gpa: Allocator, io: std.Io, work_tree: std.Io.Dir, diag: ?*?Diagnostic) Error!Layout {
    var git_dir = work_tree.openDir(io, ".git", .{ .iterate = true }) catch {
        work_tree.close(io);
        return error.IoFailed;
    };
    errdefer git_dir.close(io);

    const cd = resolveCommonDir(gpa, io, git_dir, diag) catch |err| {
        work_tree.close(io);
        return err;
    };
    return .{
        .git_dir = git_dir,
        .common_dir = cd.dir,
        .work_tree = work_tree,
        .is_bare = false,
        .is_linked_worktree = cd.is_linked,
    };
}

/// `work_tree` held a `.git` file naming `gitdir_path`. Consumes
/// `work_tree` exactly as `buildFromGitDirEntry` does.
fn buildFromGitFile(gpa: Allocator, io: std.Io, work_tree: std.Io.Dir, gitdir_path: []const u8, diag: ?*?Diagnostic) Error!Layout {
    var git_dir = openDirRelative(io, work_tree, gitdir_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => {
            work_tree.close(io);
            return error.NotARepository;
        },
        else => {
            work_tree.close(io);
            return error.IoFailed;
        },
    };
    errdefer git_dir.close(io);

    const cd = resolveCommonDir(gpa, io, git_dir, diag) catch |err| {
        work_tree.close(io);
        return err;
    };
    return .{
        .git_dir = git_dir,
        .common_dir = cd.dir,
        .work_tree = work_tree,
        .is_bare = false,
        .is_linked_worktree = cd.is_linked,
    };
}

/// `git_dir` itself looked like a bare repository. Consumes `git_dir`.
fn buildFromBareDir(gpa: Allocator, io: std.Io, git_dir: std.Io.Dir, diag: ?*?Diagnostic) Error!Layout {
    const cd = resolveCommonDir(gpa, io, git_dir, diag) catch |err| {
        git_dir.close(io);
        return err;
    };
    return .{
        .git_dir = git_dir,
        .common_dir = cd.dir,
        .work_tree = null,
        .is_bare = true,
        .is_linked_worktree = cd.is_linked,
    };
}

const CommonDirResult = struct { dir: std.Io.Dir, is_linked: bool };

/// Reads `git_dir`'s own `commondir` file, if it has one, and resolves the
/// directory it names, relative to `git_dir` when the path is not
/// absolute. Returns `git_dir` itself, handle for handle, when there is no
/// such file: every repository that is not a linked worktree keeps refs,
/// config, and objects directly in its own git directory. Never closes or
/// otherwise takes ownership of `git_dir`.
fn resolveCommonDir(gpa: Allocator, io: std.Io, git_dir: std.Io.Dir, diag: ?*?Diagnostic) Error!CommonDirResult {
    const content = git_dir.readFileAlloc(io, "commondir", gpa, max_link_file_len) catch |err| switch (err) {
        error.FileNotFound => return .{ .dir = git_dir, .is_linked = false },
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.IoFailed,
    };
    defer gpa.free(content);

    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) {
        reportCorruptGitFile(diag, gpa, "commondir");
        return error.CorruptGitFile;
    }

    const common = openDirRelative(io, git_dir, trimmed) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.NotARepository,
        else => return error.IoFailed,
    };
    return .{ .dir = common, .is_linked = true };
}

fn discoverFromOverride(gpa: Allocator, io: std.Io, start: std.Io.Dir, override_path: []const u8, options: DiscoverOptions, diag: ?*?Diagnostic) Error!Layout {
    var git_dir = openDirRelative(io, start, override_path) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return error.NotARepository,
        else => return error.IoFailed,
    };
    errdefer git_dir.close(io);

    const cd = try resolveCommonDir(gpa, io, git_dir, diag);

    var work_tree: ?std.Io.Dir = null;
    if (options.work_tree_override) |wt_path| {
        work_tree = openDirRelative(io, start, wt_path) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => {
                if (cd.is_linked) cd.dir.close(io);
                return error.NotARepository;
            },
            else => {
                if (cd.is_linked) cd.dir.close(io);
                return error.IoFailed;
            },
        };
    } else if (gitDirNameLooksNonBare(override_path)) {
        // git's own rule for an explicit `GIT_DIR` with neither
        // `GIT_WORK_TREE` nor `core.worktree` to consult (this module
        // never reads config, so neither is available here): a `GIT_DIR`
        // literally named ".git" is the ordinary shape a ".git" directory
        // inside a work tree has, so the directory this walk started from
        // is that work tree. Any other name is what an operator points at
        // a bare repository on purpose, and stays bare.
        work_tree = dupDir(io, start) catch {
            if (cd.is_linked) cd.dir.close(io);
            return error.IoFailed;
        };
    }

    return .{
        .git_dir = git_dir,
        .common_dir = cd.dir,
        .work_tree = work_tree,
        .is_bare = work_tree == null,
        .is_linked_worktree = cd.is_linked,
    };
}

/// True when `path`'s final "/"-separated component is exactly ".git".
fn gitDirNameLooksNonBare(path: []const u8) bool {
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    const trimmed = path[0..end];
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/');
    const base = if (slash) |s| trimmed[s + 1 ..] else trimmed;
    return std.mem.eql(u8, base, ".git");
}

/// A fresh, independently closable handle to the same directory as `dir`.
fn dupDir(io: std.Io, dir: std.Io.Dir) std.Io.Dir.OpenError!std.Io.Dir {
    return dir.openDir(io, ".", .{ .iterate = true });
}

const openDirRelative = core_mod.openDirRelative;

// expected

test "discover finds a .git directory in the starting directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/marker", .data = "hello" });

    var layout = try discover(gpa, io, tmp.dir, .{}, null);
    defer layout.deinit(io);

    try std.testing.expect(!layout.is_bare);
    try std.testing.expect(!layout.is_linked_worktree);
    try std.testing.expect(layout.work_tree != null);

    const content = try layout.git_dir.readFileAlloc(io, "marker", gpa, .limited(64));
    defer gpa.free(content);
    try std.testing.expectEqualStrings("hello", content);
}

test "discover walks up two levels to find a .git directory" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.createDirPath(io, "a/b");
    try tmp.dir.writeFile(io, .{ .sub_path = "top_marker", .data = "top" });

    var start = try tmp.dir.openDir(io, "a/b", .{ .iterate = true });
    defer start.close(io);

    var layout = try discover(gpa, io, start, .{}, null);
    defer layout.deinit(io);

    const content = try layout.work_tree.?.readFileAlloc(io, "top_marker", gpa, .limited(64));
    defer gpa.free(content);
    try std.testing.expectEqualStrings("top", content);
}

test "discover reads a .git file holding gitdir: and follows it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "real.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "real.git/marker", .data = "hi" });
    try tmp.dir.createDirPath(io, "work");
    try tmp.dir.writeFile(io, .{ .sub_path = "work/.git", .data = "gitdir: ../real.git\n" });

    var start = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer start.close(io);

    var layout = try discover(gpa, io, start, .{}, null);
    defer layout.deinit(io);

    try std.testing.expect(!layout.is_linked_worktree);
    const content = try layout.git_dir.readFileAlloc(io, "marker", gpa, .limited(64));
    defer gpa.free(content);
    try std.testing.expectEqualStrings("hi", content);
}

test "discover reads commondir for a linked worktree" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "main.git/worktrees/wt1");
    try tmp.dir.writeFile(io, .{ .sub_path = "main.git/marker", .data = "common" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.git/worktrees/wt1/commondir", .data = "../..\n" });
    try tmp.dir.createDirPath(io, "wt");
    try tmp.dir.writeFile(io, .{ .sub_path = "wt/.git", .data = "gitdir: ../main.git/worktrees/wt1\n" });

    var start = try tmp.dir.openDir(io, "wt", .{ .iterate = true });
    defer start.close(io);

    var layout = try discover(gpa, io, start, .{}, null);
    defer layout.deinit(io);

    try std.testing.expect(layout.is_linked_worktree);
    try std.testing.expect(layout.git_dir.handle != layout.common_dir.handle);
    const content = try layout.common_dir.readFileAlloc(io, "marker", gpa, .limited(64));
    defer gpa.free(content);
    try std.testing.expectEqualStrings("common", content);
}

// suspicious

/// A `std.Io` that behaves exactly like `std.testing.io`, except opening
/// `".."` from one specific, pre-recorded directory returns a fresh handle
/// to that same directory instead of its real parent. This simulates
/// reaching the top of the whole directory tree (`..` resolving back to
/// itself) without the walk ever touching a real directory outside the
/// test's own temporary one.
///
/// `std.Io.File.Stat` carries no device id in this Zig version, so no test
/// in this file can build a genuine cross-filesystem boundary. This double
/// exercises the one thing `discover`'s upward walk can detect without a
/// device id: `..` resolving back to `current` itself.
///
/// State lives on the instance, not in a package-level `var`: a caller
/// keeps a `RootLoop` alive on its own stack and reaches it back through
/// `std.Io.userdata`, the same way any other `std.Io` implementation
/// would.
const RootLoop = struct {
    boundary_inode: std.Io.File.INode,
    /// `std.testing.io`'s own userdata, forwarded on every call so the
    /// real implementation underneath still sees what it expects.
    real_userdata: ?*anyopaque,
    table: std.Io.VTable,

    fn dirOpenDir(
        userdata: ?*anyopaque,
        dir: std.Io.Dir,
        sub_path: []const u8,
        options: std.Io.Dir.OpenOptions,
    ) std.Io.Dir.OpenError!std.Io.Dir {
        const self: *RootLoop = @ptrCast(@alignCast(userdata.?));
        // Matched by inode, not by handle: the walk opens a fresh handle
        // for every directory it visits, including one for the boundary
        // directory itself on its way through, so a handle recorded once
        // up front would never match it again.
        if (std.mem.eql(u8, sub_path, "..")) {
            if (std.testing.io.vtable.dirStat(self.real_userdata, dir)) |st| {
                if (st.inode == self.boundary_inode) {
                    return std.testing.io.vtable.dirOpenDir(self.real_userdata, dir, ".", options);
                }
            } else |_| {}
        }
        return std.testing.io.vtable.dirOpenDir(self.real_userdata, dir, sub_path, options);
    }

    /// Fills `rl` in place and returns a `std.Io` backed by it. `rl` must
    /// outlive the returned `std.Io`.
    fn init(rl: *RootLoop, boundary: std.Io.Dir) std.Io.Dir.StatError!std.Io {
        const st = try boundary.stat(std.testing.io);
        rl.* = .{
            .boundary_inode = st.inode,
            .real_userdata = std.testing.io.userdata,
            .table = std.testing.io.vtable.*,
        };
        rl.table.dirOpenDir = dirOpenDir;
        return .{ .userdata = rl, .vtable = &rl.table };
    }
};

test "discover stops when a parent directory is its own parent" {
    // See `RootLoop`'s doc comment: without a device id, this proves only
    // that the walk stops where ascending becomes impossible, the top of
    // the whole directory tree. It does not prove this build can tell a
    // genuine mid-tree filesystem boundary apart from that; it cannot.
    // See `DiscoverOptions.cross_filesystem`.
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "x");
    var root_loop: RootLoop = undefined;
    const io = try RootLoop.init(&root_loop, tmp.dir);

    var start = try tmp.dir.openDir(io, "x", .{ .iterate = true });
    defer start.close(io);

    try std.testing.expectError(error.NotARepository, discover(gpa, io, start, .{ .cross_filesystem = false }, null));
}

test "discover fails with NotARepository when it reaches the root" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "a/b");
    var root_loop: RootLoop = undefined;
    const io = try RootLoop.init(&root_loop, tmp.dir);

    var start = try tmp.dir.openDir(io, "a/b", .{ .iterate = true });
    defer start.close(io);

    try std.testing.expectError(error.NotARepository, discover(gpa, io, start, .{}, null));
}

test "a .git file with no gitdir: prefix is CorruptGitFile" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".git", .data = "not a gitdir line\n" });

    try std.testing.expectError(error.CorruptGitFile, discover(gpa, io, tmp.dir, .{}, null));
}

test "a .git file naming a path that does not exist is NotARepository" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".git", .data = "gitdir: does-not-exist\n" });

    try std.testing.expectError(error.NotARepository, discover(gpa, io, tmp.dir, .{}, null));
}

test "GIT_DIR override skips the upward walk entirely" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // No `.git` anywhere in this tree; only the override target exists,
    // reachable only relative to `start`, never by walking up from it.
    try tmp.dir.createDirPath(io, "elsewhere/realgit");
    try tmp.dir.writeFile(io, .{ .sub_path = "elsewhere/realgit/marker", .data = "hi" });
    try tmp.dir.createDirPath(io, "start_here");

    var start = try tmp.dir.openDir(io, "start_here", .{ .iterate = true });
    defer start.close(io);

    var layout = try discover(gpa, io, start, .{ .git_dir_override = "../elsewhere/realgit" }, null);
    defer layout.deinit(io);

    const content = try layout.git_dir.readFileAlloc(io, "marker", gpa, .limited(64));
    defer gpa.free(content);
    try std.testing.expectEqualStrings("hi", content);
    try std.testing.expect(layout.is_bare);
    try std.testing.expect(layout.work_tree == null);
}

test "GIT_DIR override named .git with no GIT_WORK_TREE treats the starting directory as the work tree" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    // An ordinary repository laid out under a directory literally named
    // ".git", exactly what `GIT_DIR=.git git ...` points at from inside a
    // normal work tree. git assumes non-bare here and regards the current
    // directory as the top of the work tree; this module cannot read
    // `core.worktree` to confirm it, but the ".git" name alone is git's
    // own default for this case.
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/marker", .data = "hi" });

    var layout = try discover(gpa, io, tmp.dir, .{ .git_dir_override = ".git" }, null);
    defer layout.deinit(io);

    try std.testing.expect(!layout.is_bare);
    try std.testing.expect(layout.work_tree != null);
}

test "a linked worktree reads its refs from the common dir, not its own git dir" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const refs_mod = @import("ziggit-refs");
    const oid_mod = @import("ziggit-oid");

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "main.git/refs/heads");
    try tmp.dir.writeFile(io, .{ .sub_path = "main.git/refs/heads/main", .data = "1111111111111111111111111111111111111111\n" });
    try tmp.dir.createDirPath(io, "main.git/worktrees/wt1");
    try tmp.dir.writeFile(io, .{ .sub_path = "main.git/worktrees/wt1/commondir", .data = "../..\n" });
    // A decoy ref of the same name inside the per-worktree admin
    // directory. A correct implementation must never resolve this one.
    try tmp.dir.createDirPath(io, "main.git/worktrees/wt1/refs/heads");
    try tmp.dir.writeFile(io, .{ .sub_path = "main.git/worktrees/wt1/refs/heads/main", .data = "2222222222222222222222222222222222222222\n" });
    try tmp.dir.createDirPath(io, "wt");
    try tmp.dir.writeFile(io, .{ .sub_path = "wt/.git", .data = "gitdir: ../main.git/worktrees/wt1\n" });

    var start = try tmp.dir.openDir(io, "wt", .{ .iterate = true });
    defer start.close(io);
    var layout = try discover(gpa, io, start, .{}, null);
    defer layout.deinit(io);

    var store = refs_mod.Store.init(gpa, io, layout.common_dir, .sha1, null);
    defer store.deinit();
    var ref = try store.lookup("refs/heads/main", null);
    defer ref.deinit(gpa);
    var buf: [oid_mod.Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("1111111111111111111111111111111111111111", ref.target.oid.toHex(&buf));
}
