//! Revision string resolution and object peeling.
//!
//! `resolve` turns a revision string into an object id, the same way
//! `gitrevisions(7)` disambiguates a short name. `peel` follows an
//! annotated tag to the object kind a caller asked for, unwrapping a
//! commit to its own tree when the caller asked for a tree.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Oid = oid_mod.Oid;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;
const ObjectKind = core_mod.ObjectKind;

const object_mod = @import("ziggit-object");
const Commit = object_mod.Commit;
const Tag = object_mod.Tag;

const odb_mod = @import("ziggit-odb");
const Odb = odb_mod.Odb;

const refs_mod = @import("ziggit-refs");
const Store = refs_mod.Store;

const repo_mod = @import("ziggit-repo");
const Repository = repo_mod.Repository;

pub const Error = error{ UnknownRevision, AmbiguousPrefix, NotThatKind } || Odb.Error || Store.Error;

/// Allocation budget for reading one tag or commit object whole, while
/// peeling. Both comfortably fit; this is a policy ceiling against a
/// hostile object, not a spec limit.
const max_peel_object_len: usize = 1 << 20;

/// How many tags `peel` follows before refusing. A real tag chain is one
/// or two hops; this leaves headroom without following a corrupt cycle
/// forever.
const max_peel_depth: usize = 10;

/// Resolves a revision string: a full or abbreviated object id, a ref
/// name, or a short name under `refs/`, `refs/tags/`, `refs/heads/`,
/// `refs/remotes/` or `refs/remotes/<name>/HEAD`, tried in git's own
/// order (`gitrevisions(7)`): a full object id first, then an exact ref
/// name, then those short forms in that order, then an abbreviated
/// object id last. Trying the short forms before the abbreviated id is
/// what makes a ref win when both match the same string; trying
/// `refs/tags/` before `refs/heads/` is what makes a tag win over a
/// branch of the same name.
pub fn resolve(gpa: Allocator, repo: *Repository, rev: []const u8, diag: ?*?Diagnostic) Error!Oid {
    if (Oid.parseAny(rev)) |oid| return oid else |_| {}

    if (repo.refs.resolve(rev, diag)) |oid| {
        return oid;
    } else |err| switch (err) {
        error.RefNotFound, error.InvalidRefName => {
            // About to retry `rev` other ways. A diagnostic attached to
            // this attempt would otherwise outlive it unfreed, since
            // nothing reads it once we move on.
            if (diag) |d| {
                if (d.*) |*inner| {
                    inner.deinit(gpa);
                    d.* = null;
                }
            }
        },
        else => return err,
    }

    var buf: [4096]u8 = undefined;
    inline for (.{
        "refs/{s}",
        "refs/tags/{s}",
        "refs/heads/{s}",
        "refs/remotes/{s}",
        "refs/remotes/{s}/HEAD",
    }) |fmt| {
        if (std.fmt.bufPrint(&buf, fmt, .{rev})) |candidate| {
            if (repo.refs.resolve(candidate, null)) |oid| {
                return oid;
            } else |err| switch (err) {
                error.RefNotFound, error.InvalidRefName => {},
                else => return err,
            }
        } else |_| {}
    }

    if (isLowerHex(rev) and rev.len >= 4) {
        return repo.odb.resolvePrefix(rev);
    }

    return error.UnknownRevision;
}

fn isLowerHex(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        switch (c) {
            '0'...'9', 'a'...'f' => {},
            else => return false,
        }
    }
    return true;
}

/// Peels `oid` to an object of `kind`: follows an annotated tag to
/// whatever it names, and unwraps a commit to its own tree when `kind` is
/// `.tree`. Bounded by `max_peel_depth` so a tag pointing at a tag cannot
/// loop forever.
///
/// `oid` itself is always found; peeling is what can fail. An object that
/// is neither `kind` nor something this can peel further towards it is
/// `error.NotThatKind`, never `error.UnknownRevision`: the revision named
/// a real object, it is just the wrong kind. A tag or commit body that
/// fails to parse while peeling, or a chain longer than `max_peel_depth`,
/// is `error.CorruptObject`, kept distinct from both of those since it
/// means the data itself is broken, not merely absent or the wrong shape.
pub fn peel(gpa: Allocator, repo: *Repository, oid: Oid, kind: ObjectKind) Error!Oid {
    var current = oid;
    var depth: usize = 0;
    while (true) {
        const info = try repo.odb.stat(current);
        if (info.kind == kind) return current;

        switch (info.kind) {
            .tag => {
                const bytes = try repo.odb.readAlloc(gpa, current, max_peel_object_len, null);
                defer gpa.free(bytes);
                var tag = Tag.parse(gpa, repo.format, bytes) catch return error.CorruptObject;
                defer tag.deinit(gpa);
                current = tag.object;
            },
            .commit => {
                if (kind != .tree) return error.NotThatKind;
                const bytes = try repo.odb.readAlloc(gpa, current, max_peel_object_len, null);
                defer gpa.free(bytes);
                var commit = Commit.parse(gpa, repo.format, bytes) catch return error.CorruptObject;
                defer commit.deinit(gpa);
                current = commit.tree;
            },
            else => return error.NotThatKind,
        }

        depth += 1;
        if (depth > max_peel_depth) return error.CorruptObject;
    }
}

// Test helpers shared by every test below.

const testing = std.testing;

const dummy_tree_hex = "4" ** 40;
const identity_line = "A U Thor <author@example.com> 1700000000 +0000";

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

fn buildCommitPayload(gpa: Allocator, parent_hex: ?[]const u8, message: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.print("tree {s}\n", .{dummy_tree_hex});
    if (parent_hex) |p| try out.writer.print("parent {s}\n", .{p});
    try out.writer.print("author {s}\n", .{identity_line});
    try out.writer.print("committer {s}\n", .{identity_line});
    try out.writer.print("\n{s}\n", .{message});
    return out.toOwnedSlice();
}

fn buildTagPayload(gpa: Allocator, object_hex: []const u8, kind_name: []const u8, tag_name: []const u8, message: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.print("object {s}\n", .{object_hex});
    try out.writer.print("type {s}\n", .{kind_name});
    try out.writer.print("tag {s}\n", .{tag_name});
    try out.writer.print("tagger {s}\n", .{identity_line});
    try out.writer.print("\n{s}\n", .{message});
    return out.toOwnedSlice();
}

// expected

test "resolve reads a full object id" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const payload = try buildCommitPayload(gpa, null, "one");
    defer gpa.free(payload);
    const oid = try repo.odb.write(.commit, payload, null);

    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const resolved = try resolve(gpa, &repo, oid.toHex(&hex_buf), null);
    try testing.expect(resolved.eql(oid));
}

test "resolve reads an unambiguous abbreviated id" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const payload = try buildCommitPayload(gpa, null, "solo commit");
    defer gpa.free(payload);
    const oid = try repo.odb.write(.commit, payload, null);

    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const hex = oid.toHex(&hex_buf);
    const resolved = try resolve(gpa, &repo, hex[0..8], null);
    try testing.expect(resolved.eql(oid));
}

test "resolve reads a full ref name" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const payload = try buildCommitPayload(gpa, null, "on main");
    defer gpa.free(payload);
    const oid = try repo.odb.write(.commit, payload, null);
    try repo.refs.update("refs/heads/main", oid, null, null, null);

    const resolved = try resolve(gpa, &repo, "refs/heads/main", null);
    try testing.expect(resolved.eql(oid));
}

test "resolve reads a short branch name under refs/heads" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const payload = try buildCommitPayload(gpa, null, "on a topic branch");
    defer gpa.free(payload);
    const oid = try repo.odb.write(.commit, payload, null);
    try repo.refs.update("refs/heads/topic", oid, null, null, null);

    const resolved = try resolve(gpa, &repo, "topic", null);
    try testing.expect(resolved.eql(oid));
}

test "resolve reads a tag name under refs/tags" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const payload = try buildCommitPayload(gpa, null, "tagged");
    defer gpa.free(payload);
    const oid = try repo.odb.write(.commit, payload, null);
    try repo.refs.update("refs/tags/v1", oid, null, null, null);

    const resolved = try resolve(gpa, &repo, "v1", null);
    try testing.expect(resolved.eql(oid));
}

test "resolve of a name shared by a branch and a tag returns the tag" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const branch_payload = try buildCommitPayload(gpa, null, "on the branch");
    defer gpa.free(branch_payload);
    const branch_oid = try repo.odb.write(.commit, branch_payload, null);
    try repo.refs.update("refs/heads/samename", branch_oid, null, null, null);

    const tag_payload = try buildCommitPayload(gpa, null, "at the tag");
    defer gpa.free(tag_payload);
    const tag_oid = try repo.odb.write(.commit, tag_payload, null);
    try repo.refs.update("refs/tags/samename", tag_oid, null, null, null);

    const resolved = try resolve(gpa, &repo, "samename", null);
    try testing.expect(resolved.eql(tag_oid));
    try testing.expect(!resolved.eql(branch_oid));
}

test "resolve of a bare remote name follows refs/remotes/<name>/HEAD" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const payload = try buildCommitPayload(gpa, null, "the remote's default branch");
    defer gpa.free(payload);
    const oid = try repo.odb.write(.commit, payload, null);
    try repo.refs.update("refs/remotes/origin/main", oid, null, null, null);
    try repo.refs.setSymbolic("refs/remotes/origin/HEAD", "refs/remotes/origin/main", null);

    const resolved = try resolve(gpa, &repo, "origin", null);
    try testing.expect(resolved.eql(oid));
}

test "peel follows an annotated tag to its commit" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const commit_payload = try buildCommitPayload(gpa, null, "tagged commit");
    defer gpa.free(commit_payload);
    const commit_oid = try repo.odb.write(.commit, commit_payload, null);

    var commit_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const commit_hex = commit_oid.toHex(&commit_hex_buf);
    const tag_payload = try buildTagPayload(gpa, commit_hex, "commit", "v1.0.0", "Release 1.0.0");
    defer gpa.free(tag_payload);
    const tag_oid = try repo.odb.write(.tag, tag_payload, null);

    const peeled = try peel(gpa, &repo, tag_oid, .commit);
    try testing.expect(peeled.eql(commit_oid));
}

// suspicious

test "peel of a blob to a tree is NotThatKind" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const blob_oid = try repo.odb.write(.blob, "just a blob\n", null);

    try testing.expectError(error.NotThatKind, peel(gpa, &repo, blob_oid, .tree));
}

test "peel of a tag chain that ends at the wrong kind is NotThatKind" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const blob_oid = try repo.odb.write(.blob, "the chain bottoms out here\n", null);

    var blob_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const blob_hex = blob_oid.toHex(&blob_hex_buf);
    const inner_tag_payload = try buildTagPayload(gpa, blob_hex, "blob", "inner", "Points at a blob");
    defer gpa.free(inner_tag_payload);
    const inner_tag_oid = try repo.odb.write(.tag, inner_tag_payload, null);

    var inner_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const inner_hex = inner_tag_oid.toHex(&inner_hex_buf);
    const outer_tag_payload = try buildTagPayload(gpa, inner_hex, "tag", "outer", "Points at the inner tag");
    defer gpa.free(outer_tag_payload);
    const outer_tag_oid = try repo.odb.write(.tag, outer_tag_payload, null);

    // The chain is outer tag -> inner tag -> blob. Asking for a commit
    // walks both tags and finds a blob at the end, never a commit.
    try testing.expectError(error.NotThatKind, peel(gpa, &repo, outer_tag_oid, .commit));
}

test "resolve of an ambiguous prefix is AmbiguousPrefix" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    // Two payloads chosen so their sha1 ids share a leading two bytes,
    // found by search rather than guessed: both start with "9ff9".
    const a = try repo.odb.write(.blob, "payload-101", null);
    const b = try repo.odb.write(.blob, "payload-202", null);
    var a_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    var b_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const a_hex = a.toHex(&a_hex_buf);
    const b_hex = b.toHex(&b_hex_buf);
    try testing.expectEqualStrings(a_hex[0..4], b_hex[0..4]);

    try testing.expectError(error.AmbiguousPrefix, resolve(gpa, &repo, a_hex[0..4], null));
}

test "resolve of a name that matches nothing is UnknownRevision" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    try testing.expectError(error.UnknownRevision, resolve(gpa, &repo, "no-such-branch", null));
}

test "resolve prefers a ref over an abbreviated id when both match" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try openTestRepo(gpa, io, tmp.dir);
    defer repo.deinit();

    const blob_oid = try repo.odb.write(.blob, "abbreviation source", null);
    var blob_hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const blob_hex = blob_oid.toHex(&blob_hex_buf);
    var abbreviation_buf: [8]u8 = undefined;
    @memcpy(&abbreviation_buf, blob_hex[0..8]);
    const abbreviation: []const u8 = &abbreviation_buf;

    const commit_payload = try buildCommitPayload(gpa, null, "the ref's own target");
    defer gpa.free(commit_payload);
    const commit_oid = try repo.odb.write(.commit, commit_payload, null);

    const ref_name = try std.fmt.allocPrint(gpa, "refs/heads/{s}", .{abbreviation});
    defer gpa.free(ref_name);
    try repo.refs.update(ref_name, commit_oid, null, null, null);

    const resolved = try resolve(gpa, &repo, abbreviation, null);
    try testing.expect(resolved.eql(commit_oid));
    try testing.expect(!resolved.eql(blob_oid));
}
