//! The plumbing CLI. Its whole purpose is comparing ziggit's output
//! against real git, by hand, on a real repository, so every subcommand
//! writes the exact bytes git would write and nothing else.
//!
//! This is the one place in the project allowed to print: it is not a
//! library module, so it does not route detail through a `Diagnostic`
//! for its own sake, only to read the detail a library module already
//! attached to a fault and put that detail on stderr.

const std = @import("std");
const Allocator = std.mem.Allocator;

const ziggit = @import("ziggit");
const Oid = ziggit.Oid;
const ObjectKind = ziggit.ObjectKind;
const FileMode = ziggit.FileMode;
const Diagnostic = ziggit.Diagnostic;
const Repository = ziggit.Repository;
const Tree = ziggit.Tree;

// `ls-remote`'s network path speaks protocol v2 directly, one command
// (`capabilities`, then `ls-refs`) rather than a whole fetch: nothing the
// front package promises a consumer covers that, so this reaches past it
// the same way `Http`/`Ssh` themselves do internally. `ziggit-pktline`
// supplies only the scratch buffer size `ziggit-proto`'s readers need.
const proto = @import("ziggit-proto");
const pktline = @import("ziggit-pktline");

/// A commit, tag, or tree this CLI reads whole rather than streamed. Real
/// ones are kilobytes; this is a defensive ceiling against a hostile or
/// corrupt object, not a spec limit.
const max_small_object: usize = 64 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    const stdout = &stdout_writer.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(arena);

    run(gpa, io, args[1..], stdout, stderr) catch {
        // We are already exiting non-zero. A flush failure here would
        // not change that outcome, and there is no lower path left to
        // report it on, so we drop it on purpose.
        stdout.flush() catch {};
        // Same reasoning as the flush above: nothing left to tell.
        stderr.flush() catch {};
        std.process.exit(1);
    };

    try stdout.flush();
    try stderr.flush();
}

/// Subcommands this CLI dispatches. Checked before repository discovery so
/// a typo is reported as an unknown subcommand, not masked by a repository
/// error that has nothing to do with what the user typed.
const known_commands = [_][]const u8{ "cat-file", "init", "ls-tree", "ls-remote", "rev-parse", "show-ref" };

fn isKnownCommand(cmd: []const u8) bool {
    for (known_commands) |k| {
        if (std.mem.eql(u8, cmd, k)) return true;
    }
    return false;
}

fn run(gpa: Allocator, io: std.Io, args: []const [:0]const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (args.len == 0) {
        try stderr.writeAll("usage: ziggit <cat-file|ls-tree|ls-remote|rev-parse|show-ref> ...\n");
        return error.UsageError;
    }

    const cmd = args[0];
    if (!isKnownCommand(cmd)) {
        try stderr.print("ziggit: unknown subcommand '{s}'\n", .{cmd});
        return error.UsageError;
    }

    // `ls-remote` names its own repository as an argument; it has no
    // business with whatever repository the CLI happens to be run from,
    // unlike every other subcommand here.
    if (std.mem.eql(u8, cmd, "ls-remote")) {
        return lsRemote(gpa, io, args[1..], stdout, stderr);
    }

    // `init` CREATES the repository, so it must run before discovery
    // rather than inside it: discovery of a repository that is not there
    // yet is exactly the case this subcommand exists to fix.
    if (std.mem.eql(u8, cmd, "init")) {
        return initCmd(gpa, io, args[1..], stdout, stderr);
    }

    var cwd = std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true }) catch |err| {
        try stderr.print("ziggit: cannot open the current directory: {s}\n", .{@errorName(err)});
        return err;
    };
    defer cwd.close(io);

    var discover_diag: ?Diagnostic = null;
    var layout = ziggit.discover(gpa, io, cwd, .{}, &discover_diag) catch |err| {
        try reportDiag(gpa, stderr, "fatal: not a git repository", err, &discover_diag, null);
        return err;
    };

    var open_diag: ?Diagnostic = null;
    var repo = Repository.open(gpa, io, layout, .{}, &open_diag) catch |err| {
        // `Repository.open` never takes ownership of `layout` on failure:
        // it stays ours to close.
        layout.deinit(io);
        try reportDiag(gpa, stderr, "could not open repository", err, &open_diag, null);
        return err;
    };
    defer repo.deinit();

    const rest = args[1..];
    if (std.mem.eql(u8, cmd, "cat-file")) {
        try catFile(gpa, &repo, rest, stdout, stderr);
    } else if (std.mem.eql(u8, cmd, "ls-tree")) {
        try lsTree(gpa, &repo, rest, stdout, stderr);
    } else if (std.mem.eql(u8, cmd, "rev-parse")) {
        try revParseCmd(gpa, &repo, rest, stdout, stderr);
    } else if (std.mem.eql(u8, cmd, "show-ref")) {
        try showRef(gpa, &repo, rest, stdout, stderr);
    } else {
        // isKnownCommand already accepted cmd above, so every name it
        // allows is handled here.
        unreachable;
    }
}

/// Writes `ziggit: <context>: <error name>[: <path>][: <detail>]\n` to
/// `stderr`, draining whatever `diag` holds so a failure names which file
/// or object was bad instead of just the error's name. Frees `diag`'s
/// owned strings, since nothing else will.
///
/// Some lookups this CLI makes (`Odb.stat`, `Odb.resolvePrefix`, an
/// unknown revision) have no `Diagnostic` to attach a name to. When `diag`
/// ends up with nothing to print, `fallback`, the revision or object id
/// the caller already had in hand, is printed in its place. Pass `null`
/// when there is no such string, or the diagnostic is always expected to
/// carry one.
fn reportDiag(gpa: Allocator, stderr: *std.Io.Writer, context: []const u8, err: anyerror, diag: *?Diagnostic, fallback: ?[]const u8) !void {
    try stderr.print("ziggit: {s}: {s}", .{ context, @errorName(err) });
    var named = false;
    if (diag.*) |*d| {
        if (d.path) |p| {
            try stderr.print(": {s}", .{p});
            named = true;
        }
        if (d.detail) |dt| {
            try stderr.print(": {s}", .{dt});
            named = true;
        }
        d.deinit(gpa);
        diag.* = null;
    }
    if (!named) {
        if (fallback) |f| try stderr.print(": {s}", .{f});
    }
    try stderr.writeAll("\n");
}

/// Resolves `rev` to a tree: `ziggit.resolve` finds the object,
/// then `peel` follows a commit to its own tree or an annotated tag to
/// whatever it names, same as `git ls-tree` accepting any tree-ish.
fn resolveTreeish(gpa: Allocator, repo: *Repository, rev: []const u8, diag: *?Diagnostic) !Oid {
    const oid = try ziggit.resolve(gpa, repo, rev, diag);
    return ziggit.peel(gpa, repo, oid, .tree);
}

fn catFile(gpa: Allocator, repo: *Repository, args: []const [:0]const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (args.len != 2) {
        try stderr.writeAll("usage: ziggit cat-file (-t|-s|-p) <object>\n");
        return error.UsageError;
    }
    const mode = args[0];
    const rev = args[1];

    var diag: ?Diagnostic = null;
    const oid = ziggit.resolve(gpa, repo, rev, &diag) catch |err| {
        try reportDiag(gpa, stderr, "cat-file", err, &diag, rev);
        return err;
    };

    if (std.mem.eql(u8, mode, "-t")) {
        // `Odb.stat` has no `Diagnostic` of its own, so `rev`, the string
        // the user actually typed, is the only way this failure can name
        // the object that was missing.
        const info = repo.odb.stat(oid) catch |err| {
            try stderr.print("ziggit: cat-file: {s}: {s}\n", .{ @errorName(err), rev });
            return err;
        };
        try stdout.print("{s}\n", .{info.kind.name()});
        return;
    }

    if (std.mem.eql(u8, mode, "-s")) {
        const info = repo.odb.stat(oid) catch |err| {
            try stderr.print("ziggit: cat-file: {s}: {s}\n", .{ @errorName(err), rev });
            return err;
        };
        try stdout.print("{d}\n", .{info.size});
        return;
    }

    if (std.mem.eql(u8, mode, "-p")) {
        const info = repo.odb.stat(oid) catch |err| {
            try stderr.print("ziggit: cat-file: {s}: {s}\n", .{ @errorName(err), rev });
            return err;
        };
        if (info.kind == .tree) {
            printTreeEntries(gpa, repo, oid, stdout, &diag) catch |err| {
                try reportDiag(gpa, stderr, "cat-file", err, &diag, rev);
                return err;
            };
        } else {
            // A blob, commit, or tag: real git's `-p` output on any of
            // these is exactly the object's own payload, so this streams
            // it straight through rather than re-serializing a parsed
            // form that could drift from what `parse` actually read.
            _ = repo.odb.read(oid, stdout, &diag) catch |err| {
                try reportDiag(gpa, stderr, "cat-file", err, &diag, rev);
                return err;
            };
        }
        return;
    }

    try stderr.print("ziggit: unknown cat-file mode '{s}'\n", .{mode});
    return error.UsageError;
}

/// Prints one tree's entries the way `git ls-tree`/`git cat-file -p`
/// print a tree: `<mode> <kind> <oid>\t<name>`, mode zero padded to six
/// octal digits. This padding is display only: the tree object itself
/// stores a mode with no leading zero, which is what `Tree.write` emits.
fn printTreeEntries(gpa: Allocator, repo: *Repository, tree_oid: Oid, stdout: *std.Io.Writer, diag: *?Diagnostic) !void {
    const bytes = try repo.odb.readAlloc(gpa, tree_oid, max_small_object, diag);
    defer gpa.free(bytes);
    var tree = try Tree.parse(gpa, repo.format, bytes);
    defer tree.deinit(gpa);

    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    for (tree.entries) |entry| {
        try stdout.print("{o:0>6} {s} {s}\t", .{ @intFromEnum(entry.mode), modeKind(entry.mode), entry.oid.toHex(&hex_buf) });
        try stdout.writeAll(entry.name);
        try stdout.writeByte('\n');
    }
}

fn modeKind(mode: FileMode) []const u8 {
    return switch (mode) {
        .tree => "tree",
        .gitlink => "commit",
        .blob, .blob_executable, .symlink => "blob",
    };
}

fn lsTree(gpa: Allocator, repo: *Repository, args: []const [:0]const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    var recursive = false;
    var tree_ish: ?[]const u8 = null;
    for (args) |a| {
        if (std.mem.eql(u8, a, "-r")) {
            recursive = true;
        } else if (tree_ish == null) {
            tree_ish = a;
        } else {
            try stderr.writeAll("usage: ziggit ls-tree [-r] <tree-ish>\n");
            return error.UsageError;
        }
    }
    const rev = tree_ish orelse {
        try stderr.writeAll("usage: ziggit ls-tree [-r] <tree-ish>\n");
        return error.UsageError;
    };

    var diag: ?Diagnostic = null;
    const tree_oid = resolveTreeish(gpa, repo, rev, &diag) catch |err| {
        try reportDiag(gpa, stderr, "ls-tree", err, &diag, rev);
        return err;
    };

    lsTreeWalk(gpa, repo, tree_oid, "", recursive, stdout, &diag) catch |err| {
        try reportDiag(gpa, stderr, "ls-tree", err, &diag, rev);
        return err;
    };
}

/// Walks one tree, recursing into a subtree's entries in place of printing
/// the subtree itself when `recursive` is set, exactly as `git ls-tree -r`
/// does. A gitlink is never recursed into, since it names a commit in a
/// different repository, not a tree in this one.
fn lsTreeWalk(gpa: Allocator, repo: *Repository, tree_oid: Oid, prefix: []const u8, recursive: bool, stdout: *std.Io.Writer, diag: *?Diagnostic) !void {
    const bytes = try repo.odb.readAlloc(gpa, tree_oid, max_small_object, diag);
    defer gpa.free(bytes);
    var tree = try Tree.parse(gpa, repo.format, bytes);
    defer tree.deinit(gpa);

    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    for (tree.entries) |entry| {
        const full_name = if (prefix.len == 0)
            try gpa.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, entry.name });
        defer gpa.free(full_name);

        if (recursive and entry.mode == .tree) {
            try lsTreeWalk(gpa, repo, entry.oid, full_name, recursive, stdout, diag);
            continue;
        }

        try stdout.print("{o:0>6} {s} {s}\t", .{ @intFromEnum(entry.mode), modeKind(entry.mode), entry.oid.toHex(&hex_buf) });
        try stdout.writeAll(full_name);
        try stdout.writeByte('\n');
    }
}

fn revParseCmd(gpa: Allocator, repo: *Repository, args: []const [:0]const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (args.len != 1) {
        try stderr.writeAll("usage: ziggit rev-parse <rev>\n");
        return error.UsageError;
    }

    var diag: ?Diagnostic = null;
    const oid = ziggit.resolve(gpa, repo, args[0], &diag) catch |err| {
        try reportDiag(gpa, stderr, "rev-parse", err, &diag, args[0]);
        return err;
    };

    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    try stdout.print("{s}\n", .{oid.toHex(&hex_buf)});
}

/// Prints `<oid> <refname>` for every ref under `refs/`, sorted by name,
/// the way `git show-ref` does by default: `HEAD` itself is never
/// included, and a symbolic ref (`refs/remotes/<x>/HEAD`) is dereferenced
/// down to the object id it ultimately names.
fn showRef(gpa: Allocator, repo: *Repository, args: []const [:0]const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (args.len != 0) {
        try stderr.writeAll("usage: ziggit show-ref\n");
        return error.UsageError;
    }

    var it = repo.refs.iterate("") catch |err| {
        try stderr.print("ziggit: show-ref: {s}\n", .{@errorName(err)});
        return err;
    };
    defer it.deinit(gpa);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| gpa.free(n);
        names.deinit(gpa);
    }
    while (it.next()) |ref| {
        var owned = ref;
        defer owned.deinit(gpa);
        const name = try gpa.dupe(u8, owned.name);
        names.append(gpa, name) catch |err| {
            gpa.free(name);
            return err;
        };
    }

    std.mem.sort([]u8, names.items, {}, lessThanBytes);

    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    for (names.items) |name| {
        var diag: ?Diagnostic = null;
        const oid = repo.refs.resolve(name, &diag) catch |err| {
            try reportDiag(gpa, stderr, "show-ref", err, &diag, name);
            return err;
        };
        try stdout.print("{s} {s}\n", .{ oid.toHex(&hex_buf), name });
    }
}

fn lessThanBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// One ref this CLI read back, whether from a local repository or over
/// the wire: a name and the object id it currently names. Owned; `name`
/// is freed by `deinit`.
const RemoteRef = struct {
    name: []const u8,
    oid: Oid,

    fn deinit(r: *RemoteRef, gpa: Allocator) void {
        gpa.free(r.name);
        r.* = undefined;
    }
};

fn lessThanRemoteRef(_: void, a: RemoteRef, b: RemoteRef) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Prints `<oid>\t<refname>` for every ref `url` advertises, sorted by
/// name, the way `git ls-remote` does. `url` is a whole repository
/// location, not a work tree to search upward from, so this never touches
/// whatever repository the CLI happens to be run inside.
fn lsRemote(gpa: Allocator, io: std.Io, args: []const [:0]const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    if (args.len != 1) {
        try stderr.writeAll("usage: ziggit ls-remote <url>\n");
        return error.UsageError;
    }
    const url = args[0];

    var diag: ?Diagnostic = null;
    const refs = remoteRefs(gpa, io, url, &diag) catch |err| {
        try reportDiag(gpa, stderr, "ls-remote", err, &diag, url);
        return err;
    };
    defer {
        for (refs) |*r| {
            var mutable = r.*;
            mutable.deinit(gpa);
        }
        gpa.free(refs);
    }

    std.mem.sort(RemoteRef, refs, {}, lessThanRemoteRef);

    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    for (refs) |r| {
        try stdout.print("{s}\t{s}\n", .{ r.oid.toHex(&hex_buf), r.name });
    }
}

/// A url with no `scheme://` prefix, or an explicit `file://` one, names a
/// path on this filesystem. Anything else names a scheme this CLI dials
/// out over. Mirrors `ziggit-fetch`'s own url classification, which is
/// not part of the front package's surface: a CLI subcommand deciding how
/// to dial a url is exactly the kind of policy the library leaves to its
/// caller.
const UrlKind = union(enum) {
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

fn remoteRefs(gpa: Allocator, io: std.Io, url: []const u8, diag: *?Diagnostic) ![]RemoteRef {
    return switch (classifyUrl(url)) {
        .local => |path| localRefs(gpa, io, path, diag),
        .http, .https => blk: {
            var http = try ziggit.Http.open(gpa, io, url, .{});
            defer http.deinit();
            break :blk transportRefs(gpa, http.transport(), diag);
        },
        // `Ssh.open` requires a host key verifier and this CLI has no
        // policy of its own for trusting one, the same reason
        // `ziggit-fetch`'s own dispatch refuses `ssh://` with no
        // `FetchOptions.ssh` supplied: inventing a default here would
        // mean silently trusting, or silently refusing, every host key
        // alike.
        .ssh => error.SshVerifierRequired,
        .unknown => error.UnsupportedProtocol,
    };
}

/// Allocation budget for reading one tag object whole while peeling.
/// Matches `ziggit-revwalk`'s own ceiling: a hostile or corrupt tag past
/// this is refused, not read.
const max_tag_object_len: usize = 1 << 20;

/// How many annotated tags in a row `peelTagChain` follows before
/// refusing, matching `ziggit-revwalk`'s own bound against a corrupt
/// cycle of tags pointing at tags.
const max_peel_depth: usize = 10;

/// Appends `name`/`oid` to `out`, and, when `peeled` is non-null, a
/// second entry right behind it named `<name>^{}` holding `peeled` --
/// the same trailing line real `git ls-remote` prints for a ref that
/// names an annotated tag. `name` is only ever borrowed here: both call
/// sites below still own whatever they passed in once this returns.
fn appendRefWithPeel(gpa: Allocator, out: *std.ArrayList(RemoteRef), name: []const u8, oid: Oid, peeled: ?Oid) !void {
    const owned_name = try gpa.dupe(u8, name);
    errdefer gpa.free(owned_name);
    try out.append(gpa, .{ .name = owned_name, .oid = oid });

    if (peeled) |peeled_oid| {
        const peeled_name = try std.fmt.allocPrint(gpa, "{s}^{{}}", .{name});
        errdefer gpa.free(peeled_name);
        try out.append(gpa, .{ .name = peeled_name, .oid = peeled_oid });
    }
}

/// Follows `oid` through a chain of annotated tag objects to the first
/// non-tag object it eventually names. Returns `null` when `oid` does
/// not name a tag at all, which is the common case: most refs point
/// straight at a commit.
fn peelTagChain(gpa: Allocator, repo: *Repository, oid: Oid, diag: *?Diagnostic) !?Oid {
    var current = oid;
    var peeled: ?Oid = null;
    var depth: usize = 0;
    while (true) {
        const info = try repo.odb.stat(current);
        if (info.kind != .tag) break;
        if (depth >= max_peel_depth) return error.CorruptObject;
        depth += 1;

        const bytes = try repo.odb.readAlloc(gpa, current, max_tag_object_len, diag);
        defer gpa.free(bytes);
        const tag = try ziggit.Tag.parse(gpa, repo.format, bytes);
        current = tag.object;
        peeled = current;
    }
    return peeled;
}

/// Lists every ref in the repository at `path`, `HEAD` included, the way
/// `git ls-remote` does for a local path: `HEAD` is dereferenced to the
/// object id it currently names, and skipped entirely on an unborn
/// repository with no commit for it to name yet. An annotated tag gets a
/// trailing `<name>^{}` entry, same as every other ref that names one.
fn localRefs(gpa: Allocator, io: std.Io, path: []const u8, diag: *?Diagnostic) ![]RemoteRef {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var layout = try ziggit.discover(gpa, io, dir, .{}, diag);
    var repo = Repository.open(gpa, io, layout, .{}, diag) catch |err| {
        layout.deinit(io);
        return err;
    };
    defer repo.deinit();

    var out: std.ArrayList(RemoteRef) = .empty;
    errdefer {
        for (out.items) |*r| r.deinit(gpa);
        out.deinit(gpa);
    }

    if (ziggit.resolve(gpa, &repo, "HEAD", diag)) |head_oid| {
        const peeled = try peelTagChain(gpa, &repo, head_oid, diag);
        try appendRefWithPeel(gpa, &out, "HEAD", head_oid, peeled);
    } else |err| switch (err) {
        error.UnknownRevision, error.RefNotFound => {},
        else => return err,
    }

    var it = try repo.refs.iterate("");
    defer it.deinit(gpa);
    while (it.next()) |ref| {
        var owned = ref;
        defer owned.deinit(gpa);
        const oid = try repo.refs.resolve(owned.name, diag);
        const peeled = try peelTagChain(gpa, &repo, oid, diag);
        try appendRefWithPeel(gpa, &out, owned.name, oid, peeled);
    }

    return out.toOwnedSlice(gpa);
}

/// Lists every ref `t` advertises, over protocol v2's `ls-refs` command:
/// the same capability check, request, and response `ziggit-fetch`'s own
/// negotiation makes before ever asking for a packfile, and nothing past
/// it -- no `fetch` command runs, and no object crosses the wire. Asks
/// the server to peel tags itself (`LsRefsOptions.peel`), the way real
/// `git ls-remote` does, rather than fetching each tag object back to
/// peel it locally.
fn transportRefs(gpa: Allocator, t: ziggit.Transport, diag: *?Diagnostic) ![]RemoteRef {
    var caps = try t.capabilities(gpa, diag);
    defer caps.deinit(gpa);
    if (!caps.isV2()) return error.UnsupportedProtocol;

    const format: ziggit.Format = if (caps.get("object-format")) |v|
        (if (std.mem.eql(u8, v, "sha256")) .sha256 else .sha1)
    else
        .sha1;

    var body_w: std.Io.Writer.Allocating = .init(gpa);
    defer body_w.deinit();
    proto.writeLsRefs(&body_w.writer, format, .{ .symrefs = true, .peel = true }) catch return error.ProtocolError;

    var reader_ptr: *std.Io.Reader = undefined;
    try t.command(gpa, .{ .name = "ls-refs", .body = body_w.written() }, &reader_ptr, diag);

    var pkt_buf: [pktline.Packet.max_data_length]u8 = undefined;
    const lines = try proto.readLsRefs(gpa, format, reader_ptr, &pkt_buf);
    defer {
        for (lines) |*l| {
            var mutable = l.*;
            mutable.deinit(gpa);
        }
        gpa.free(lines);
    }

    var out: std.ArrayList(RemoteRef) = .empty;
    errdefer {
        for (out.items) |*r| r.deinit(gpa);
        out.deinit(gpa);
    }
    for (lines) |line| {
        try appendRefWithPeel(gpa, &out, line.name, line.oid, line.peeled);
    }

    return out.toOwnedSlice(gpa);
}

/// `ziggit init [<directory>]`, matching `git init`'s one-line output.
///
/// Git also prints a hint block about the default branch name when
/// `init.defaultBranch` is not configured. That block is advice about a
/// future git release, not a statement about the repository, and its
/// wording changes between versions, so it is not reproduced. The line
/// below is what git prints once that hint is silenced.
fn initCmd(
    gpa: Allocator,
    io: std.Io,
    args: []const [:0]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !void {
    if (args.len > 1) {
        try stderr.writeAll("usage: ziggit init [<directory>]\n");
        return error.UsageError;
    }

    const target = if (args.len == 1) args[0] else ".";

    var cwd = std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true }) catch |err| {
        try stderr.print("ziggit: cannot open the current directory: {s}\n", .{@errorName(err)});
        return err;
    };
    defer cwd.close(io);

    if (args.len == 1) {
        cwd.createDirPath(io, target) catch |err| {
            try stderr.print("ziggit: cannot create '{s}': {s}\n", .{ target, @errorName(err) });
            return err;
        };
    }

    var dir = cwd.openDir(io, target, .{ .iterate = true }) catch |err| {
        try stderr.print("ziggit: cannot open '{s}': {s}\n", .{ target, @errorName(err) });
        return err;
    };
    defer dir.close(io);

    Repository.init(gpa, io, dir, .{}) catch |err| {
        try stderr.print("ziggit: cannot initialise a repository: {s}\n", .{@errorName(err)});
        return err;
    };

    // Git prints the absolute path of the git directory, with a trailing
    // separator.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = dir.realPath(io, &path_buf) catch |err| {
        try stderr.print("ziggit: cannot resolve '{s}': {s}\n", .{ target, @errorName(err) });
        return err;
    };
    try stdout.print("Initialized empty Git repository in {s}/.git/\n", .{path_buf[0..len]});
}
