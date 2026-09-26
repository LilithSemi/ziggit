//! Linked worktrees: a second checkout of the same repository, sharing one
//! object database and one set of refs.
//!
//! Reading one already works through `ziggit-repo`, which follows a `.git`
//! file and its `commondir`. This adds the writing side.
//!
//! A linked worktree named `w` is two places at once. Under the common git
//! directory:
//!
//! ```
//! .git/worktrees/w/commondir   "../.."
//! .git/worktrees/w/gitdir      absolute path of the worktree's own .git file
//! .git/worktrees/w/HEAD        the commit, detached
//! .git/worktrees/w/ORIG_HEAD   the same commit
//! .git/worktrees/w/index       this worktree's own index
//! ```
//!
//! and in the worktree itself, a `.git` file holding
//! `gitdir: <absolute path of .git/worktrees/w>`.
//!
//! Only detached worktrees are created here. Git can also check out a branch
//! and then refuses to check the same branch out twice; nothing needs that
//! yet, and the refusal is a whole rule of its own.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Oid = oid_mod.Oid;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;

const repo_mod = @import("ziggit-repo");
const Repository = repo_mod.Repository;

const checkout_mod = @import("ziggit-checkout");
const status_mod = @import("ziggit-status");
const index_mod = @import("ziggit-index");
const ignore_mod = @import("ziggit-ignore");
const revwalk_mod = @import("ziggit-revwalk");

pub const Error = error{
    WorktreeExists,
    WorktreeNotFound,
    WorktreeNotEmpty,
    WorktreeDirty,
    IoFailed,
} || repo_mod.Error || checkout_mod.Error || status_mod.Error || revwalk_mod.Error || Allocator.Error;

pub const AddOptions = struct {
    /// Write an index describing the checked-out tree. On by default: without
    /// one, `git status` in the new worktree reports every file twice, as
    /// staged-deleted and untracked, for a tree where nothing changed.
    write_index: bool = true,
};

/// Creates a linked worktree named `name`, detached at `commit`, checked out
/// into `worktree_dir`.
///
/// `worktree_dir` must already exist and be empty. Refusing a populated
/// directory rather than merging into it keeps this from silently adopting
/// whatever was already there.
pub fn add(
    gpa: Allocator,
    io: std.Io,
    repo: *Repository,
    name: []const u8,
    worktree_dir: std.Io.Dir,
    commit: Oid,
    options: AddOptions,
    diag: ?*?Diagnostic,
) Error!void {
    try requireEmpty(io, worktree_dir);

    const admin_rel = try std.fmt.allocPrint(gpa, "worktrees/{s}", .{name});
    defer gpa.free(admin_rel);

    if (repo.layout.common_dir.statFile(io, admin_rel, .{})) |_| {
        return error.WorktreeExists;
    } else |_| {}

    repo.layout.common_dir.createDirPath(io, admin_rel) catch return error.IoFailed;
    errdefer repo.layout.common_dir.deleteTree(io, admin_rel) catch {};

    var admin = repo.layout.common_dir.openDir(io, admin_rel, .{ .iterate = true }) catch return error.IoFailed;
    defer admin.close(io);

    admin.createDirPath(io, "refs") catch return error.IoFailed;
    admin.createDirPath(io, "logs") catch return error.IoFailed;

    var admin_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const admin_path_len = admin.realPath(io, &admin_path_buf) catch return error.IoFailed;
    const admin_path = admin_path_buf[0..admin_path_len];

    var work_path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const work_path_len = worktree_dir.realPath(io, &work_path_buf) catch return error.IoFailed;
    const work_path = work_path_buf[0..work_path_len];

    // `commondir` is relative, so moving the whole repository keeps it valid.
    // `gitdir` and the worktree's `.git` file are absolute, as git writes them.
    try writeFile(io, admin, "commondir", "../..\n");

    const gitdir_text = try std.fmt.allocPrint(gpa, "{s}/.git\n", .{work_path});
    defer gpa.free(gitdir_text);
    try writeFile(io, admin, "gitdir", gitdir_text);

    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const head_text = try std.fmt.allocPrint(gpa, "{s}\n", .{commit.toHex(&hex_buf)});
    defer gpa.free(head_text);
    try writeFile(io, admin, "HEAD", head_text);
    try writeFile(io, admin, "ORIG_HEAD", head_text);

    const dotgit_text = try std.fmt.allocPrint(gpa, "gitdir: {s}\n", .{admin_path});
    defer gpa.free(dotgit_text);
    try writeFile(io, worktree_dir, ".git", dotgit_text);

    const tree = try revwalk_mod.peel(gpa, repo, commit, .tree);
    try checkout_mod.checkoutTree(gpa, io, &repo.odb, worktree_dir, tree, .{
        .write_index_to = if (options.write_index) admin else null,
    }, diag);
}

pub const RemoveOptions = struct {
    /// Delete a worktree whose files differ from its index. Off by default,
    /// matching git, which refuses and tells the caller to use force.
    force: bool = false,
};

/// Deletes the linked worktree `name`: its checked-out files and its
/// administrative directory.
pub fn remove(
    gpa: Allocator,
    io: std.Io,
    repo: *Repository,
    name: []const u8,
    options: RemoveOptions,
    diag: ?*?Diagnostic,
) Error!void {
    const admin_rel = try std.fmt.allocPrint(gpa, "worktrees/{s}", .{name});
    defer gpa.free(admin_rel);

    var admin = repo.layout.common_dir.openDir(io, admin_rel, .{ .iterate = true }) catch
        return error.WorktreeNotFound;
    var admin_open = true;
    defer if (admin_open) admin.close(io);

    const work_path = try readWorktreePath(gpa, io, admin);
    defer gpa.free(work_path);

    var work = std.Io.Dir.cwd().openDir(io, work_path, .{ .iterate = true }) catch null;
    if (work) |*w| {
        defer w.close(io);
        if (!options.force) try requireClean(gpa, io, repo, w.*, admin, diag);
    }

    if (work != null) {
        std.Io.Dir.cwd().deleteTree(io, work_path) catch return error.IoFailed;
    }

    admin.close(io);
    admin_open = false;
    repo.layout.common_dir.deleteTree(io, admin_rel) catch return error.IoFailed;

    // Git drops `worktrees/` once the last one goes.
    repo.layout.common_dir.deleteDir(io, "worktrees") catch {};
}

/// The worktree directory a `gitdir` file points at, with the trailing
/// `/.git` removed.
fn readWorktreePath(gpa: Allocator, io: std.Io, admin: std.Io.Dir) Error![]u8 {
    const raw = admin.readFileAlloc(io, "gitdir", gpa, .limited(std.Io.Dir.max_path_bytes)) catch
        return error.IoFailed;
    defer gpa.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    const suffix = "/.git";
    const path = if (std.mem.endsWith(u8, trimmed, suffix))
        trimmed[0 .. trimmed.len - suffix.len]
    else
        trimmed;
    return gpa.dupe(u8, path);
}

fn requireClean(
    gpa: Allocator,
    io: std.Io,
    repo: *Repository,
    work: std.Io.Dir,
    admin: std.Io.Dir,
    diag: ?*?Diagnostic,
) Error!void {
    var index = index_mod.Index.open(gpa, io, admin, repo.format) catch |err| switch (err) {
        error.IndexNotFound => return,
        else => return err,
    };
    defer index.deinit();

    var matcher = ignore_mod.Matcher.init(gpa);
    defer matcher.deinit();

    var result = try status_mod.status(gpa, io, work, &repo.odb, index, repo.format, .{
        .ignore = &matcher,
    }, diag);
    defer result.deinit(gpa);

    if (!result.isClean()) return error.WorktreeDirty;
}

fn requireEmpty(io: std.Io, dir: std.Io.Dir) Error!void {
    var it = dir.iterate();
    if (it.next(io) catch return error.IoFailed) |_| return error.WorktreeNotEmpty;
}

fn writeFile(io: std.Io, dir: std.Io.Dir, path: []const u8, data: []const u8) Error!void {
    dir.writeFile(io, .{ .sub_path = path, .data = data }) catch return error.IoFailed;
}
