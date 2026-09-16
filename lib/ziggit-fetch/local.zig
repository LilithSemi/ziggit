//! Fetch: the local strategy, and the dispatcher that picks between it and
//! the remote one.
//!
//! Git implements a `file://` fetch by spawning `git-upload-pack` on the
//! source path and speaking the wire protocol to it over a pipe. This
//! project cannot spawn anything, so a local fetch speaks no protocol at
//! all: it opens the source repository directly, walks reachability from
//! the refs the caller's refspecs match, and copies whatever `repo`'s
//! object database is missing straight across. That is both simpler and
//! faster than a protocol over a pipe would have been.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Oid = oid_mod.Oid;
const Format = oid_mod.Format;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;
const ObjectKind = core_mod.ObjectKind;

const object_mod = @import("ziggit-object");

const odb_mod = @import("ziggit-odb");
const Odb = odb_mod.Odb;

const repo_mod = @import("ziggit-repo");
const Repository = repo_mod.Repository;

const refs_mod = @import("ziggit-refs");
const Store = refs_mod.Store;

const proto = @import("ziggit-proto");

const transport_mod = @import("ziggit-transport");
const Http = transport_mod.Http;
const Ssh = transport_mod.Ssh;

const fetcher_mod = @import("Fetcher.zig");
const FetchOptions = fetcher_mod.FetchOptions;
const Result = fetcher_mod.Result;

const remote_mod = @import("remote.zig");

/// `fetcher_mod.Error` already carries every fault a copy or a ref update
/// can hit; `repo_mod.Error` is added for what opening the source can hit
/// beyond that (a bad `core.repositoryformatversion`, for example).
/// `SshVerifierRequired` is `fetch`'s own refusal of an `ssh://` url
/// carrying no `FetchOptions.ssh`.
pub const Error = fetcher_mod.Error || repo_mod.Error || error{SshVerifierRequired};

/// Fetches from a repository on this filesystem. Speaks no protocol: it
/// opens the source repository and copies the objects reachable from the
/// wanted tips straight into `repo`'s object database. Git spawns
/// `git-upload-pack` for this; we cannot spawn, and reading the source
/// directly is both simpler and faster than a protocol over a pipe would
/// be.
///
/// `source_path` is opened read only and is never written to: this reads
/// through its `Odb` and `Store` alone, and neither is ever asked to
/// write.
pub fn fetchLocal(
    gpa: Allocator,
    io: std.Io,
    repo: *Repository,
    source_path: []const u8,
    options: FetchOptions,
    diag: ?*?Diagnostic,
) Error!Result {
    var source = try openSourceRepo(gpa, io, source_path, diag);
    defer source.deinit();

    const listing = try buildSourceListing(gpa, &source.refs);
    defer {
        for (listing) |*r| {
            var mutable = r.*;
            mutable.deinit(gpa);
        }
        gpa.free(listing);
    }

    var plan = try remote_mod.buildPlan(gpa, repo.format, options.refspecs, listing);
    defer plan.deinit(gpa);

    var copied = try copyReachable(gpa, &repo.odb, &source.odb, repo.format, plan.wants, options.depth, diag);
    defer copied.shallow_boundary.deinit(gpa);

    const updated = try fetcher_mod.applyRefUpdates(gpa, repo, plan.updates, options.update_refs, diag);

    if (options.depth != null and copied.shallow_boundary.items.len != 0) {
        try fetcher_mod.recordShallowBoundary(gpa, io, repo.layout.common_dir, copied.shallow_boundary.items);
    }

    // A local fetch writes FETCH_HEAD exactly as a remote one does. Git
    // makes no distinction, and a cache clone over a local path is the
    // case a person is most likely to open with the git command later.
    if (options.update_refs) {
        if (options.remote_url) |url| {
            try fetcher_mod.writeFetchHead(gpa, io, repo.layout.common_dir, repo.format, plan.updates, url);
        }
    }

    return .{
        .updated = updated,
        .objects_received = copied.objects,
        .bytes_received = copied.bytes,
    };
}

/// Chooses a strategy from `url` and runs it. A `file://` url or a path
/// with no scheme is local; `http` and `https` are always remote, over
/// `Http`. `ssh` is remote too, over `Ssh`, but only once the caller
/// supplies `options.ssh`: `Ssh.open` dials the moment it is called and
/// requires a host key verifier (`Ssh.SshOptions.verifier`), and
/// inventing one here would mean silently trusting or silently refusing
/// every host key alike. `ssh://` with `options.ssh` absent is refused
/// with `error.SshVerifierRequired`, which says plainly that a verifier
/// is missing, distinct from `error.UnsupportedProtocol`, reserved for a
/// scheme this build does not implement at all (`git://`, for example).
pub fn fetch(
    gpa: Allocator,
    io: std.Io,
    repo: *Repository,
    url: []const u8,
    options: FetchOptions,
    diag: ?*?Diagnostic,
) Error!Result {
    return switch (classifyUrl(url)) {
        .local => |path| blk: {
            var opts = options;
            // The url as the caller wrote it, not the path `classifyUrl`
            // pulled out of it: FETCH_HEAD records where the caller said
            // to fetch from.
            opts.remote_url = url;
            break :blk fetchLocal(gpa, io, repo, path, opts, diag);
        },
        .http, .https => blk: {
            var http = try Http.open(gpa, io, url, options.transport);
            defer http.deinit();
            var opts = options;
            opts.remote_url = url;
            break :blk fetcher_mod.fetchRemote(gpa, io, repo, http.transport(), opts, diag);
        },
        .ssh => blk: {
            const ssh_options = options.ssh orelse return error.SshVerifierRequired;
            var ssh = try Ssh.open(gpa, io, url, options.transport, ssh_options);
            defer ssh.deinit();
            var opts = options;
            opts.remote_url = url;
            break :blk fetcher_mod.fetchRemote(gpa, io, repo, ssh.transport(), opts, diag);
        },
        .unknown => error.UnsupportedProtocol,
    };
}

const UrlKind = union(enum) {
    /// The filesystem path this fetch should open: `url` itself for a
    /// bare path with no scheme, or the text after `file://` for a
    /// `file://` url. Borrowed from `url`.
    local: []const u8,
    http,
    https,
    ssh,
    unknown,
};

fn classifyUrl(url: []const u8) UrlKind {
    const separator = "://";
    const at = std.mem.indexOf(u8, url, separator) orelse return .{ .local = url };
    const scheme = url[0..at];
    const rest = url[at + separator.len ..];
    if (std.mem.eql(u8, scheme, "file")) return .{ .local = rest };
    if (std.mem.eql(u8, scheme, "http")) return .http;
    if (std.mem.eql(u8, scheme, "https")) return .https;
    if (std.mem.eql(u8, scheme, "ssh")) return .ssh;
    return .unknown;
}

/// Opens the repository at `source_path` for reading only. `error.NotFound`
/// covers both a path that does not exist and one that exists but is not a
/// git repository: a caller asking to fetch from either has nothing this
/// strategy can read, and the distinction between them is not worth a
/// second error name. Anything else the initial open can fail with,
/// permission denied or a path component that is not a directory, for
/// example, is neither of those: it is reported as `error.IoFailed`, with
/// `diag` carrying the real cause, rather than folded into `NotFound`
/// where a caller would go looking for a path that was never the problem.
///
/// `source_path` names the repository itself, not a work tree subdirectory
/// to search upward from: `repo_mod.discover`'s own upward walk exists for
/// a CLI invoked from somewhere inside a work tree, and reusing it
/// unguarded here would mean a caller who names an ordinary, unrelated
/// subdirectory of this very project silently "fetches from" this
/// project's own repository instead of getting the refusal they asked
/// for. `looksLikeRepoRoot` confirms `source_path` itself already carries
/// a `.git` entry or a bare layout before `discover` ever runs, so
/// `discover`'s first, non-walking check is guaranteed to be the one that
/// matches.
fn openSourceRepo(gpa: Allocator, io: std.Io, source_path: []const u8, diag: ?*?Diagnostic) Error!Repository {
    var dir = core_mod.openDirRelative(io, null, source_path) catch |err| switch (err) {
        error.FileNotFound => return error.NotFound,
        else => {
            reportOpenSourceFailure(diag, gpa, source_path, err);
            return error.IoFailed;
        },
    };
    defer dir.close(io);
    if (!looksLikeRepoRoot(io, dir)) return error.NotFound;

    var layout = repo_mod.discover(gpa, io, dir, .{}, diag) catch |err| switch (err) {
        error.NotARepository => return error.NotFound,
        error.CorruptGitFile => return error.CorruptGitFile,
        error.IoFailed => return error.IoFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
    errdefer layout.deinit(io);

    return repo_mod.Repository.open(gpa, io, layout, .{}, diag);
}

/// Reports, through `diag` when the caller asked for detail, that opening
/// `source_path` failed for a reason other than plain absence. `err`
/// names the real cause; a caller that only sees `error.IoFailed` would
/// otherwise have nothing to go on.
fn reportOpenSourceFailure(diag: ?*?Diagnostic, gpa: Allocator, source_path: []const u8, err: std.Io.Dir.OpenError) void {
    if (!core_mod.wants(diag)) return;
    const path = gpa.dupe(u8, source_path) catch null;
    const detail = std.fmt.allocPrint(gpa, "could not open source repository: {s}", .{@errorName(err)}) catch null;
    core_mod.report(diag, gpa, .{ .kind = .io, .path = path, .detail = detail });
}

/// True when `dir` itself, with no ancestor considered, already looks like
/// a repository: a `.git` entry (directory or gitfile) directly inside it,
/// or `dir` itself laid out bare (a `HEAD` file alongside `objects` and
/// `refs` directories). Deliberately only as thorough as it needs to be to
/// gate `discover` below; `discover` itself still does the real parsing
/// and validation once this says there is something here worth it trying.
fn looksLikeRepoRoot(io: std.Io, dir: std.Io.Dir) bool {
    // A failed `.git` stat, missing, unreadable, or anything else, just
    // means "no `.git` entry here"; `catch null` says that outright
    // instead of an empty catch block that leaves the intent implicit.
    // The bare-layout checks below decide the rest.
    if (dir.statFile(io, ".git", .{}) catch null) |_| return true;

    const head_stat = dir.statFile(io, "HEAD", .{}) catch return false;
    if (head_stat.kind != .file) return false;

    var objects_dir = dir.openDir(io, "objects", .{}) catch return false;
    objects_dir.close(io);

    var refs_dir = dir.openDir(io, "refs", .{}) catch return false;
    refs_dir.close(io);

    return true;
}

/// Builds a `proto.RefLine` per ref `source`'s `Store` holds, so
/// `remote_mod.buildPlan`, the exact matcher `fetchRemote` uses against a
/// server's `ls-refs` listing, can be reused unchanged against a local
/// source instead of a wire response. A symbolic ref is resolved to the
/// object id it currently reaches; one that cannot be resolved (a
/// dangling symref) is left out rather than failing the whole listing.
fn buildSourceListing(gpa: Allocator, source_refs: *Store) Error![]proto.RefLine {
    var it = try source_refs.iterate("");
    defer it.deinit(gpa);

    var out: std.ArrayList(proto.RefLine) = .empty;
    errdefer {
        for (out.items) |*r| r.deinit(gpa);
        out.deinit(gpa);
    }

    while (it.next()) |ref_owned| {
        var ref = ref_owned;
        defer ref.deinit(gpa);

        const oid: Oid = switch (ref.target) {
            .oid => |o| o,
            .symbolic => source_refs.resolve(ref.name, null) catch continue,
        };
        const name_owned = try gpa.dupe(u8, ref.name);
        errdefer gpa.free(name_owned);
        try out.append(gpa, .{ .oid = oid, .name = name_owned, .peeled = ref.peeled, .symref_target = null });
    }

    return out.toOwnedSlice(gpa);
}

const CopyResult = struct { objects: u32, bytes: u64, shallow_boundary: std.ArrayList(Oid) };

/// Walks every object reachable from `wants`, in `source`, and copies
/// whatever `dest` does not already have. An object `dest` already holds
/// is skipped without being read from `source` at all, on the same
/// assumption `haves`-based negotiation makes for a remote fetch: if the
/// destination already has an object, it was fetched whole, so whatever it
/// reaches is already there too. `visited` is shared across every root in
/// `wants`, so an object reachable from two of them is still only ever
/// read and written once.
///
/// When `depth` is not null, the walk is bounded so that only commits
/// within that depth from a root are copied. A commit whose parents are
/// excluded by the depth bound is recorded in the shallow boundary.
/// Depth counts commits, not hops; depth = 1 is just the tip, depth = 2
/// is the tip and its immediate parents.
///
/// Assumption, stated rather than proven here: an object reached only
/// through `source`'s own `objects/info/alternates` is read the same way
/// as one in `source`'s own object database, since this calls only
/// `source.odb.read`, and following alternates is `ziggit-odb`'s own
/// concern, already covered by that module's tests. Nothing below is
/// alternates-specific; a judgement call, not an oversight.
fn copyReachable(
    gpa: Allocator,
    dest: *Odb,
    source: *Odb,
    format: Format,
    wants: []const Oid,
    depth: ?u32,
    diag: ?*?Diagnostic,
) Error!CopyResult {
    var visited: std.AutoHashMapUnmanaged(Oid, void) = .empty;
    defer visited.deinit(gpa);
    var commit_depth: std.AutoHashMapUnmanaged(Oid, u32) = .empty;
    defer commit_depth.deinit(gpa);
    var stack: std.ArrayList(Oid) = .empty;
    defer stack.deinit(gpa);
    var shallow_boundary: std.ArrayList(Oid) = .empty;

    for (wants) |w| {
        if (visited.contains(w)) continue;
        try visited.put(gpa, w, {});
        try stack.append(gpa, w);
        if (depth != null) {
            try commit_depth.put(gpa, w, 1);
        }
    }

    var objects: u32 = 0;
    var bytes: u64 = 0;

    while (stack.pop()) |current| {
        if (try dest.exists(current)) continue;

        var capture: std.Io.Writer.Allocating = .init(gpa);
        defer capture.deinit();
        const kind = try source.read(current, &capture.writer, diag);
        const payload = capture.written();

        _ = try dest.write(kind, payload, diag);
        objects += 1;
        bytes += payload.len;

        const current_depth = if (depth != null) commit_depth.get(current) else null;

        if (kind == .commit and depth != null) {
            var commit = object_mod.Commit.parse(gpa, format, payload) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.CorruptCommit => return error.CorruptObject,
            };
            defer commit.deinit(gpa);

            if (current_depth) |cd| {
                if (cd < depth.?) {
                    for (commit.parents) |p| {
                        if (visited.contains(p)) continue;
                        try visited.put(gpa, p, {});
                        try stack.append(gpa, p);
                        try commit_depth.put(gpa, p, cd + 1);
                    }
                } else {
                    try shallow_boundary.append(gpa, current);
                }
            }

            try pushOne(gpa, &visited, &stack, commit.tree);
        } else {
            try pushChildren(gpa, &visited, &stack, format, kind, payload);
        }
    }

    return .{ .objects = objects, .bytes = bytes, .shallow_boundary = shallow_boundary };
}

/// Pushes every object `payload` (an object of `kind`) points at directly
/// onto `stack`, skipping one already in `visited`. A gitlink tree entry
/// names a commit in a different repository entirely, never present in
/// this source's own object database, so it is never pushed: there is
/// nothing here for this walk to follow it to.
fn pushChildren(
    gpa: Allocator,
    visited: *std.AutoHashMapUnmanaged(Oid, void),
    stack: *std.ArrayList(Oid),
    format: Format,
    kind: ObjectKind,
    payload: []const u8,
) Error!void {
    switch (kind) {
        .blob => {},
        .tree => {
            var tree = object_mod.Tree.parse(gpa, format, payload) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.CorruptTree => return error.CorruptObject,
            };
            defer tree.deinit(gpa);
            for (tree.entries) |entry| {
                if (entry.mode.isGitlink()) continue;
                try pushOne(gpa, visited, stack, entry.oid);
            }
        },
        .commit => {
            var commit = object_mod.Commit.parse(gpa, format, payload) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.CorruptCommit => return error.CorruptObject,
            };
            defer commit.deinit(gpa);
            try pushOne(gpa, visited, stack, commit.tree);
            for (commit.parents) |p| try pushOne(gpa, visited, stack, p);
        },
        .tag => {
            var tag = object_mod.Tag.parse(gpa, format, payload) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.CorruptTag => return error.CorruptObject,
            };
            defer tag.deinit(gpa);
            try pushOne(gpa, visited, stack, tag.object);
        },
    }
}

fn pushOne(gpa: Allocator, visited: *std.AutoHashMapUnmanaged(Oid, void), stack: *std.ArrayList(Oid), oid: Oid) Allocator.Error!void {
    if (visited.contains(oid)) return;
    try visited.put(gpa, oid, {});
    try stack.append(gpa, oid);
}

const pack_mod = @import("ziggit-pack");

const refspec_mod = @import("refspec.zig");
const Refspec = refspec_mod.Refspec;

const testing = std.testing;

// Test helpers shared by every test below.

const identity_line = "A U Thor <author@example.com> 1700000000 +0000";
const test_committer: core_mod.Committer = .{ .name = "A U Thor", .email = "author@example.com" };

fn buildMinimalRepo(io: std.Io, dir: std.Io.Dir) !void {
    try dir.createDirPath(io, "objects/pack");
    try dir.createDirPath(io, "refs/heads");
    try dir.writeFile(io, .{ .sub_path = "HEAD", .data = "ref: refs/heads/main\n" });
}

fn openTestRepo(gpa: Allocator, io: std.Io, dir: std.Io.Dir) !Repository {
    try buildMinimalRepo(io, dir);
    const layout = try repo_mod.discover(gpa, io, dir, .{}, null);
    return Repository.open(gpa, io, layout, .{ .committer = test_committer }, null);
}

/// Builds an ordinary, non-bare repository at `dir`: a `.git` directory
/// holding `HEAD`, `objects`, and `refs`, with `dir` itself standing in
/// for the work tree. This is the common real-world shape; every other
/// fixture in this file builds the bare shape instead, since it is
/// simplest, but `looksLikeRepoRoot`'s `.git`-entry branch is only ever
/// exercised against this one.
fn buildOrdinaryRepo(io: std.Io, dir: std.Io.Dir) !void {
    try dir.createDirPath(io, ".git/objects/pack");
    try dir.createDirPath(io, ".git/refs/heads");
    try dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });
}

fn openOrdinaryTestRepo(gpa: Allocator, io: std.Io, dir: std.Io.Dir) !Repository {
    try buildOrdinaryRepo(io, dir);
    const layout = try repo_mod.discover(gpa, io, dir, .{}, null);
    return Repository.open(gpa, io, layout, .{ .committer = test_committer }, null);
}

/// Builds a linked worktree at `dir`/"wt": a real repository at
/// `dir`/"main.git" (`HEAD`, `objects`, `refs`, exactly `buildOrdinaryRepo`'s
/// insides but at the top of "main.git" rather than under a nested
/// `.git`), plus the `worktrees/wt1` entry and `commondir` file a linked
/// worktree's own git directory carries, plus `dir`/"wt/.git", a file
/// holding `gitdir: ../main.git/worktrees/wt1`. `dir`/"wt" is what a
/// caller points a fetch at; its own `.git` is a file, not a directory,
/// which is the shape every linked worktree has.
fn buildLinkedWorktreeRepo(io: std.Io, dir: std.Io.Dir) !void {
    try dir.createDirPath(io, "main.git/objects/pack");
    try dir.createDirPath(io, "main.git/refs/heads");
    try dir.writeFile(io, .{ .sub_path = "main.git/HEAD", .data = "ref: refs/heads/main\n" });
    try dir.createDirPath(io, "main.git/worktrees/wt1");
    try dir.writeFile(io, .{ .sub_path = "main.git/worktrees/wt1/commondir", .data = "../..\n" });
    try dir.createDirPath(io, "wt");
    try dir.writeFile(io, .{ .sub_path = "wt/.git", .data = "gitdir: ../main.git/worktrees/wt1\n" });
}

fn openLinkedWorktreeTestRepo(gpa: Allocator, io: std.Io, dir: std.Io.Dir) !Repository {
    try buildLinkedWorktreeRepo(io, dir);
    var wt = try dir.openDir(io, "wt", .{ .iterate = true });
    defer wt.close(io);
    const layout = try repo_mod.discover(gpa, io, wt, .{}, null);
    return Repository.open(gpa, io, layout, .{ .committer = test_committer }, null);
}

fn realPathOf(gpa: Allocator, io: std.Io, dir: std.Io.Dir) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try dir.realPath(io, &buf);
    return gpa.dupe(u8, buf[0..len]);
}

fn buildTreePayload(gpa: Allocator, blob_oid: Oid) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll("100644 file.txt\x00");
    try out.writer.writeAll(blob_oid.slice());
    return out.toOwnedSlice();
}

fn buildCommitPayload(gpa: Allocator, tree_hex: []const u8, parent_hex: ?[]const u8, message: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.print("tree {s}\n", .{tree_hex});
    if (parent_hex) |p| try out.writer.print("parent {s}\n", .{p});
    try out.writer.print("author {s}\n", .{identity_line});
    try out.writer.print("committer {s}\n", .{identity_line});
    try out.writer.print("\n{s}\n", .{message});
    return out.toOwnedSlice();
}

/// One blob, one tree naming it, and one commit naming that tree: the
/// smallest history where "everything a commit reaches" is more than the
/// commit object itself. Written straight into `source`'s own `Odb` and
/// `Store`, which is ordinary test setup, not a violation of the
/// read-only guarantee `fetchLocal` itself owes the source: nothing under
/// test runs yet when this builds the fixture.
const SourceHistory = struct {
    blob_oid: Oid,
    tree_oid: Oid,
    commit_oid: Oid,
};

fn buildSourceHistory(gpa: Allocator, source: *Repository) !SourceHistory {
    const blob_oid = try source.odb.write(.blob, "hello world\n", null);

    const tree_payload = try buildTreePayload(gpa, blob_oid);
    defer gpa.free(tree_payload);
    const tree_oid = try source.odb.write(.tree, tree_payload, null);

    var tree_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const tree_hex = tree_oid.toHex(&tree_hex_buf);
    const commit_payload = try buildCommitPayload(gpa, tree_hex, null, "one");
    defer gpa.free(commit_payload);
    const commit_oid = try source.odb.write(.commit, commit_payload, null);

    try source.refs.update("refs/heads/main", commit_oid, null, null, null);

    return .{ .blob_oid = blob_oid, .tree_oid = tree_oid, .commit_oid = commit_oid };
}

/// A multi-commit history with at least 3 commits in a chain.
const MultiCommitHistory = struct {
    commits: [3]Oid,
};

fn buildMultiCommitHistory(gpa: Allocator, source: *Repository) !MultiCommitHistory {
    const blob_oid = try source.odb.write(.blob, "hello world\n", null);

    const tree_payload = try buildTreePayload(gpa, blob_oid);
    defer gpa.free(tree_payload);
    const tree_oid = try source.odb.write(.tree, tree_payload, null);

    var tree_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const tree_hex = tree_oid.toHex(&tree_hex_buf);

    var hex_bufs: [3][Oid.max_formatted_length]u8 = undefined;

    const commit1_payload = try buildCommitPayload(gpa, tree_hex, null, "first");
    defer gpa.free(commit1_payload);
    const commit1_oid = try source.odb.write(.commit, commit1_payload, null);

    const commit1_hex = commit1_oid.toHex(&hex_bufs[0]);

    const commit2_payload = try buildCommitPayload(gpa, tree_hex, commit1_hex, "second");
    defer gpa.free(commit2_payload);
    const commit2_oid = try source.odb.write(.commit, commit2_payload, null);

    const commit2_hex = commit2_oid.toHex(&hex_bufs[1]);

    const commit3_payload = try buildCommitPayload(gpa, tree_hex, commit2_hex, "third");
    defer gpa.free(commit3_payload);
    const commit3_oid = try source.odb.write(.commit, commit3_payload, null);

    try source.refs.update("refs/heads/main", commit3_oid, null, null, null);

    return .{ .commits = .{ commit1_oid, commit2_oid, commit3_oid } };
}

/// A snapshot of every regular file under `dir`, relative path to content,
/// good enough to prove `dir` was not written to by comparing two
/// snapshots for exact equality. Both the paths present and every byte of
/// every file's content must match; a snapshot taken before and after a
/// call this test suspects of writing is the whole point of collecting
/// one at all.
const DirSnapshot = struct {
    entries: []Entry,

    const Entry = struct { path: []u8, content: []u8 };

    fn take(gpa: Allocator, io: std.Io, dir: std.Io.Dir) !DirSnapshot {
        var list: std.ArrayList(Entry) = .empty;
        errdefer {
            for (list.items) |e| {
                gpa.free(e.path);
                gpa.free(e.content);
            }
            list.deinit(gpa);
        }

        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const path = try gpa.dupe(u8, entry.path);
            errdefer gpa.free(path);
            const content = try dir.readFileAlloc(io, entry.path, gpa, .limited(1 << 20));
            errdefer gpa.free(content);
            try list.append(gpa, .{ .path = path, .content = content });
        }

        std.mem.sort(Entry, list.items, {}, lessThanByPath);
        return .{ .entries = try list.toOwnedSlice(gpa) };
    }

    fn lessThanByPath(_: void, a: Entry, b: Entry) bool {
        return std.mem.lessThan(u8, a.path, b.path);
    }

    fn deinit(s: *DirSnapshot, gpa: Allocator) void {
        for (s.entries) |e| {
            gpa.free(e.path);
            gpa.free(e.content);
        }
        gpa.free(s.entries);
        s.* = undefined;
    }

    fn expectEqual(a: DirSnapshot, b: DirSnapshot) !void {
        try testing.expectEqual(a.entries.len, b.entries.len);
        for (a.entries, b.entries) |x, y| {
            try testing.expectEqualStrings(x.path, y.path);
            try testing.expectEqualStrings(x.content, y.content);
        }
    }
};

// expected

test "fetchLocal copies a commit and everything it reaches" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source_tmp = testing.tmpDir(.{ .iterate = true });
    defer source_tmp.cleanup();
    var source = try openTestRepo(gpa, io, source_tmp.dir);
    defer source.deinit();
    const history = try buildSourceHistory(gpa, &source);

    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    const source_path = try realPathOf(gpa, io, source_tmp.dir);
    defer gpa.free(source_path);

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchLocal(gpa, io, &dest, source_path, .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    try testing.expect(try dest.odb.exists(history.commit_oid));
    try testing.expect(try dest.odb.exists(history.tree_oid));
    try testing.expect(try dest.odb.exists(history.blob_oid));
}

test "fetchLocal updates the local refs the refspecs name" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source_tmp = testing.tmpDir(.{ .iterate = true });
    defer source_tmp.cleanup();
    var source = try openTestRepo(gpa, io, source_tmp.dir);
    defer source.deinit();
    const history = try buildSourceHistory(gpa, &source);

    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    const source_path = try realPathOf(gpa, io, source_tmp.dir);
    defer gpa.free(source_path);

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchLocal(gpa, io, &dest, source_path, .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    try testing.expectEqual(@as(usize, 1), result.updated.len);
    try testing.expectEqualStrings("refs/remotes/origin/main", result.updated[0].name);
    try testing.expect(std.meta.activeTag(result.updated[0].outcome) == .updated);
    try testing.expect(result.updated[0].outcome.updated.old == null);
    try testing.expect(result.updated[0].outcome.updated.new.eql(history.commit_oid));

    const resolved = try dest.refs.resolve("refs/remotes/origin/main", null);
    try testing.expect(resolved.eql(history.commit_oid));
}

test "fetchLocal skips an object the destination already has" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source_tmp = testing.tmpDir(.{ .iterate = true });
    defer source_tmp.cleanup();
    var source = try openTestRepo(gpa, io, source_tmp.dir);
    defer source.deinit();
    const history = try buildSourceHistory(gpa, &source);

    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();
    // The destination already has the blob and the tree: only the commit
    // itself is missing, so only the commit should be copied.
    _ = try dest.odb.write(.blob, "hello world\n", null);
    const tree_payload = try buildTreePayload(gpa, history.blob_oid);
    defer gpa.free(tree_payload);
    _ = try dest.odb.write(.tree, tree_payload, null);

    const source_path = try realPathOf(gpa, io, source_tmp.dir);
    defer gpa.free(source_path);

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchLocal(gpa, io, &dest, source_path, .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    try testing.expectEqual(@as(u32, 1), result.objects_received);
    try testing.expect(try dest.odb.exists(history.commit_oid));
}

test "fetchLocal resolves an object id source" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source_tmp = testing.tmpDir(.{ .iterate = true });
    defer source_tmp.cleanup();
    var source = try openTestRepo(gpa, io, source_tmp.dir);
    defer source.deinit();
    const history = try buildSourceHistory(gpa, &source);

    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    const source_path = try realPathOf(gpa, io, source_tmp.dir);
    defer gpa.free(source_path);

    // A local fetch has every object on disk already: there is no
    // capability to negotiate, so an object id source either resolves
    // straight to the object or it does not. No advertised ref names this
    // commit under the destination for the refspec, only its own oid.
    var oid_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const oid_hex = history.commit_oid.toHex(&oid_hex_buf);
    const refspec_text = try std.fmt.allocPrint(gpa, "{s}:refs/heads/pinned", .{oid_hex});
    defer gpa.free(refspec_text);

    var rs = [_]Refspec{try Refspec.parse(gpa, refspec_text)};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchLocal(gpa, io, &dest, source_path, .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    try testing.expect(try dest.odb.exists(history.commit_oid));
    try testing.expect(try dest.odb.exists(history.tree_oid));
    try testing.expect(try dest.odb.exists(history.blob_oid));

    const resolved = try dest.refs.resolve("refs/heads/pinned", null);
    try testing.expect(resolved.eql(history.commit_oid));
}

test "fetch dispatches a file:// url to the local strategy" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source_tmp = testing.tmpDir(.{ .iterate = true });
    defer source_tmp.cleanup();
    var source = try openTestRepo(gpa, io, source_tmp.dir);
    defer source.deinit();
    const history = try buildSourceHistory(gpa, &source);

    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    const source_path = try realPathOf(gpa, io, source_tmp.dir);
    defer gpa.free(source_path);
    const url = try std.fmt.allocPrint(gpa, "file://{s}", .{source_path});
    defer gpa.free(url);

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetch(gpa, io, &dest, url, .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    const resolved = try dest.refs.resolve("refs/remotes/origin/main", null);
    try testing.expect(resolved.eql(history.commit_oid));
}

test "fetch dispatches a bare path with no scheme to the local strategy" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source_tmp = testing.tmpDir(.{ .iterate = true });
    defer source_tmp.cleanup();
    var source = try openTestRepo(gpa, io, source_tmp.dir);
    defer source.deinit();
    const history = try buildSourceHistory(gpa, &source);

    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    const source_path = try realPathOf(gpa, io, source_tmp.dir);
    defer gpa.free(source_path);

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetch(gpa, io, &dest, source_path, .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    const resolved = try dest.refs.resolve("refs/remotes/origin/main", null);
    try testing.expect(resolved.eql(history.commit_oid));
}

test "a local fetch writes FETCH_HEAD naming the path the caller gave" {
    // Git makes no distinction between a local and a remote fetch here,
    // and a cache clone over a local path is the case a person is most
    // likely to open with the git command afterwards.
    const gpa = testing.allocator;
    const io = testing.io;
    var source_tmp = testing.tmpDir(.{ .iterate = true });
    defer source_tmp.cleanup();
    var source = try openTestRepo(gpa, io, source_tmp.dir);
    defer source.deinit();
    const history = try buildSourceHistory(gpa, &source);

    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    const source_path = try realPathOf(gpa, io, source_tmp.dir);
    defer gpa.free(source_path);

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetch(gpa, io, &dest, source_path, .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    const content = try dest_tmp.dir.readFileAlloc(io, "FETCH_HEAD", gpa, .limited(4096));
    defer gpa.free(content);

    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const expected = try std.fmt.allocPrint(
        gpa,
        "{s}\t\tbranch 'main' of {s}\n",
        .{ history.commit_oid.toHex(&hex_buf), source_path },
    );
    defer gpa.free(expected);

    try testing.expectEqualStrings(expected, content);
}

test "fetch dispatches an https url to the remote strategy" {
    const gpa = testing.allocator;
    const io = testing.io;
    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    // Loopback on a port nothing listens on: a connection refusal proves
    // this reached the network transport, not the local filesystem one.
    // A one second bound keeps this test fast regardless of environment.
    // Whatever the exact network fault, it must not be the local
    // strategy's own "not a repository" answer: that would mean this
    // dispatched to `fetchLocal` on a string that is plainly a url.
    try testing.expectError(error.NetworkFailed, fetch(gpa, io, &dest, "https://127.0.0.1:1/example.git", .{
        .refspecs = &rs,
        .transport = .{ .connect_timeout_ms = 1000 },
    }, null));
}

// suspicious

test "fetchLocal on a path that is not a repository is NotFound" {
    const gpa = testing.allocator;
    const io = testing.io;
    var not_a_repo = testing.tmpDir(.{ .iterate = true });
    defer not_a_repo.cleanup();

    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    const path = try realPathOf(gpa, io, not_a_repo.dir);
    defer gpa.free(path);

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    try testing.expectError(error.NotFound, fetchLocal(gpa, io, &dest, path, .{ .refspecs = &rs }, null));
}

test "fetchLocal never writes to the source repository" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source_tmp = testing.tmpDir(.{ .iterate = true });
    defer source_tmp.cleanup();
    var source = try openTestRepo(gpa, io, source_tmp.dir);
    defer source.deinit();
    _ = try buildSourceHistory(gpa, &source);

    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    const source_path = try realPathOf(gpa, io, source_tmp.dir);
    defer gpa.free(source_path);

    var before = try DirSnapshot.take(gpa, io, source_tmp.dir);
    defer before.deinit(gpa);

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchLocal(gpa, io, &dest, source_path, .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    var after = try DirSnapshot.take(gpa, io, source_tmp.dir);
    defer after.deinit(gpa);

    try before.expectEqual(after);
}

test "fetchLocal reads a packed object from the source" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source_tmp = testing.tmpDir(.{ .iterate = true });
    defer source_tmp.cleanup();
    try buildMinimalRepo(io, source_tmp.dir);

    const blob_payload = "hello world\n";
    const blob_oid = object_mod.loose.hash(.sha1, .blob, blob_payload);

    const tree_payload = try buildTreePayload(gpa, blob_oid);
    defer gpa.free(tree_payload);
    const tree_oid = object_mod.loose.hash(.sha1, .tree, tree_payload);

    var tree_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const tree_hex = tree_oid.toHex(&tree_hex_buf);
    const commit_payload = try buildCommitPayload(gpa, tree_hex, null, "packed");
    defer gpa.free(commit_payload);
    const commit_oid = object_mod.loose.hash(.sha1, .commit, commit_payload);

    var built = try pack_mod.testing.buildTestPack(gpa, .sha1, &.{
        .{ .object = .{ .kind = .blob, .payload = blob_payload } },
        .{ .object = .{ .kind = .tree, .payload = tree_payload } },
        .{ .object = .{ .kind = .commit, .payload = commit_payload } },
    });
    defer built.deinit(gpa);

    var pack_dir = try source_tmp.dir.openDir(io, "objects/pack", .{ .iterate = true });
    defer pack_dir.close(io);
    try pack_dir.writeFile(io, .{ .sub_path = "pack-1.pack", .data = built.bytes });
    {
        var pack_read_buf: [4096]u8 = undefined;
        var pack_file = try pack_dir.openFile(io, "pack-1.pack", .{});
        defer pack_file.close(io);
        var pack_reader = pack_file.reader(io, &pack_read_buf);

        var idx_write_buf: [4096]u8 = undefined;
        var idx_file = try pack_dir.createFile(io, "pack-1.idx", .{ .read = true });
        defer idx_file.close(io);
        var idx_writer = idx_file.writer(io, &idx_write_buf);

        try pack_mod.writeIndex(gpa, .sha1, &pack_reader, &idx_writer, null);
    }

    // No loose object anywhere in the source: every one of the three must
    // come from the pack this test just wrote.
    var commit_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const ref_line = try std.fmt.allocPrint(gpa, "{s}\n", .{commit_oid.toHex(&commit_hex_buf)});
    defer gpa.free(ref_line);
    try source_tmp.dir.writeFile(io, .{ .sub_path = "refs/heads/main", .data = ref_line });

    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    const source_path = try realPathOf(gpa, io, source_tmp.dir);
    defer gpa.free(source_path);

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchLocal(gpa, io, &dest, source_path, .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    try testing.expect(try dest.odb.exists(commit_oid));
    try testing.expect(try dest.odb.exists(tree_oid));
    try testing.expect(try dest.odb.exists(blob_oid));
}

test "a local fetch with depth 1 copies the tip commit and none of its parents" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source_tmp = testing.tmpDir(.{ .iterate = true });
    defer source_tmp.cleanup();
    var source = try openTestRepo(gpa, io, source_tmp.dir);
    defer source.deinit();
    const history = try buildMultiCommitHistory(gpa, &source);

    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    const source_path = try realPathOf(gpa, io, source_tmp.dir);
    defer gpa.free(source_path);

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchLocal(gpa, io, &dest, source_path, .{ .refspecs = &rs, .depth = 1 }, null);
    defer result.deinit(gpa);

    try testing.expect(try dest.odb.exists(history.commits[2]));
    try testing.expect(!try dest.odb.exists(history.commits[1]));
    try testing.expect(!try dest.odb.exists(history.commits[0]));
}

test "a local fetch with depth 2 copies the tip and its immediate parents" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source_tmp = testing.tmpDir(.{ .iterate = true });
    defer source_tmp.cleanup();
    var source = try openTestRepo(gpa, io, source_tmp.dir);
    defer source.deinit();
    const history = try buildMultiCommitHistory(gpa, &source);

    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    const source_path = try realPathOf(gpa, io, source_tmp.dir);
    defer gpa.free(source_path);

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchLocal(gpa, io, &dest, source_path, .{ .refspecs = &rs, .depth = 2 }, null);
    defer result.deinit(gpa);

    try testing.expect(try dest.odb.exists(history.commits[2]));
    try testing.expect(try dest.odb.exists(history.commits[1]));
    try testing.expect(!try dest.odb.exists(history.commits[0]));
}

test "a local fetch with a depth writes the shallow boundary file" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source_tmp = testing.tmpDir(.{ .iterate = true });
    defer source_tmp.cleanup();
    var source = try openTestRepo(gpa, io, source_tmp.dir);
    defer source.deinit();
    _ = try buildMultiCommitHistory(gpa, &source);

    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    const source_path = try realPathOf(gpa, io, source_tmp.dir);
    defer gpa.free(source_path);

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchLocal(gpa, io, &dest, source_path, .{ .refspecs = &rs, .depth = 1 }, null);
    defer result.deinit(gpa);

    const shallow = dest.layout.common_dir.readFileAlloc(io, "shallow", gpa, .limited(1 << 20)) catch {
        try testing.expect(false);
        return;
    };
    defer gpa.free(shallow);

    try testing.expect(shallow.len > 0);
}

test "a commit whose parents the depth excludes is named in the shallow boundary" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source_tmp = testing.tmpDir(.{ .iterate = true });
    defer source_tmp.cleanup();
    var source = try openTestRepo(gpa, io, source_tmp.dir);
    defer source.deinit();
    const history = try buildMultiCommitHistory(gpa, &source);

    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    const source_path = try realPathOf(gpa, io, source_tmp.dir);
    defer gpa.free(source_path);

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchLocal(gpa, io, &dest, source_path, .{ .refspecs = &rs, .depth = 2 }, null);
    defer result.deinit(gpa);

    const shallow = dest.layout.common_dir.readFileAlloc(io, "shallow", gpa, .limited(1 << 20)) catch {
        try testing.expect(false);
        return;
    };
    defer gpa.free(shallow);

    var commit2_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const commit2_hex = history.commits[1].toHex(&commit2_hex_buf);
    try testing.expect(std.mem.containsAtLeast(u8, shallow, 1, commit2_hex));
}

test "a local fetch with no depth still copies the whole history" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source_tmp = testing.tmpDir(.{ .iterate = true });
    defer source_tmp.cleanup();
    var source = try openTestRepo(gpa, io, source_tmp.dir);
    defer source.deinit();
    const history = try buildMultiCommitHistory(gpa, &source);

    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    const source_path = try realPathOf(gpa, io, source_tmp.dir);
    defer gpa.free(source_path);

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchLocal(gpa, io, &dest, source_path, .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    try testing.expect(try dest.odb.exists(history.commits[2]));
    try testing.expect(try dest.odb.exists(history.commits[1]));
    try testing.expect(try dest.odb.exists(history.commits[0]));
}

// The ordinary repository layout (a `.git` directory, or a `.git` file for
// a linked worktree) had no coverage at all before this: every fixture
// above builds the bare shape instead. These exercise `looksLikeRepoRoot`'s
// `.git`-entry branch, the one the bug below was about.

test "fetchLocal fetches from an ordinary, non-bare source repository" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source_tmp = testing.tmpDir(.{ .iterate = true });
    defer source_tmp.cleanup();
    var source = try openOrdinaryTestRepo(gpa, io, source_tmp.dir);
    defer source.deinit();
    const history = try buildSourceHistory(gpa, &source);

    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    const source_path = try realPathOf(gpa, io, source_tmp.dir);
    defer gpa.free(source_path);

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchLocal(gpa, io, &dest, source_path, .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    try testing.expect(try dest.odb.exists(history.commit_oid));
    try testing.expect(try dest.odb.exists(history.tree_oid));
    try testing.expect(try dest.odb.exists(history.blob_oid));
    const resolved = try dest.refs.resolve("refs/remotes/origin/main", null);
    try testing.expect(resolved.eql(history.commit_oid));
}

test "fetchLocal fetches from a source whose .git is a file naming a gitdir, as a linked worktree has" {
    const gpa = testing.allocator;
    const io = testing.io;
    var source_tmp = testing.tmpDir(.{ .iterate = true });
    defer source_tmp.cleanup();
    var source = try openLinkedWorktreeTestRepo(gpa, io, source_tmp.dir);
    defer source.deinit();
    const history = try buildSourceHistory(gpa, &source);

    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    var wt = try source_tmp.dir.openDir(io, "wt", .{ .iterate = true });
    defer wt.close(io);
    const source_path = try realPathOf(gpa, io, wt);
    defer gpa.free(source_path);

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var result = try fetchLocal(gpa, io, &dest, source_path, .{ .refspecs = &rs }, null);
    defer result.deinit(gpa);

    try testing.expect(try dest.odb.exists(history.commit_oid));
    const resolved = try dest.refs.resolve("refs/remotes/origin/main", null);
    try testing.expect(resolved.eql(history.commit_oid));
}

// Regression test for the bug `openSourceRepo`'s doc comment describes: an
// empty directory used to resolve upward through `discover`'s own walk and
// silently "fetch from" whatever `.git` an ancestor happened to carry.
test "fetchLocal refuses a source with no .git of its own rather than resolving upward to an ancestor's .git" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "outer/.git");
    try tmp.dir.createDirPath(io, "outer/inner");

    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    var inner = try tmp.dir.openDir(io, "outer/inner", .{ .iterate = true });
    defer inner.close(io);
    const source_path = try realPathOf(gpa, io, inner);
    defer gpa.free(source_path);

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    try testing.expectError(error.NotFound, fetchLocal(gpa, io, &dest, source_path, .{ .refspecs = &rs }, null));
}

test "fetchLocal on a source path that does not exist at all is NotFound" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    const tmp_path = try realPathOf(gpa, io, tmp.dir);
    defer gpa.free(tmp_path);
    const source_path = try std.fmt.allocPrint(gpa, "{s}/does-not-exist", .{tmp_path});
    defer gpa.free(source_path);

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    try testing.expectError(error.NotFound, fetchLocal(gpa, io, &dest, source_path, .{ .refspecs = &rs }, null));
}

test "fetchLocal on a source it cannot open for a reason other than absence reports an accurate error" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "no-access");

    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    const tmp_path = try realPathOf(gpa, io, tmp.dir);
    defer gpa.free(tmp_path);
    const source_path = try std.fmt.allocPrint(gpa, "{s}/no-access", .{tmp_path});
    defer gpa.free(source_path);

    try tmp.dir.setFilePermissions(io, "no-access", @enumFromInt(0), .{});

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    var diag: ?Diagnostic = null;
    const result = fetchLocal(gpa, io, &dest, source_path, .{ .refspecs = &rs }, &diag);

    // Restored before any assertion below can fail the test: leaving this
    // directory unreadable would otherwise make `tmp.cleanup()` itself
    // fail when this test tears down.
    try tmp.dir.setFilePermissions(io, "no-access", @enumFromInt(0o755), .{});

    try testing.expectError(error.IoFailed, result);
    try testing.expect(diag != null);
    if (diag) |*d| d.deinit(gpa);
}

test "fetch refuses an unrecognised url scheme rather than guessing at it" {
    const gpa = testing.allocator;
    const io = testing.io;
    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    try testing.expectError(
        error.UnsupportedProtocol,
        fetch(gpa, io, &dest, "git://example.com/repo.git", .{ .refspecs = &rs }, null),
    );
}

fn dummySshCredentials(ctx: ?*anyopaque, url: []const u8, host: []const u8, allowed: transport_mod.AllowedTypes) ?transport_mod.Credential {
    _ = ctx;
    _ = url;
    _ = host;
    _ = allowed;
    return .none;
}

fn acceptAllHostKeys(ctx: ?*anyopaque, host: []const u8, key_type: []const u8, key: []const u8) bool {
    _ = ctx;
    _ = host;
    _ = key_type;
    _ = key;
    return true;
}

test "fetch refuses an ssh url when FetchOptions carries no ssh verifier" {
    const gpa = testing.allocator;
    const io = testing.io;
    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    try testing.expectError(
        error.SshVerifierRequired,
        fetch(gpa, io, &dest, "ssh://git@example.com/repo.git", .{ .refspecs = &rs }, null),
    );
}

test "fetch dispatches an ssh url to the ssh transport once a verifier is supplied" {
    const gpa = testing.allocator;
    const io = testing.io;
    var dest_tmp = testing.tmpDir(.{ .iterate = true });
    defer dest_tmp.cleanup();
    var dest = try openTestRepo(gpa, io, dest_tmp.dir);
    defer dest.deinit();

    var rs = [_]Refspec{try Refspec.parse(gpa, "+refs/heads/*:refs/remotes/origin/*")};
    defer for (&rs) |*r| r.deinit(gpa);
    // Loopback on a port nothing listens on: a connection refusal proves
    // this reached the ssh transport, not a bare refusal for lacking a
    // verifier and not the local filesystem strategy. A one second bound
    // keeps this test fast regardless of environment.
    try testing.expectError(error.NetworkFailed, fetch(gpa, io, &dest, "ssh://git@127.0.0.1:1/example.git", .{
        .refspecs = &rs,
        .transport = .{ .connect_timeout_ms = 1000, .credentials = dummySshCredentials },
        .ssh = .{ .verifier = acceptAllHostKeys },
    }, null));
}
