//! Fetching and checking out every submodule a tree records, recursively.
//!
//! A submodule's `path` comes from `.gitmodules`, a file inside the
//! repository, and a repository can come from a remote server: `path` is
//! untrusted the same way a tree entry name is to `ziggit-checkout`.
//! Unlike a tree entry name, a submodule path is legitimately a
//! multi-component relative path, so it cannot simply be rejected for
//! carrying a `/`. `validateSubmodulePath` walks its decomposed
//! components instead, rejecting any `..` component, an absolute path,
//! an empty path, a path beginning with a separator, or one carrying a
//! `\`.
//!
//! A submodule's checked-out commit comes from the gitlink entry in its
//! parent's tree, never from `.gitmodules` itself: `.gitmodules` only
//! names a submodule's `path` and `url`. If the fetched remote does not
//! have the gitlink's commit, that is `error.RefNotFound`, a real
//! failure, never a skip.
//!
//! A relative submodule url (`./…` or `../…`, resolved against the
//! parent's own remote in real git) is not implemented: resolving it
//! would need the parent's own remote url, which this module is not
//! given, and silently treating it as a local filesystem path relative
//! to this process's own working directory -- what `ziggit-fetch`'s bare
//! "no scheme" dispatch would otherwise do -- would resolve against the
//! wrong base entirely. A relative url is refused with
//! `error.UnsupportedProtocol` before it ever reaches `fetch`.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Oid = oid_mod.Oid;
const Format = oid_mod.Format;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;

const object_mod = @import("ziggit-object");
const Tree = object_mod.Tree;
const Commit = object_mod.Commit;

const odb_mod = @import("ziggit-odb");
const Odb = odb_mod.Odb;

const repo_mod = @import("ziggit-repo");
const Repository = repo_mod.Repository;

const fetch_mod = @import("ziggit-fetch");
const checkout_mod = @import("ziggit-checkout");

const gitmodules_mod = @import("gitmodules.zig");
const parseGitmodules = gitmodules_mod.parseGitmodules;
pub const Error = gitmodules_mod.Error;

/// Maximum number of submodule levels below the root this follows. The
/// root's own tree is depth 1 and is never itself a submodule, so a
/// chain of exactly `max_depth` real submodule levels is followed in
/// full and succeeds; a chain one level deeper is
/// `error.SubmoduleTooDeep`. A hostile repository can nest submodules
/// forever, so this bound exists to refuse that, never to silently
/// truncate a legitimate, merely deep, tree.
pub const max_depth: usize = 10;

pub const UpdateOptions = struct {
    recursive: bool = true,
    fetch: fetch_mod.FetchOptions,
    strategy: checkout_mod.Strategy = .{},
    parent_remote_url: ?[]const u8 = null,
};

/// Allocation budget for reading one tree object whole. Matches
/// `ziggit-checkout`'s own ceiling: a hostile or corrupt tree past this
/// is refused, not read.
const max_tree_object_len: usize = 1 << 20;

/// Allocation budget for one commit object. Real commits are a few
/// kilobytes; this is a policy ceiling against a hostile one, matching
/// `ziggit-fetch`'s own.
const max_commit_object_len: usize = 1 << 20;

/// Allocation budget for the `.gitmodules` blob itself.
const max_gitmodules_len: usize = 1 << 20;

/// Fetches and checks out every submodule the tree at `repo`'s `HEAD`
/// records, recursively into `worktree`.
pub fn updateAll(
    gpa: Allocator,
    io: std.Io,
    repo: *Repository,
    worktree: std.Io.Dir,
    options: UpdateOptions,
    diag: ?*?Diagnostic,
) Error!void {
    const tree_oid = (try headTree(gpa, repo, diag)) orelse return;
    try updateAtDepth(gpa, io, repo, worktree, tree_oid, options, diag, 1);
}

/// Walks the submodules `tree_oid` (an already-known tree in `repo`'s own
/// object database) records. `tree_oid` is threaded in explicitly rather
/// than re-derived from `repo.head()` at every level: `updateAll` fetches
/// each submodule with the caller's own refspecs, which land at whatever
/// local ref they name (`refs/remotes/origin/*`, ordinarily), never at
/// `refs/heads/*`, so a submodule's own `HEAD` never resolves after a
/// fetch. The tree that actually matters for one is the gitlink's own
/// pinned commit, already known the moment its checkout runs, not
/// whatever `HEAD` happens to point at.
fn updateAtDepth(
    gpa: Allocator,
    io: std.Io,
    repo: *Repository,
    worktree: std.Io.Dir,
    tree_oid: Oid,
    options: UpdateOptions,
    diag: ?*?Diagnostic,
    depth: usize,
) Error!void {
    const gitmodules_bytes = (try readGitmodulesBlob(gpa, repo, tree_oid, diag)) orelse return;
    defer gpa.free(gitmodules_bytes);

    // A leaf with no `.gitmodules` of its own already returned above,
    // regardless of `depth`: only a level that genuinely carries further
    // submodules can ever exceed the bound.
    if (depth > max_depth) return error.SubmoduleTooDeep;

    const submodules = try parseGitmodules(gpa, gitmodules_bytes);
    defer {
        for (submodules) |*s| {
            var mutable = s.*;
            mutable.deinit(gpa);
        }
        gpa.free(submodules);
    }

    for (submodules) |sub| {
        if (sub.url.len == 0) {
            reportSkippedNoUrl(diag, gpa, sub.name);
            continue;
        }

        try validateSubmodulePath(sub.path);

        const gitlink_oid = (try findGitlinkOid(gpa, &repo.odb, repo.format, tree_oid, sub.path, diag)) orelse {
            reportSkippedNoGitlink(diag, gpa, sub.path);
            continue;
        };

        // Resolve relative URLs against the parent's remote URL.
        var resolved_url: ?[]u8 = null;
        defer if (resolved_url) |u| gpa.free(u);

        const fetch_url = if (isRelativeSubmoduleUrl(sub.url)) blk: {
            if (options.parent_remote_url == null) return error.RelativeUrlWithoutParentRemote;
            resolved_url = try resolveRelativeSubmoduleUrl(gpa, options.parent_remote_url.?, sub.url);
            break :blk resolved_url.?;
        } else sub.url;

        var sub_dir = try openSubmoduleWorktreeDir(gpa, io, worktree, sub.path, diag);
        defer sub_dir.close(io);

        var sub_repo = try openOrInitSubmoduleRepo(gpa, io, sub_dir, diag);
        defer sub_repo.deinit();

        var result = try fetch_mod.fetch(gpa, io, &sub_repo, fetch_url, options.fetch, diag);
        defer result.deinit(gpa);

        if (!(try sub_repo.odb.exists(gitlink_oid))) return error.RefNotFound;

        const sub_tree_oid = try readCommitTree(gpa, &sub_repo.odb, sub_repo.format, gitlink_oid, diag);

        try checkout_mod.checkoutTree(gpa, io, &sub_repo.odb, sub_dir, sub_dir, sub_tree_oid, options.strategy, diag);

        if (options.recursive) {
            try updateAtDepth(gpa, io, &sub_repo, sub_dir, sub_tree_oid, options, diag, depth + 1);
        }
    }
}

/// The tree `repo`'s `HEAD` commit records, or null when `repo` has no
/// commit yet (a freshly initialized repository, not a fault).
fn headTree(gpa: Allocator, repo: *Repository, diag: ?*?Diagnostic) Error!?Oid {
    const head_oid = repo.head(diag) catch |err| switch (err) {
        error.RefNotFound => return null,
        else => return err,
    };
    return try readCommitTree(gpa, &repo.odb, repo.format, head_oid, diag);
}

/// Reads `oid` as a commit and returns its tree. Bounded, like
/// `ziggit-checkout`'s own small-object reads: a hostile or corrupt
/// commit past `max_commit_object_len`, or an object that is not really
/// a commit at all, is `error.CorruptObject`, never trusted.
fn readCommitTree(gpa: Allocator, odb: *Odb, format: Format, oid: Oid, diag: ?*?Diagnostic) Error!Oid {
    const bytes = try readObjectAlloc(gpa, odb, oid, .commit, max_commit_object_len, diag);
    defer gpa.free(bytes);
    var commit = Commit.parse(gpa, format, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CorruptCommit => return error.CorruptObject,
    };
    defer commit.deinit(gpa);
    return commit.tree;
}

/// Reads `repo`'s `.gitmodules` blob out of the tree at `tree_oid`, or
/// null when the tree has no such entry at all -- an ordinary repository
/// with no submodules, not a fault.
fn readGitmodulesBlob(gpa: Allocator, repo: *Repository, tree_oid: Oid, diag: ?*?Diagnostic) Error!?[]u8 {
    return readObjectAllocOpt(gpa, &repo.odb, repo.format, tree_oid, ".gitmodules", diag);
}

/// Looks up the entry named `leaf` in the tree at `tree_oid`, reads it
/// as a blob, and returns its bytes, or null when the tree has no such
/// entry. A defensive helper shared by `readGitmodulesBlob` today; kept
/// general rather than hard-coding `.gitmodules` twice.
fn readObjectAllocOpt(gpa: Allocator, odb: *Odb, format: Format, tree_oid: Oid, leaf: []const u8, diag: ?*?Diagnostic) Error!?[]u8 {
    const bytes = try readObjectAlloc(gpa, odb, tree_oid, .tree, max_tree_object_len, diag);
    defer gpa.free(bytes);
    var tree = Tree.parse(gpa, format, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CorruptTree => return error.CorruptObject,
    };
    defer tree.deinit(gpa);

    const entry = tree.find(leaf) orelse return null;
    if (entry.mode.isTree() or entry.mode.isGitlink()) return null;
    return try readObjectAlloc(gpa, odb, entry.oid, .blob, max_gitmodules_len, diag);
}

const KindTag = enum { blob, tree, commit };

/// Reads `oid` into a fresh, bounded allocation, refusing anything over
/// `max_size` and anything whose real object kind is not `want`. Mirrors
/// `Odb.readAlloc`'s own bound-then-read shape, but keeps the
/// `ObjectKind` `readAlloc` itself discards: every object this module
/// reads came from a repository someone else wrote, so trusting its
/// claimed shape without checking is not an option.
fn readObjectAlloc(gpa: Allocator, odb: *Odb, oid: Oid, want: KindTag, max_size: usize, diag: ?*?Diagnostic) Error![]u8 {
    const buf = try gpa.alloc(u8, max_size);
    var w: std.Io.Writer = .fixed(buf);
    if (odb.read(oid, &w, diag)) |kind| {
        const matches = switch (want) {
            .blob => kind == .blob,
            .tree => kind == .tree,
            .commit => kind == .commit,
        };
        if (!matches) {
            gpa.free(buf);
            return error.CorruptObject;
        }
        const written = w.buffered().len;
        return gpa.realloc(buf, written);
    } else |err| {
        gpa.free(buf);
        const info = odb.stat(oid) catch |stat_err| return stat_err;
        if (info.size > max_size) return error.ObjectTooLarge;
        return err;
    }
}

/// The tree oid a path resolves to, walking down from `start` one
/// component at a time, or null when any component along the way is
/// missing or is not itself a tree. `subpath` null or empty returns
/// `start` unchanged.
fn resolveTreeAtPath(gpa: Allocator, odb: *Odb, format: Format, start: Oid, subpath: ?[]const u8, diag: ?*?Diagnostic) Error!?Oid {
    const sp = subpath orelse return start;
    if (sp.len == 0) return start;

    var current = start;
    var it = std.mem.splitScalar(u8, sp, '/');
    while (it.next()) |component| {
        const bytes = try readObjectAlloc(gpa, odb, current, .tree, max_tree_object_len, diag);
        defer gpa.free(bytes);
        var tree = Tree.parse(gpa, format, bytes) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CorruptTree => return error.CorruptObject,
        };
        defer tree.deinit(gpa);

        const entry = tree.find(component) orelse return null;
        if (!entry.mode.isTree()) return null;
        current = entry.oid;
    }
    return current;
}

/// The gitlink oid a submodule's `path` names in the tree at
/// `root_tree`, or null when the path is not there at all, or is there
/// but is not a gitlink. `path` is assumed already validated by
/// `validateSubmodulePath`.
fn findGitlinkOid(gpa: Allocator, odb: *Odb, format: Format, root_tree: Oid, path: []const u8, diag: ?*?Diagnostic) Error!?Oid {
    const last_slash = std.mem.lastIndexOfScalar(u8, path, '/');
    const parent: ?[]const u8 = if (last_slash) |i| path[0..i] else null;
    const leaf = if (last_slash) |i| path[i + 1 ..] else path;

    const parent_tree_oid = (try resolveTreeAtPath(gpa, odb, format, root_tree, parent, diag)) orelse return null;

    const bytes = try readObjectAlloc(gpa, odb, parent_tree_oid, .tree, max_tree_object_len, diag);
    defer gpa.free(bytes);
    var tree = Tree.parse(gpa, format, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CorruptTree => return error.CorruptObject,
    };
    defer tree.deinit(gpa);

    const entry = tree.find(leaf) orelse return null;
    if (!entry.mode.isGitlink()) return null;
    return entry.oid;
}

/// A path is absolute if it starts with the POSIX root separator `/`, or
/// with a drive letter such as `C:` in the Windows style. Matches
/// `ziggit-checkout`'s own check.
fn isAbsolutePath(path: []const u8) bool {
    if (path.len > 0 and path[0] == '/') return true;
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') return true;
    return false;
}

/// Validates a submodule's `path`, a relative path with separators,
/// legitimately, unlike a tree entry name. Rejects, by walking its
/// decomposed components rather than searching the string as a whole:
/// an empty path, an absolute path, a path beginning with a separator
/// (an empty leading component already catches this), any component
/// that is `.` or `..`, and any component carrying a `\`.
fn validateSubmodulePath(path: []const u8) Error!void {
    if (path.len == 0) return error.InvalidSubmodulePath;
    if (isAbsolutePath(path)) return error.InvalidSubmodulePath;

    var saw_component = false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        saw_component = true;
        if (component.len == 0) return error.InvalidSubmodulePath;
        if (std.mem.eql(u8, component, ".")) return error.InvalidSubmodulePath;
        if (std.mem.eql(u8, component, "..")) return error.InvalidSubmodulePath;
        if (std.mem.indexOfScalar(u8, component, '\\') != null) return error.InvalidSubmodulePath;
    }
    if (!saw_component) return error.InvalidSubmodulePath;
}

/// A relative url in git's own submodule sense: one resolved against the
/// parent's own remote url, spelled `./…` or `../…`.
fn isRelativeSubmoduleUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "./") or std.mem.startsWith(u8, url, "../");
}

/// Resolves a relative submodule url against the parent's remote url.
/// Returns the resolved url, which the caller must free. The parent
/// remote url must be an absolute url; a relative url with no parent url
/// available is caught earlier and returns
/// `error.RelativeUrlWithoutParentRemote`.
///
/// Git treats the parent's own url as a stack of path segments and walks
/// it one relative segment at a time: a `..` segment pops the last one
/// off, a `.` segment leaves the stack alone, and any other segment is
/// pushed on. The parent's own last segment is popped only by an
/// explicit `..`, so `./name.git` pushes `name.git` on top of the whole
/// parent url, while `../name.git` first pops the parent's own last
/// segment and replaces it:
/// - `../name.git` against `https://host/group/parent.git` yields
///   `https://host/group/name.git`
/// - `./name.git` against `https://host/group/parent.git` yields
///   `https://host/group/parent.git/name.git`
///
/// If a `..` segment would pop past the start of the url, this returns
/// `error.RelativeUrlEscapesRoot` rather than emitting a malformed url:
/// real git resolves such a url into a malformed one
/// (`https:/evil.git`) and only fails once it tries to connect.
fn resolveRelativeSubmoduleUrl(gpa: Allocator, parent_url: []const u8, relative_url: []const u8) Error![]u8 {
    // A local file path carries no scheme.
    if (parent_url.len > 0 and parent_url[0] == '/') {
        var path_components: std.ArrayList([]const u8) = .empty;
        defer path_components.deinit(gpa);

        var parent_it = std.mem.splitScalar(u8, parent_url[1..], '/');
        while (parent_it.next()) |component| {
            if (component.len > 0) try path_components.append(gpa, component);
        }

        try applyRelativeSegments(gpa, &path_components, relative_url);

        var result_buf: std.ArrayList(u8) = .empty;
        defer result_buf.deinit(gpa);
        try result_buf.appendSlice(gpa, "/");
        for (path_components.items, 0..) |comp, i| {
            if (i > 0) try result_buf.appendSlice(gpa, "/");
            try result_buf.appendSlice(gpa, comp);
        }

        return try gpa.dupe(u8, result_buf.items);
    }

    // A remote url: scheme, host, then an optional path.
    const scheme_end = std.mem.indexOf(u8, parent_url, "://") orelse return error.InvalidSubmodulePath;
    const scheme = parent_url[0..scheme_end];
    const after_scheme = parent_url[scheme_end + 3 ..];

    const path_start = std.mem.indexOf(u8, after_scheme, "/");
    const host = if (path_start) |i| after_scheme[0..i] else after_scheme;
    const parent_path = if (path_start) |i| after_scheme[i + 1 ..] else "";

    var path_components: std.ArrayList([]const u8) = .empty;
    defer path_components.deinit(gpa);

    var path_it = std.mem.splitScalar(u8, parent_path, '/');
    while (path_it.next()) |component| {
        if (component.len > 0) try path_components.append(gpa, component);
    }

    try applyRelativeSegments(gpa, &path_components, relative_url);

    var path_buf: std.ArrayList(u8) = .empty;
    defer path_buf.deinit(gpa);
    for (path_components.items) |comp| {
        try path_buf.appendSlice(gpa, "/");
        try path_buf.appendSlice(gpa, comp);
    }

    return std.fmt.allocPrint(gpa, "{s}://{s}{s}", .{ scheme, host, path_buf.items });
}

/// Applies each `/`-separated segment of `relative_url` to `components`
/// in place: a `..` segment pops the last entry off (or returns
/// `error.RelativeUrlEscapesRoot` when `components` is already empty), a
/// `.` segment is skipped, and any other segment is pushed on. Shared by
/// both branches of `resolveRelativeSubmoduleUrl`, which differ only in
/// how the starting stack and the final result are built. `relative_url`
/// is assumed already known to start with `./` or `../`, via
/// `isRelativeSubmoduleUrl`, so its first segment is always `.` or `..`.
fn applyRelativeSegments(gpa: Allocator, components: *std.ArrayList([]const u8), relative_url: []const u8) Error!void {
    var it = std.mem.splitScalar(u8, relative_url, '/');
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        if (std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (components.items.len == 0) return error.RelativeUrlEscapesRoot;
            components.items.len -= 1;
        } else {
            try components.append(gpa, segment);
        }
    }
}

/// Opens `worktree/path`, creating any missing directory component along
/// the way, refusing with `error.InvalidSubmodulePath` the moment any
/// component -- an intermediate directory or the submodule's own
/// directory itself -- already exists as a symlink. `path` is assumed
/// already validated: no `..`, no absolute path, no empty component.
///
/// A symlink here could point anywhere, including outside `worktree`;
/// resolving it and continuing would let a submodule's own gitlink
/// checkout land outside the repository entirely, the same class of
/// escape `ziggit-checkout` refuses for a tree entry name. Checking each
/// component against the live filesystem, rather than trusting a path
/// built from already-open directory handles, is what
/// `ziggit-checkout`'s own doc comment names as a thing it does not
/// solve for a symlink a tree write leaves behind; this does solve it,
/// for a submodule path, since nothing else stands between a hostile
/// `.gitmodules` and a filesystem write here.
fn openSubmoduleWorktreeDir(gpa: Allocator, io: std.Io, worktree: std.Io.Dir, path: []const u8, diag: ?*?Diagnostic) Error!std.Io.Dir {
    var current: std.Io.Dir = worktree;
    var owns_current = false;
    errdefer if (owns_current) current.close(io);

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |component| {
        const existing = current.statFile(io, component, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => null,
            else => {
                reportStatFailure(diag, gpa, path, err);
                return error.IoFailed;
            },
        };
        if (existing) |st| {
            if (st.kind == .sym_link) return error.InvalidSubmodulePath;
        } else {
            current.createDir(io, component, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => {
                    reportCreateDirFailure(diag, gpa, path, err);
                    return error.IoFailed;
                },
            };
        }

        const next = current.openDir(io, component, .{ .iterate = true }) catch |err| {
            reportOpenDirFailure(diag, gpa, path, err);
            return error.IoFailed;
        };
        if (owns_current) current.close(io);
        current = next;
        owns_current = true;
    }

    return current;
}

/// Opens the git repository already at `dir`, or bootstraps a minimal
/// one there first when `dir` carries no `.git` yet. Always builds the
/// `.git` layout itself rather than letting `ziggit-repo.discover` walk
/// upward from `dir`: `dir` is freshly created scaffolding the moment a
/// submodule is first fetched, so an upward walk would otherwise resolve
/// straight through it to the parent repository's own `.git`.
fn openOrInitSubmoduleRepo(gpa: Allocator, io: std.Io, dir: std.Io.Dir, diag: ?*?Diagnostic) Error!Repository {
    const has_git = blk: {
        _ = dir.statFile(io, ".git", .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => {
                reportStatFailure(diag, gpa, ".git", err);
                return error.IoFailed;
            },
        };
        break :blk true;
    };
    if (!has_git) {
        dir.createDirPath(io, ".git/objects/pack") catch return error.IoFailed;
        dir.createDirPath(io, ".git/refs/heads") catch return error.IoFailed;
        dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" }) catch return error.IoFailed;
    }

    var layout = try repo_mod.discover(gpa, io, dir, .{}, diag);
    errdefer layout.deinit(io);
    return try Repository.open(gpa, io, layout, .{}, diag);
}

/// Reports, through `diag` when the caller asked for detail, that
/// `name`'s `.gitmodules` entry carried no `url` and was skipped rather
/// than treated as fatal: git tolerates an incomplete entry, and a
/// caller who wants to know which submodule was skipped reads `diag`.
fn reportSkippedNoUrl(diag: ?*?Diagnostic, gpa: Allocator, name: []const u8) void {
    if (!core_mod.wants(diag)) return;
    const path_dup = gpa.dupe(u8, name) catch null;
    const detail_dup = gpa.dupe(u8, "submodule has no url; skipped") catch null;
    core_mod.report(diag, gpa, .{ .kind = .corrupt_config, .path = path_dup, .detail = detail_dup });
}

/// Reports, through `diag` when the caller asked for detail, that `path`
/// named no gitlink in the parent's own tree and was skipped rather than
/// treated as fatal: git tolerates a `.gitmodules` entry naming a path the
/// tree does not carry as a gitlink, and a caller who wants to know which
/// path was ignored reads `diag`.
fn reportSkippedNoGitlink(diag: ?*?Diagnostic, gpa: Allocator, path: []const u8) void {
    if (!core_mod.wants(diag)) return;
    const path_dup = gpa.dupe(u8, path) catch null;
    const detail_dup = gpa.dupe(u8, "no matching gitlink in tree; skipped") catch null;
    core_mod.report(diag, gpa, .{ .kind = .corrupt_config, .path = path_dup, .detail = detail_dup });
}

/// Reports, through `diag` when the caller asked for detail, that
/// stat-ing `path` (or a component of it) failed for a reason other than
/// plain absence. `err` names the real cause; a caller that only sees
/// `error.IoFailed` would otherwise have nothing to go on.
fn reportStatFailure(diag: ?*?Diagnostic, gpa: Allocator, path: []const u8, err: std.Io.Dir.StatFileError) void {
    if (!core_mod.wants(diag)) return;
    const path_dup = gpa.dupe(u8, path) catch null;
    const detail_dup = std.fmt.allocPrint(gpa, "could not stat: {s}", .{@errorName(err)}) catch null;
    core_mod.report(diag, gpa, .{ .kind = .io, .path = path_dup, .detail = detail_dup });
}

/// Reports, through `diag` when the caller asked for detail, that
/// creating the directory at `path` failed for a reason other than it
/// already existing. `err` names the real cause.
fn reportCreateDirFailure(diag: ?*?Diagnostic, gpa: Allocator, path: []const u8, err: std.Io.Dir.CreateDirError) void {
    if (!core_mod.wants(diag)) return;
    const path_dup = gpa.dupe(u8, path) catch null;
    const detail_dup = std.fmt.allocPrint(gpa, "could not create directory: {s}", .{@errorName(err)}) catch null;
    core_mod.report(diag, gpa, .{ .kind = .io, .path = path_dup, .detail = detail_dup });
}

/// Reports, through `diag` when the caller asked for detail, that opening
/// the directory at `path` failed. `err` names the real cause.
fn reportOpenDirFailure(diag: ?*?Diagnostic, gpa: Allocator, path: []const u8, err: std.Io.Dir.OpenError) void {
    if (!core_mod.wants(diag)) return;
    const path_dup = gpa.dupe(u8, path) catch null;
    const detail_dup = std.fmt.allocPrint(gpa, "could not open directory: {s}", .{@errorName(err)}) catch null;
    core_mod.report(diag, gpa, .{ .kind = .io, .path = path_dup, .detail = detail_dup });
}

// Test helpers shared by every test below.

const testing = std.testing;

const identity_line = "A U Thor <author@example.com> 1700000000 +0000";
const test_committer: core_mod.Committer = .{ .name = "A U Thor", .email = "author@example.com" };

fn buildMinimalRepoDir(io: std.Io, dir: std.Io.Dir) !void {
    try dir.createDirPath(io, "objects/pack");
    try dir.createDirPath(io, "refs/heads");
    try dir.writeFile(io, .{ .sub_path = "HEAD", .data = "ref: refs/heads/main\n" });
}

fn openTestRepo(gpa: Allocator, io: std.Io, dir: std.Io.Dir) !Repository {
    try buildMinimalRepoDir(io, dir);
    const layout = try repo_mod.discover(gpa, io, dir, .{}, null);
    return Repository.open(gpa, io, layout, .{ .committer = test_committer }, null);
}

fn realPathOf(gpa: Allocator, io: std.Io, dir: std.Io.Dir) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try dir.realPath(io, &buf);
    return gpa.dupe(u8, buf[0..len]);
}

fn writeBlob(odb: *Odb, data: []const u8) !Oid {
    return odb.write(.blob, data, null);
}

fn writeTreeSorted(gpa: Allocator, odb: *Odb, entries: []Tree.Entry) !Oid {
    Tree.sortEntries(entries);
    var aw = try std.Io.Writer.Allocating.initCapacity(gpa, 256);
    defer aw.deinit();
    const t: Tree = .{ .entries = entries };
    try t.write(&aw.writer);
    return odb.write(.tree, aw.writer.buffered(), null);
}

fn writeCommit(gpa: Allocator, odb: *Odb, tree_oid: Oid, parent_hex: ?[]const u8, message: []const u8) !Oid {
    var tree_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const tree_hex = tree_oid.toHex(&tree_hex_buf);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.print("tree {s}\n", .{tree_hex});
    if (parent_hex) |p| try out.writer.print("parent {s}\n", .{p});
    try out.writer.print("author {s}\n", .{identity_line});
    try out.writer.print("committer {s}\n", .{identity_line});
    try out.writer.print("\n{s}\n", .{message});
    return odb.write(.commit, out.writer.buffered(), null);
}

fn gitmodulesText(gpa: Allocator, name: []const u8, path: []const u8, url: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "[submodule \"{s}\"]\n\tpath = {s}\n\turl = {s}\n", .{ name, path, url });
}

fn updateRef(dir: std.Io.Dir, io: std.Io, oid: Oid) !void {
    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const line = try std.fmt.allocPrint(std.testing.allocator, "{s}\n", .{oid.toHex(&hex_buf)});
    defer std.testing.allocator.free(line);
    try dir.writeFile(io, .{ .sub_path = "refs/heads/main", .data = line });
}

/// Builds the one default refspec into `storage`, owned by the caller
/// (ordinarily a single test's own stack), and returns fetch options
/// using it. A local array per test, rather than a shared package-level
/// `var`, since this project bans package-level mutable state even when
/// confined to test fixtures.
fn defaultFetchOptions(gpa: Allocator, storage: *[1]fetch_mod.Refspec) fetch_mod.FetchOptions {
    storage[0] = fetch_mod.Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*") catch unreachable;
    return .{ .refspecs = storage[0..1] };
}

// expected

test "updateAll fetches a submodule and checks it out at its gitlink oid" {
    var refspecs_storage: [1]fetch_mod.Refspec = undefined;
    const gpa = testing.allocator;
    const io = testing.io;

    // The submodule's own source repository: two commits, so that
    // checking out the *older* one (the one the parent's gitlink names)
    // rather than the ref tip is a real, distinguishing assertion.
    var sub_tmp = testing.tmpDir(.{ .iterate = true });
    defer sub_tmp.cleanup();
    var sub_source = try openTestRepo(gpa, io, sub_tmp.dir);
    defer sub_source.deinit();

    const v1_blob = try writeBlob(&sub_source.odb, "v1\n");
    var v1_entries = [_]Tree.Entry{.{ .mode = .blob, .name = "marker.txt", .oid = v1_blob }};
    const v1_tree = try writeTreeSorted(gpa, &sub_source.odb, &v1_entries);
    const v1_commit = try writeCommit(gpa, &sub_source.odb, v1_tree, null, "v1");

    var v1_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const v1_hex = v1_commit.toHex(&v1_hex_buf);
    const v2_blob = try writeBlob(&sub_source.odb, "v2\n");
    var v2_entries = [_]Tree.Entry{.{ .mode = .blob, .name = "marker.txt", .oid = v2_blob }};
    const v2_tree = try writeTreeSorted(gpa, &sub_source.odb, &v2_entries);
    const v2_commit = try writeCommit(gpa, &sub_source.odb, v2_tree, v1_hex, "v2");
    try updateRef(sub_tmp.dir, io, v2_commit);

    const sub_url = try realPathOf(gpa, io, sub_tmp.dir);
    defer gpa.free(sub_url);

    // The parent repository: one commit whose tree names ".gitmodules"
    // and a gitlink for "lib" pinned at the *first* submodule commit.
    var root_tmp = testing.tmpDir(.{ .iterate = true });
    defer root_tmp.cleanup();
    var root = try openTestRepo(gpa, io, root_tmp.dir);
    defer root.deinit();

    const gm_text = try gitmodulesText(gpa, "lib", "lib", sub_url);
    defer gpa.free(gm_text);
    const gm_blob = try writeBlob(&root.odb, gm_text);
    var root_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitmodules", .oid = gm_blob },
        .{ .mode = .gitlink, .name = "lib", .oid = v1_commit },
    };
    const root_tree = try writeTreeSorted(gpa, &root.odb, &root_entries);
    const root_commit = try writeCommit(gpa, &root.odb, root_tree, null, "root");
    try updateRef(root_tmp.dir, io, root_commit);

    var worktree_tmp = testing.tmpDir(.{ .iterate = true });
    defer worktree_tmp.cleanup();

    try updateAll(gpa, io, &root, worktree_tmp.dir, .{ .fetch = defaultFetchOptions(gpa, &refspecs_storage) }, null);

    var lib_dir = try worktree_tmp.dir.openDir(io, "lib", .{ .iterate = true });
    defer lib_dir.close(io);
    const content = try lib_dir.readFileAlloc(io, "marker.txt", gpa, .limited(64));
    defer gpa.free(content);
    try testing.expectEqualStrings("v1\n", content);
    for (&refspecs_storage) |*r| r.deinit(gpa);
}

test "updateAll recurses into a submodule that has its own submodule" {
    var refspecs_storage: [1]fetch_mod.Refspec = undefined;
    const gpa = testing.allocator;
    const io = testing.io;

    // Grandchild: one commit, one marker file.
    var gc_tmp = testing.tmpDir(.{ .iterate = true });
    defer gc_tmp.cleanup();
    var gc = try openTestRepo(gpa, io, gc_tmp.dir);
    defer gc.deinit();
    const gc_blob = try writeBlob(&gc.odb, "leaf\n");
    var gc_entries = [_]Tree.Entry{.{ .mode = .blob, .name = "leaf.txt", .oid = gc_blob }};
    const gc_tree = try writeTreeSorted(gpa, &gc.odb, &gc_entries);
    const gc_commit = try writeCommit(gpa, &gc.odb, gc_tree, null, "grandchild");
    try updateRef(gc_tmp.dir, io, gc_commit);
    const gc_url = try realPathOf(gpa, io, gc_tmp.dir);
    defer gpa.free(gc_url);

    // Child: one commit, a gitmodules naming the grandchild, a gitlink
    // for it.
    var c_tmp = testing.tmpDir(.{ .iterate = true });
    defer c_tmp.cleanup();
    var c = try openTestRepo(gpa, io, c_tmp.dir);
    defer c.deinit();
    const c_gm = try gitmodulesText(gpa, "grandchild", "grandchild", gc_url);
    defer gpa.free(c_gm);
    const c_gm_blob = try writeBlob(&c.odb, c_gm);
    var c_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitmodules", .oid = c_gm_blob },
        .{ .mode = .gitlink, .name = "grandchild", .oid = gc_commit },
    };
    const c_tree = try writeTreeSorted(gpa, &c.odb, &c_entries);
    const c_commit = try writeCommit(gpa, &c.odb, c_tree, null, "child");
    try updateRef(c_tmp.dir, io, c_commit);
    const c_url = try realPathOf(gpa, io, c_tmp.dir);
    defer gpa.free(c_url);

    // Root: one commit, a gitmodules naming the child, a gitlink for it.
    var root_tmp = testing.tmpDir(.{ .iterate = true });
    defer root_tmp.cleanup();
    var root = try openTestRepo(gpa, io, root_tmp.dir);
    defer root.deinit();
    const root_gm = try gitmodulesText(gpa, "child", "child", c_url);
    defer gpa.free(root_gm);
    const root_gm_blob = try writeBlob(&root.odb, root_gm);
    var root_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitmodules", .oid = root_gm_blob },
        .{ .mode = .gitlink, .name = "child", .oid = c_commit },
    };
    const root_tree = try writeTreeSorted(gpa, &root.odb, &root_entries);
    const root_commit = try writeCommit(gpa, &root.odb, root_tree, null, "root");
    try updateRef(root_tmp.dir, io, root_commit);

    var worktree_tmp = testing.tmpDir(.{ .iterate = true });
    defer worktree_tmp.cleanup();

    try updateAll(gpa, io, &root, worktree_tmp.dir, .{ .recursive = true, .fetch = defaultFetchOptions(gpa, &refspecs_storage) }, null);

    var grandchild_dir = try worktree_tmp.dir.openDir(io, "child/grandchild", .{ .iterate = true });
    defer grandchild_dir.close(io);
    const content = try grandchild_dir.readFileAlloc(io, "leaf.txt", gpa, .limited(64));
    defer gpa.free(content);
    try testing.expectEqualStrings("leaf\n", content);
    for (&refspecs_storage) |*r| r.deinit(gpa);
}

test "recursive false checks out the top level and does not recurse" {
    var refspecs_storage: [1]fetch_mod.Refspec = undefined;
    const gpa = testing.allocator;
    const io = testing.io;

    var gc_tmp = testing.tmpDir(.{ .iterate = true });
    defer gc_tmp.cleanup();
    var gc = try openTestRepo(gpa, io, gc_tmp.dir);
    defer gc.deinit();
    const gc_blob = try writeBlob(&gc.odb, "leaf\n");
    var gc_entries = [_]Tree.Entry{.{ .mode = .blob, .name = "leaf.txt", .oid = gc_blob }};
    const gc_tree = try writeTreeSorted(gpa, &gc.odb, &gc_entries);
    const gc_commit = try writeCommit(gpa, &gc.odb, gc_tree, null, "grandchild");
    try updateRef(gc_tmp.dir, io, gc_commit);
    const gc_url = try realPathOf(gpa, io, gc_tmp.dir);
    defer gpa.free(gc_url);

    var c_tmp = testing.tmpDir(.{ .iterate = true });
    defer c_tmp.cleanup();
    var c = try openTestRepo(gpa, io, c_tmp.dir);
    defer c.deinit();
    const c_gm = try gitmodulesText(gpa, "grandchild", "grandchild", gc_url);
    defer gpa.free(c_gm);
    const c_gm_blob = try writeBlob(&c.odb, c_gm);
    var c_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitmodules", .oid = c_gm_blob },
        .{ .mode = .gitlink, .name = "grandchild", .oid = gc_commit },
    };
    const c_tree = try writeTreeSorted(gpa, &c.odb, &c_entries);
    const c_commit = try writeCommit(gpa, &c.odb, c_tree, null, "child");
    try updateRef(c_tmp.dir, io, c_commit);
    const c_url = try realPathOf(gpa, io, c_tmp.dir);
    defer gpa.free(c_url);

    var root_tmp = testing.tmpDir(.{ .iterate = true });
    defer root_tmp.cleanup();
    var root = try openTestRepo(gpa, io, root_tmp.dir);
    defer root.deinit();
    const root_gm = try gitmodulesText(gpa, "child", "child", c_url);
    defer gpa.free(root_gm);
    const root_gm_blob = try writeBlob(&root.odb, root_gm);
    var root_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitmodules", .oid = root_gm_blob },
        .{ .mode = .gitlink, .name = "child", .oid = c_commit },
    };
    const root_tree = try writeTreeSorted(gpa, &root.odb, &root_entries);
    const root_commit = try writeCommit(gpa, &root.odb, root_tree, null, "root");
    try updateRef(root_tmp.dir, io, root_commit);

    var worktree_tmp = testing.tmpDir(.{ .iterate = true });
    defer worktree_tmp.cleanup();

    try updateAll(gpa, io, &root, worktree_tmp.dir, .{ .recursive = false, .fetch = defaultFetchOptions(gpa, &refspecs_storage) }, null);

    // The top level's own submodule was fetched and checked out.
    var child_dir = try worktree_tmp.dir.openDir(io, "child", .{ .iterate = true });
    defer child_dir.close(io);
    _ = try child_dir.statFile(io, ".gitmodules", .{});

    // Its own submodule was left untouched: `checkoutTree`'s gitlink
    // handling still creates the empty placeholder directory, but no
    // fetch or checkout ever ran inside it.
    var grandchild_dir = try child_dir.openDir(io, "grandchild", .{ .iterate = true });
    defer grandchild_dir.close(io);
    try testing.expectError(error.FileNotFound, grandchild_dir.statFile(io, "leaf.txt", .{}));
    for (&refspecs_storage) |*r| r.deinit(gpa);
}

// suspicious

test "a submodule path containing .. is InvalidSubmodulePath" {
    var refspecs_storage: [1]fetch_mod.Refspec = undefined;
    const gpa = testing.allocator;
    const io = testing.io;

    var root_tmp = testing.tmpDir(.{ .iterate = true });
    defer root_tmp.cleanup();
    var root = try openTestRepo(gpa, io, root_tmp.dir);
    defer root.deinit();

    const gm_text = try gitmodulesText(gpa, "evil", "a/../../b", "https://example.com/evil.git");
    defer gpa.free(gm_text);
    const gm_blob = try writeBlob(&root.odb, gm_text);
    var root_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitmodules", .oid = gm_blob },
    };
    const root_tree = try writeTreeSorted(gpa, &root.odb, &root_entries);
    const root_commit = try writeCommit(gpa, &root.odb, root_tree, null, "root");
    try updateRef(root_tmp.dir, io, root_commit);

    var worktree_tmp = testing.tmpDir(.{ .iterate = true });
    defer worktree_tmp.cleanup();

    try testing.expectError(
        error.InvalidSubmodulePath,
        updateAll(gpa, io, &root, worktree_tmp.dir, .{ .fetch = defaultFetchOptions(gpa, &refspecs_storage) }, null),
    );
    for (&refspecs_storage) |*r| r.deinit(gpa);
}

test "an absolute submodule path is InvalidSubmodulePath" {
    var refspecs_storage: [1]fetch_mod.Refspec = undefined;
    const gpa = testing.allocator;
    const io = testing.io;

    var root_tmp = testing.tmpDir(.{ .iterate = true });
    defer root_tmp.cleanup();
    var root = try openTestRepo(gpa, io, root_tmp.dir);
    defer root.deinit();

    const gm_text = try gitmodulesText(gpa, "evil", "/etc/passwd", "https://example.com/evil.git");
    defer gpa.free(gm_text);
    const gm_blob = try writeBlob(&root.odb, gm_text);
    var root_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitmodules", .oid = gm_blob },
    };
    const root_tree = try writeTreeSorted(gpa, &root.odb, &root_entries);
    const root_commit = try writeCommit(gpa, &root.odb, root_tree, null, "root");
    try updateRef(root_tmp.dir, io, root_commit);

    var worktree_tmp = testing.tmpDir(.{ .iterate = true });
    defer worktree_tmp.cleanup();

    try testing.expectError(
        error.InvalidSubmodulePath,
        updateAll(gpa, io, &root, worktree_tmp.dir, .{ .fetch = defaultFetchOptions(gpa, &refspecs_storage) }, null),
    );
    for (&refspecs_storage) |*r| r.deinit(gpa);
}

test "a submodule path that is a symlink out of the worktree is refused" {
    var refspecs_storage: [1]fetch_mod.Refspec = undefined;
    const gpa = testing.allocator;
    const io = testing.io;

    var root_tmp = testing.tmpDir(.{ .iterate = true });
    defer root_tmp.cleanup();
    var root = try openTestRepo(gpa, io, root_tmp.dir);
    defer root.deinit();

    const bogus_oid = try Oid.parse(.sha1, "cccccccccccccccccccccccccccccccccccccccc");
    const gm_text = try gitmodulesText(gpa, "evil", "evil", "https://example.com/evil.git");
    defer gpa.free(gm_text);
    const gm_blob = try writeBlob(&root.odb, gm_text);
    var root_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitmodules", .oid = gm_blob },
        .{ .mode = .gitlink, .name = "evil", .oid = bogus_oid },
    };
    const root_tree = try writeTreeSorted(gpa, &root.odb, &root_entries);
    const root_commit = try writeCommit(gpa, &root.odb, root_tree, null, "root");
    try updateRef(root_tmp.dir, io, root_commit);

    var worktree_tmp = testing.tmpDir(.{ .iterate = true });
    defer worktree_tmp.cleanup();

    // A pre-existing symlink at the submodule's own path, pointing
    // somewhere else entirely.
    var outside_tmp = testing.tmpDir(.{});
    defer outside_tmp.cleanup();
    const outside_path = try realPathOf(gpa, io, outside_tmp.dir);
    defer gpa.free(outside_path);
    try worktree_tmp.dir.symLink(io, outside_path, "evil", .{});

    try testing.expectError(
        error.InvalidSubmodulePath,
        updateAll(gpa, io, &root, worktree_tmp.dir, .{ .fetch = defaultFetchOptions(gpa, &refspecs_storage) }, null),
    );
    for (&refspecs_storage) |*r| r.deinit(gpa);
}

test "nesting deeper than max_depth is SubmoduleTooDeep rather than unbounded" {
    var refspecs_storage: [1]fetch_mod.Refspec = undefined;
    const gpa = testing.allocator;
    const io = testing.io;

    // A chain of `max_depth + 2` repositories, each naming the next as
    // its one submodule, built leaf first so each parent already knows
    // its child's commit oid and on-disk url.
    const chain_len = max_depth + 2;
    var dirs: [chain_len]std.testing.TmpDir = undefined;
    var idx: usize = 0;
    while (idx < chain_len) : (idx += 1) dirs[idx] = testing.tmpDir(.{ .iterate = true });
    defer for (&dirs) |*d| d.cleanup();

    var child_oid: ?Oid = null;
    var child_url: ?[]u8 = null;
    defer if (child_url) |u| gpa.free(u);

    var level: usize = chain_len;
    while (level > 0) {
        level -= 1;
        var r = try openTestRepo(gpa, io, dirs[level].dir);
        defer r.deinit();

        var entries_buf: [2]Tree.Entry = undefined;
        var n: usize = 0;
        const marker_blob = try writeBlob(&r.odb, "level\n");
        entries_buf[n] = .{ .mode = .blob, .name = "marker.txt", .oid = marker_blob };
        n += 1;

        var gm_text_opt: ?[]u8 = null;
        defer if (gm_text_opt) |t| gpa.free(t);
        if (child_oid) |coid| {
            gm_text_opt = try gitmodulesText(gpa, "next", "next", child_url.?);
            const gm_blob = try writeBlob(&r.odb, gm_text_opt.?);
            entries_buf[n] = .{ .mode = .blob, .name = ".gitmodules", .oid = gm_blob };
            n += 1;
            // `.gitmodules` must sort with the gitlink; grow to fit
            // three entries when both are present.
            var full_entries = [_]Tree.Entry{
                entries_buf[0],
                entries_buf[1],
                .{ .mode = .gitlink, .name = "next", .oid = coid },
            };
            const tree_oid = try writeTreeSorted(gpa, &r.odb, &full_entries);
            const commit_oid = try writeCommit(gpa, &r.odb, tree_oid, null, "level");
            try updateRef(dirs[level].dir, io, commit_oid);

            if (child_url) |u| gpa.free(u);
            child_url = try realPathOf(gpa, io, dirs[level].dir);
            child_oid = commit_oid;
        } else {
            var leaf_entries = [_]Tree.Entry{entries_buf[0]};
            const tree_oid = try writeTreeSorted(gpa, &r.odb, &leaf_entries);
            const commit_oid = try writeCommit(gpa, &r.odb, tree_oid, null, "leaf");
            try updateRef(dirs[level].dir, io, commit_oid);

            child_url = try realPathOf(gpa, io, dirs[level].dir);
            child_oid = commit_oid;
        }
    }

    var root = try openTestRepo(gpa, io, dirs[0].dir);
    defer root.deinit();
    // Re-open, since the loop above already closed its own handle via
    // `defer r.deinit()`; `root` here is the same on-disk repository
    // `updateAll` walks from the top.

    var worktree_tmp = testing.tmpDir(.{ .iterate = true });
    defer worktree_tmp.cleanup();

    try testing.expectError(
        error.SubmoduleTooDeep,
        updateAll(gpa, io, &root, worktree_tmp.dir, .{ .recursive = true, .fetch = defaultFetchOptions(gpa, &refspecs_storage) }, null),
    );
    for (&refspecs_storage) |*r| r.deinit(gpa);
}

test "a chain of exactly max_depth submodule levels succeeds" {
    var refspecs_storage: [1]fetch_mod.Refspec = undefined;
    const gpa = testing.allocator;
    const io = testing.io;

    // A chain of `max_depth + 1` repositories: the root plus exactly
    // `max_depth` real submodule levels, the deepest a genuine leaf with
    // no `.gitmodules` of its own. Built leaf first, same shape as the
    // over-the-boundary test above, so each parent already knows its
    // child's commit oid and on-disk url.
    const chain_len = max_depth + 1;
    var dirs: [chain_len]std.testing.TmpDir = undefined;
    var idx: usize = 0;
    while (idx < chain_len) : (idx += 1) dirs[idx] = testing.tmpDir(.{ .iterate = true });
    defer for (&dirs) |*d| d.cleanup();

    var child_oid: ?Oid = null;
    var child_url: ?[]u8 = null;
    defer if (child_url) |u| gpa.free(u);

    var level: usize = chain_len;
    while (level > 0) {
        level -= 1;
        var r = try openTestRepo(gpa, io, dirs[level].dir);
        defer r.deinit();

        var entries_buf: [2]Tree.Entry = undefined;
        var n: usize = 0;
        const marker_blob = try writeBlob(&r.odb, "level\n");
        entries_buf[n] = .{ .mode = .blob, .name = "marker.txt", .oid = marker_blob };
        n += 1;

        var gm_text_opt: ?[]u8 = null;
        defer if (gm_text_opt) |t| gpa.free(t);
        if (child_oid) |coid| {
            gm_text_opt = try gitmodulesText(gpa, "next", "next", child_url.?);
            const gm_blob = try writeBlob(&r.odb, gm_text_opt.?);
            entries_buf[n] = .{ .mode = .blob, .name = ".gitmodules", .oid = gm_blob };
            n += 1;
            var full_entries = [_]Tree.Entry{
                entries_buf[0],
                entries_buf[1],
                .{ .mode = .gitlink, .name = "next", .oid = coid },
            };
            const tree_oid = try writeTreeSorted(gpa, &r.odb, &full_entries);
            const commit_oid = try writeCommit(gpa, &r.odb, tree_oid, null, "level");
            try updateRef(dirs[level].dir, io, commit_oid);

            if (child_url) |u| gpa.free(u);
            child_url = try realPathOf(gpa, io, dirs[level].dir);
            child_oid = commit_oid;
        } else {
            var leaf_entries = [_]Tree.Entry{entries_buf[0]};
            const tree_oid = try writeTreeSorted(gpa, &r.odb, &leaf_entries);
            const commit_oid = try writeCommit(gpa, &r.odb, tree_oid, null, "leaf");
            try updateRef(dirs[level].dir, io, commit_oid);

            child_url = try realPathOf(gpa, io, dirs[level].dir);
            child_oid = commit_oid;
        }
    }

    var root = try openTestRepo(gpa, io, dirs[0].dir);
    defer root.deinit();

    var worktree_tmp = testing.tmpDir(.{ .iterate = true });
    defer worktree_tmp.cleanup();

    try updateAll(gpa, io, &root, worktree_tmp.dir, .{ .recursive = true, .fetch = defaultFetchOptions(gpa, &refspecs_storage) }, null);

    // Walk down `max_depth` "next" components -- one per real submodule
    // level -- and confirm the deepest submodule's own content actually
    // landed, not merely an empty placeholder directory.
    var current = try worktree_tmp.dir.openDir(io, "next", .{ .iterate = true });
    var opened: usize = 1;
    while (opened < max_depth) : (opened += 1) {
        const next = try current.openDir(io, "next", .{ .iterate = true });
        current.close(io);
        current = next;
    }
    defer current.close(io);

    const content = try current.readFileAlloc(io, "marker.txt", gpa, .limited(64));
    defer gpa.free(content);
    try testing.expectEqualStrings("level\n", content);
    for (&refspecs_storage) |*r| r.deinit(gpa);
}

test "a submodule whose gitlink oid the remote does not have is RefNotFound" {
    var refspecs_storage: [1]fetch_mod.Refspec = undefined;
    const gpa = testing.allocator;
    const io = testing.io;

    var sub_tmp = testing.tmpDir(.{ .iterate = true });
    defer sub_tmp.cleanup();
    var sub_source = try openTestRepo(gpa, io, sub_tmp.dir);
    defer sub_source.deinit();
    const blob = try writeBlob(&sub_source.odb, "hi\n");
    var entries = [_]Tree.Entry{.{ .mode = .blob, .name = "f.txt", .oid = blob }};
    const tree_oid = try writeTreeSorted(gpa, &sub_source.odb, &entries);
    const commit_oid = try writeCommit(gpa, &sub_source.odb, tree_oid, null, "one");
    try updateRef(sub_tmp.dir, io, commit_oid);
    const sub_url = try realPathOf(gpa, io, sub_tmp.dir);
    defer gpa.free(sub_url);

    var root_tmp = testing.tmpDir(.{ .iterate = true });
    defer root_tmp.cleanup();
    var root = try openTestRepo(gpa, io, root_tmp.dir);
    defer root.deinit();

    // A gitlink oid the submodule's own source repository never had:
    // built from real, well-formed bytes so it hashes to something the
    // source genuinely lacks, rather than colliding by chance with
    // `commit_oid` above.
    const missing_commit_payload = "tree 0000000000000000000000000000000000000000\nauthor A U Thor <author@example.com> 1700000001 +0000\ncommitter A U Thor <author@example.com> 1700000001 +0000\n\nnever fetched\n";
    const missing_oid = object_mod.loose.hash(.sha1, .commit, missing_commit_payload);

    const gm_text = try gitmodulesText(gpa, "lib", "lib", sub_url);
    defer gpa.free(gm_text);
    const gm_blob = try writeBlob(&root.odb, gm_text);
    var root_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitmodules", .oid = gm_blob },
        .{ .mode = .gitlink, .name = "lib", .oid = missing_oid },
    };
    const root_tree = try writeTreeSorted(gpa, &root.odb, &root_entries);
    const root_commit = try writeCommit(gpa, &root.odb, root_tree, null, "root");
    try updateRef(root_tmp.dir, io, root_commit);

    var worktree_tmp = testing.tmpDir(.{ .iterate = true });
    defer worktree_tmp.cleanup();

    try testing.expectError(
        error.RefNotFound,
        updateAll(gpa, io, &root, worktree_tmp.dir, .{ .fetch = defaultFetchOptions(gpa, &refspecs_storage) }, null),
    );
    for (&refspecs_storage) |*r| r.deinit(gpa);
}

test "a .gitmodules entry with no url is skipped and named in diag" {
    var refspecs_storage: [1]fetch_mod.Refspec = undefined;
    const gpa = testing.allocator;
    const io = testing.io;

    var root_tmp = testing.tmpDir(.{ .iterate = true });
    defer root_tmp.cleanup();
    var root = try openTestRepo(gpa, io, root_tmp.dir);
    defer root.deinit();

    const gm_text = "[submodule \"noUrl\"]\n\tpath = noUrl\n";
    const gm_blob = try writeBlob(&root.odb, gm_text);
    var root_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitmodules", .oid = gm_blob },
    };
    const root_tree = try writeTreeSorted(gpa, &root.odb, &root_entries);
    const root_commit = try writeCommit(gpa, &root.odb, root_tree, null, "root");
    try updateRef(root_tmp.dir, io, root_commit);

    var worktree_tmp = testing.tmpDir(.{ .iterate = true });
    defer worktree_tmp.cleanup();

    var diag: ?Diagnostic = null;
    try updateAll(gpa, io, &root, worktree_tmp.dir, .{ .fetch = defaultFetchOptions(gpa, &refspecs_storage) }, &diag);
    try testing.expect(diag != null);
    try testing.expectEqualStrings("noUrl", diag.?.path.?);
    diag.?.deinit(gpa);

    // Not fatal: no "noUrl" directory was ever created.
    try testing.expectError(error.FileNotFound, worktree_tmp.dir.statFile(io, "noUrl", .{}));
    for (&refspecs_storage) |*r| r.deinit(gpa);
}

test "a .gitmodules entry whose path has no matching gitlink is skipped and named in diag" {
    var refspecs_storage: [1]fetch_mod.Refspec = undefined;
    const gpa = testing.allocator;
    const io = testing.io;

    var root_tmp = testing.tmpDir(.{ .iterate = true });
    defer root_tmp.cleanup();
    var root = try openTestRepo(gpa, io, root_tmp.dir);
    defer root.deinit();

    // "orphan" carries a real url, so it clears the no-url skip, but the
    // tree has no gitlink entry named "orphan" at all: git tolerates a
    // `.gitmodules` entry naming a path the tree never recorded.
    const gm_text = try gitmodulesText(gpa, "orphan", "orphan", "https://example.com/orphan.git");
    defer gpa.free(gm_text);
    const gm_blob = try writeBlob(&root.odb, gm_text);
    var root_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitmodules", .oid = gm_blob },
    };
    const root_tree = try writeTreeSorted(gpa, &root.odb, &root_entries);
    const root_commit = try writeCommit(gpa, &root.odb, root_tree, null, "root");
    try updateRef(root_tmp.dir, io, root_commit);

    var worktree_tmp = testing.tmpDir(.{ .iterate = true });
    defer worktree_tmp.cleanup();

    var diag: ?Diagnostic = null;
    try updateAll(gpa, io, &root, worktree_tmp.dir, .{ .fetch = defaultFetchOptions(gpa, &refspecs_storage) }, &diag);
    try testing.expect(diag != null);
    try testing.expectEqualStrings("orphan", diag.?.path.?);
    diag.?.deinit(gpa);

    // Not fatal: no "orphan" directory was ever created.
    try testing.expectError(error.FileNotFound, worktree_tmp.dir.statFile(io, "orphan", .{}));
    for (&refspecs_storage) |*r| r.deinit(gpa);
}

test "a submodule url starting with ../ is RelativeUrlWithoutParentRemote" {
    var refspecs_storage: [1]fetch_mod.Refspec = undefined;
    const gpa = testing.allocator;
    const io = testing.io;

    var root_tmp = testing.tmpDir(.{ .iterate = true });
    defer root_tmp.cleanup();
    var root = try openTestRepo(gpa, io, root_tmp.dir);
    defer root.deinit();

    const bogus_oid = try Oid.parse(.sha1, "cccccccccccccccccccccccccccccccccccccccc");
    const gm_text = try gitmodulesText(gpa, "sibling", "sibling", "../sibling.git");
    defer gpa.free(gm_text);
    const gm_blob = try writeBlob(&root.odb, gm_text);
    var root_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitmodules", .oid = gm_blob },
        .{ .mode = .gitlink, .name = "sibling", .oid = bogus_oid },
    };
    const root_tree = try writeTreeSorted(gpa, &root.odb, &root_entries);
    const root_commit = try writeCommit(gpa, &root.odb, root_tree, null, "root");
    try updateRef(root_tmp.dir, io, root_commit);

    var worktree_tmp = testing.tmpDir(.{ .iterate = true });
    defer worktree_tmp.cleanup();

    try testing.expectError(
        error.RelativeUrlWithoutParentRemote,
        updateAll(gpa, io, &root, worktree_tmp.dir, .{ .fetch = defaultFetchOptions(gpa, &refspecs_storage) }, null),
    );
    for (&refspecs_storage) |*r| r.deinit(gpa);
}

test "a submodule url starting with ./ is RelativeUrlWithoutParentRemote" {
    var refspecs_storage: [1]fetch_mod.Refspec = undefined;
    const gpa = testing.allocator;
    const io = testing.io;

    var root_tmp = testing.tmpDir(.{ .iterate = true });
    defer root_tmp.cleanup();
    var root = try openTestRepo(gpa, io, root_tmp.dir);
    defer root.deinit();

    const bogus_oid = try Oid.parse(.sha1, "cccccccccccccccccccccccccccccccccccccccc");
    const gm_text = try gitmodulesText(gpa, "local", "local", "./local.git");
    defer gpa.free(gm_text);
    const gm_blob = try writeBlob(&root.odb, gm_text);
    var root_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitmodules", .oid = gm_blob },
        .{ .mode = .gitlink, .name = "local", .oid = bogus_oid },
    };
    const root_tree = try writeTreeSorted(gpa, &root.odb, &root_entries);
    const root_commit = try writeCommit(gpa, &root.odb, root_tree, null, "root");
    try updateRef(root_tmp.dir, io, root_commit);

    var worktree_tmp = testing.tmpDir(.{ .iterate = true });
    defer worktree_tmp.cleanup();

    try testing.expectError(
        error.RelativeUrlWithoutParentRemote,
        updateAll(gpa, io, &root, worktree_tmp.dir, .{ .fetch = defaultFetchOptions(gpa, &refspecs_storage) }, null),
    );
    for (&refspecs_storage) |*r| r.deinit(gpa);
}

test "a submodule path whose intermediate component is a symlink out of the worktree is refused" {
    var refspecs_storage: [1]fetch_mod.Refspec = undefined;
    const gpa = testing.allocator;
    const io = testing.io;

    var root_tmp = testing.tmpDir(.{ .iterate = true });
    defer root_tmp.cleanup();
    var root = try openTestRepo(gpa, io, root_tmp.dir);
    defer root.deinit();

    const bogus_oid = try Oid.parse(.sha1, "cccccccccccccccccccccccccccccccccccccccc");
    const gm_text = try gitmodulesText(gpa, "evil", "vendor/evil", "https://example.com/evil.git");
    defer gpa.free(gm_text);
    const gm_blob = try writeBlob(&root.odb, gm_text);

    // A real "vendor" subtree carrying the "evil" gitlink, exactly the
    // shape `findGitlinkOid` expects for a multi-component path: a tree
    // entry name is one path component, never a whole path.
    var vendor_entries = [_]Tree.Entry{
        .{ .mode = .gitlink, .name = "evil", .oid = bogus_oid },
    };
    const vendor_tree = try writeTreeSorted(gpa, &root.odb, &vendor_entries);

    var root_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitmodules", .oid = gm_blob },
        .{ .mode = .tree, .name = "vendor", .oid = vendor_tree },
    };
    const root_tree = try writeTreeSorted(gpa, &root.odb, &root_entries);
    const root_commit = try writeCommit(gpa, &root.odb, root_tree, null, "root");
    try updateRef(root_tmp.dir, io, root_commit);

    var worktree_tmp = testing.tmpDir(.{ .iterate = true });
    defer worktree_tmp.cleanup();

    // "vendor" itself, an intermediate component of the submodule path
    // rather than its own leaf, is a pre-existing symlink pointing
    // somewhere else entirely.
    var outside_tmp = testing.tmpDir(.{});
    defer outside_tmp.cleanup();
    const outside_path = try realPathOf(gpa, io, outside_tmp.dir);
    defer gpa.free(outside_path);
    try worktree_tmp.dir.symLink(io, outside_path, "vendor", .{});

    try testing.expectError(
        error.InvalidSubmodulePath,
        updateAll(gpa, io, &root, worktree_tmp.dir, .{ .fetch = defaultFetchOptions(gpa, &refspecs_storage) }, null),
    );
    for (&refspecs_storage) |*r| r.deinit(gpa);
}

test "a submodule url beginning ../ resolves against the parent remote url" {
    var refspecs_storage: [1]fetch_mod.Refspec = undefined;
    const gpa = testing.allocator;
    const io = testing.io;

    // Create a parent directory containing both the parent repo and sibling repo
    var repos_tmp = testing.tmpDir(.{ .iterate = true });
    defer repos_tmp.cleanup();

    // Sibling repository
    try repos_tmp.dir.createDir(io, "sibling", .default_dir);
    var sibling_dir = try repos_tmp.dir.openDir(io, "sibling", .{ .iterate = true });
    defer sibling_dir.close(io);
    var sub_source = try openTestRepo(gpa, io, sibling_dir);
    defer sub_source.deinit();
    const blob = try writeBlob(&sub_source.odb, "sibling\n");
    var entries = [_]Tree.Entry{.{ .mode = .blob, .name = "marker.txt", .oid = blob }};
    const tree_oid = try writeTreeSorted(gpa, &sub_source.odb, &entries);
    const commit_oid = try writeCommit(gpa, &sub_source.odb, tree_oid, null, "sibling");
    try updateRef(sibling_dir, io, commit_oid);

    // Parent repository with a ../ relative submodule url
    try repos_tmp.dir.createDir(io, "parent", .default_dir);
    var parent_dir = try repos_tmp.dir.openDir(io, "parent", .{ .iterate = true });
    defer parent_dir.close(io);
    var root = try openTestRepo(gpa, io, parent_dir);
    defer root.deinit();

    const parent_url = try realPathOf(gpa, io, parent_dir);
    defer gpa.free(parent_url);

    const gm_text = try gitmodulesText(gpa, "sibling", "sibling", "../sibling");
    defer gpa.free(gm_text);
    const gm_blob = try writeBlob(&root.odb, gm_text);
    var root_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitmodules", .oid = gm_blob },
        .{ .mode = .gitlink, .name = "sibling", .oid = commit_oid },
    };
    const root_tree = try writeTreeSorted(gpa, &root.odb, &root_entries);
    const root_commit = try writeCommit(gpa, &root.odb, root_tree, null, "root");
    try updateRef(parent_dir, io, root_commit);

    var worktree_tmp = testing.tmpDir(.{ .iterate = true });
    defer worktree_tmp.cleanup();

    try updateAll(gpa, io, &root, worktree_tmp.dir, .{ .fetch = defaultFetchOptions(gpa, &refspecs_storage), .parent_remote_url = parent_url }, null);

    var sibling_wt = try worktree_tmp.dir.openDir(io, "sibling", .{ .iterate = true });
    defer sibling_wt.close(io);
    const content = try sibling_wt.readFileAlloc(io, "marker.txt", gpa, .limited(64));
    defer gpa.free(content);
    try testing.expectEqualStrings("sibling\n", content);
    for (&refspecs_storage) |*r| r.deinit(gpa);
}

test "a submodule url beginning ./ resolves against the parent remote url" {
    var refspecs_storage: [1]fetch_mod.Refspec = undefined;
    const gpa = testing.allocator;
    const io = testing.io;

    // `./` descends into the parent's own url rather than replacing its
    // last segment, so the submodule this resolves to must actually live
    // *inside* the parent's own directory, not beside it.
    var repos_tmp = testing.tmpDir(.{ .iterate = true });
    defer repos_tmp.cleanup();

    try repos_tmp.dir.createDir(io, "parent", .default_dir);
    var parent_dir = try repos_tmp.dir.openDir(io, "parent", .{ .iterate = true });
    defer parent_dir.close(io);
    var root = try openTestRepo(gpa, io, parent_dir);
    defer root.deinit();

    const parent_url = try realPathOf(gpa, io, parent_dir);
    defer gpa.free(parent_url);

    // The "local" repository, nested under the parent's own directory.
    try parent_dir.createDir(io, "local", .default_dir);
    var local_dir = try parent_dir.openDir(io, "local", .{ .iterate = true });
    defer local_dir.close(io);
    var sub_source = try openTestRepo(gpa, io, local_dir);
    defer sub_source.deinit();
    const blob = try writeBlob(&sub_source.odb, "local\n");
    var entries = [_]Tree.Entry{.{ .mode = .blob, .name = "marker.txt", .oid = blob }};
    const tree_oid = try writeTreeSorted(gpa, &sub_source.odb, &entries);
    const commit_oid = try writeCommit(gpa, &sub_source.odb, tree_oid, null, "local");
    try updateRef(local_dir, io, commit_oid);

    const gm_text = try gitmodulesText(gpa, "local", "local", "./local");
    defer gpa.free(gm_text);
    const gm_blob = try writeBlob(&root.odb, gm_text);
    var root_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitmodules", .oid = gm_blob },
        .{ .mode = .gitlink, .name = "local", .oid = commit_oid },
    };
    const root_tree = try writeTreeSorted(gpa, &root.odb, &root_entries);
    const root_commit = try writeCommit(gpa, &root.odb, root_tree, null, "root");
    try updateRef(parent_dir, io, root_commit);

    var worktree_tmp = testing.tmpDir(.{ .iterate = true });
    defer worktree_tmp.cleanup();

    try updateAll(gpa, io, &root, worktree_tmp.dir, .{ .fetch = defaultFetchOptions(gpa, &refspecs_storage), .parent_remote_url = parent_url }, null);

    var local_wt = try worktree_tmp.dir.openDir(io, "local", .{ .iterate = true });
    defer local_wt.close(io);
    const content = try local_wt.readFileAlloc(io, "marker.txt", gpa, .limited(64));
    defer gpa.free(content);
    try testing.expectEqualStrings("local\n", content);
    for (&refspecs_storage) |*r| r.deinit(gpa);
}

test "a relative url with ./ descends into the parent repository rather than beside it" {
    var refspecs_storage: [1]fetch_mod.Refspec = undefined;
    const gpa = testing.allocator;
    const io = testing.io;

    // Two "sub" repositories with the same leaf name at two different
    // places: one beside "parent" (where the old, wrong rule looked, the
    // same place "../sub" resolves to), and one inside "parent" (where
    // "./sub" must actually resolve to). Only the inside one carries the
    // commit the parent's gitlink names, so checking out the wrong one
    // fails outright rather than merely fetching the wrong content.
    var repos_tmp = testing.tmpDir(.{ .iterate = true });
    defer repos_tmp.cleanup();
    try repos_tmp.dir.createDirPath(io, "group/parent");

    var parent_dir = try repos_tmp.dir.openDir(io, "group/parent", .{ .iterate = true });
    defer parent_dir.close(io);
    var root = try openTestRepo(gpa, io, parent_dir);
    defer root.deinit();
    const parent_url = try realPathOf(gpa, io, parent_dir);
    defer gpa.free(parent_url);

    // "beside": group/sub, the same place "../sub" would resolve to.
    try repos_tmp.dir.createDirPath(io, "group/sub");
    var beside_dir = try repos_tmp.dir.openDir(io, "group/sub", .{ .iterate = true });
    defer beside_dir.close(io);
    var beside_source = try openTestRepo(gpa, io, beside_dir);
    defer beside_source.deinit();
    const beside_blob = try writeBlob(&beside_source.odb, "beside\n");
    var beside_entries = [_]Tree.Entry{.{ .mode = .blob, .name = "marker.txt", .oid = beside_blob }};
    const beside_tree = try writeTreeSorted(gpa, &beside_source.odb, &beside_entries);
    const beside_commit = try writeCommit(gpa, &beside_source.odb, beside_tree, null, "beside");
    try updateRef(beside_dir, io, beside_commit);

    // "inside": group/parent/sub, where "./sub" must actually resolve to.
    try parent_dir.createDir(io, "sub", .default_dir);
    var inside_dir = try parent_dir.openDir(io, "sub", .{ .iterate = true });
    defer inside_dir.close(io);
    var inside_source = try openTestRepo(gpa, io, inside_dir);
    defer inside_source.deinit();
    const inside_blob = try writeBlob(&inside_source.odb, "inside\n");
    var inside_entries = [_]Tree.Entry{.{ .mode = .blob, .name = "marker.txt", .oid = inside_blob }};
    const inside_tree = try writeTreeSorted(gpa, &inside_source.odb, &inside_entries);
    const inside_commit = try writeCommit(gpa, &inside_source.odb, inside_tree, null, "inside");
    try updateRef(inside_dir, io, inside_commit);

    const gm_text = try gitmodulesText(gpa, "sub", "sub", "./sub");
    defer gpa.free(gm_text);
    const gm_blob = try writeBlob(&root.odb, gm_text);
    var root_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitmodules", .oid = gm_blob },
        .{ .mode = .gitlink, .name = "sub", .oid = inside_commit },
    };
    const root_tree = try writeTreeSorted(gpa, &root.odb, &root_entries);
    const root_commit = try writeCommit(gpa, &root.odb, root_tree, null, "root");
    try updateRef(parent_dir, io, root_commit);

    var worktree_tmp = testing.tmpDir(.{ .iterate = true });
    defer worktree_tmp.cleanup();

    try updateAll(gpa, io, &root, worktree_tmp.dir, .{ .fetch = defaultFetchOptions(gpa, &refspecs_storage), .parent_remote_url = parent_url }, null);

    var sub_wt = try worktree_tmp.dir.openDir(io, "sub", .{ .iterate = true });
    defer sub_wt.close(io);
    const content = try sub_wt.readFileAlloc(io, "marker.txt", gpa, .limited(64));
    defer gpa.free(content);
    try testing.expectEqualStrings("inside\n", content);
    for (&refspecs_storage) |*r| r.deinit(gpa);
}

test "a relative submodule url with no parent remote url is refused by name" {
    var refspecs_storage: [1]fetch_mod.Refspec = undefined;
    const gpa = testing.allocator;
    const io = testing.io;

    var root_tmp = testing.tmpDir(.{ .iterate = true });
    defer root_tmp.cleanup();
    var root = try openTestRepo(gpa, io, root_tmp.dir);
    defer root.deinit();

    const bogus_oid = try Oid.parse(.sha1, "cccccccccccccccccccccccccccccccccccccccc");
    const gm_text = try gitmodulesText(gpa, "rel", "rel", "../rel.git");
    defer gpa.free(gm_text);
    const gm_blob = try writeBlob(&root.odb, gm_text);
    var root_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitmodules", .oid = gm_blob },
        .{ .mode = .gitlink, .name = "rel", .oid = bogus_oid },
    };
    const root_tree = try writeTreeSorted(gpa, &root.odb, &root_entries);
    const root_commit = try writeCommit(gpa, &root.odb, root_tree, null, "root");
    try updateRef(root_tmp.dir, io, root_commit);

    var worktree_tmp = testing.tmpDir(.{ .iterate = true });
    defer worktree_tmp.cleanup();

    try testing.expectError(
        error.RelativeUrlWithoutParentRemote,
        updateAll(gpa, io, &root, worktree_tmp.dir, .{ .fetch = defaultFetchOptions(gpa, &refspecs_storage) }, null),
    );
    for (&refspecs_storage) |*r| r.deinit(gpa);
}

test "a relative url that would escape above the parent remote root is refused" {
    var refspecs_storage: [1]fetch_mod.Refspec = undefined;
    const gpa = testing.allocator;
    const io = testing.io;

    var root_tmp = testing.tmpDir(.{ .iterate = true });
    defer root_tmp.cleanup();
    var root = try openTestRepo(gpa, io, root_tmp.dir);
    defer root.deinit();

    const bogus_oid = try Oid.parse(.sha1, "cccccccccccccccccccccccccccccccccccccccc");
    const parent_url = "https://host/group/parent.git";

    // Test: ../../../../evil.git tries to escape
    const gm_text = try gitmodulesText(gpa, "evil", "evil", "../../../../evil.git");
    defer gpa.free(gm_text);
    const gm_blob = try writeBlob(&root.odb, gm_text);
    var root_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitmodules", .oid = gm_blob },
        .{ .mode = .gitlink, .name = "evil", .oid = bogus_oid },
    };
    const root_tree = try writeTreeSorted(gpa, &root.odb, &root_entries);
    const root_commit = try writeCommit(gpa, &root.odb, root_tree, null, "root");
    try updateRef(root_tmp.dir, io, root_commit);

    var worktree_tmp = testing.tmpDir(.{ .iterate = true });
    defer worktree_tmp.cleanup();

    try testing.expectError(
        error.RelativeUrlEscapesRoot,
        updateAll(gpa, io, &root, worktree_tmp.dir, .{ .fetch = defaultFetchOptions(gpa, &refspecs_storage), .parent_remote_url = parent_url }, null),
    );
    for (&refspecs_storage) |*r| r.deinit(gpa);
}

test "a relative url with mixed segments that would escape is refused" {
    var refspecs_storage: [1]fetch_mod.Refspec = undefined;
    const gpa = testing.allocator;
    const io = testing.io;

    var root_tmp = testing.tmpDir(.{ .iterate = true });
    defer root_tmp.cleanup();
    var root = try openTestRepo(gpa, io, root_tmp.dir);
    defer root.deinit();

    const bogus_oid = try Oid.parse(.sha1, "cccccccccccccccccccccccccccccccccccccccc");
    const parent_url = "https://host/group/parent.git";

    // Test: ../a/../../../evil.git also escapes
    const gm_text = try gitmodulesText(gpa, "evil2", "evil2", "../a/../../../evil.git");
    defer gpa.free(gm_text);
    const gm_blob = try writeBlob(&root.odb, gm_text);
    var root_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitmodules", .oid = gm_blob },
        .{ .mode = .gitlink, .name = "evil2", .oid = bogus_oid },
    };
    const root_tree = try writeTreeSorted(gpa, &root.odb, &root_entries);
    const root_commit = try writeCommit(gpa, &root.odb, root_tree, null, "root");
    try updateRef(root_tmp.dir, io, root_commit);

    var worktree_tmp = testing.tmpDir(.{ .iterate = true });
    defer worktree_tmp.cleanup();

    try testing.expectError(
        error.RelativeUrlEscapesRoot,
        updateAll(gpa, io, &root, worktree_tmp.dir, .{ .fetch = defaultFetchOptions(gpa, &refspecs_storage), .parent_remote_url = parent_url }, null),
    );
    for (&refspecs_storage) |*r| r.deinit(gpa);
}

test "an absolute submodule url ignores the parent remote url" {
    var refspecs_storage: [1]fetch_mod.Refspec = undefined;
    const gpa = testing.allocator;
    const io = testing.io;

    // The submodule's own source repository
    var sub_tmp = testing.tmpDir(.{ .iterate = true });
    defer sub_tmp.cleanup();
    var sub_source = try openTestRepo(gpa, io, sub_tmp.dir);
    defer sub_source.deinit();
    const blob = try writeBlob(&sub_source.odb, "absolute\n");
    var entries = [_]Tree.Entry{.{ .mode = .blob, .name = "marker.txt", .oid = blob }};
    const tree_oid = try writeTreeSorted(gpa, &sub_source.odb, &entries);
    const commit_oid = try writeCommit(gpa, &sub_source.odb, tree_oid, null, "absolute");
    try updateRef(sub_tmp.dir, io, commit_oid);
    const sub_url = try realPathOf(gpa, io, sub_tmp.dir);
    defer gpa.free(sub_url);

    // Parent repository with an absolute submodule url
    var root_tmp = testing.tmpDir(.{ .iterate = true });
    defer root_tmp.cleanup();
    var root = try openTestRepo(gpa, io, root_tmp.dir);
    defer root.deinit();

    const gm_text = try gitmodulesText(gpa, "abs", "abs", sub_url);
    defer gpa.free(gm_text);
    const gm_blob = try writeBlob(&root.odb, gm_text);
    var root_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitmodules", .oid = gm_blob },
        .{ .mode = .gitlink, .name = "abs", .oid = commit_oid },
    };
    const root_tree = try writeTreeSorted(gpa, &root.odb, &root_entries);
    const root_commit = try writeCommit(gpa, &root.odb, root_tree, null, "root");
    try updateRef(root_tmp.dir, io, root_commit);

    var worktree_tmp = testing.tmpDir(.{ .iterate = true });
    defer worktree_tmp.cleanup();

    // Provide a parent_remote_url that differs from the actual submodule url
    const fake_parent_url = "https://totally.different.host/path/parent.git";
    try updateAll(gpa, io, &root, worktree_tmp.dir, .{ .fetch = defaultFetchOptions(gpa, &refspecs_storage), .parent_remote_url = fake_parent_url }, null);

    var abs_dir = try worktree_tmp.dir.openDir(io, "abs", .{ .iterate = true });
    defer abs_dir.close(io);
    const content = try abs_dir.readFileAlloc(io, "marker.txt", gpa, .limited(64));
    defer gpa.free(content);
    try testing.expectEqualStrings("absolute\n", content);
    for (&refspecs_storage) |*r| r.deinit(gpa);
}
