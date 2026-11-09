//! Merging two commits, including the virtual base a criss-cross history
//! needs.
//!
//! `mergeTrees` takes only an object database, since a tree merge needs no
//! graph. Finding the base does need one, so this is where `Repository`
//! enters.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Oid = oid_mod.Oid;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;

const repo_mod = @import("ziggit-repo");
const Repository = repo_mod.Repository;

const revwalk_mod = @import("ziggit-revwalk");

const merge_trees_mod = @import("merge_trees.zig");
const write_tree_mod = @import("write_tree.zig");
const Options = merge_trees_mod.Options;
const Result = merge_trees_mod.Result;

pub const Error = error{
    /// The two commits share no ancestor. Git refuses this outright:
    /// "fatal: refusing to merge unrelated histories".
    UnrelatedHistories,
} || merge_trees_mod.Error || write_tree_mod.Error || revwalk_mod.Error;

/// Merges `theirs` into `ours`, finding the base itself.
///
/// With several merge bases, which is what a criss-cross history gives,
/// the bases are folded into one virtual base: each is merged into the
/// running base and the result written as a tree. A conflict inside a
/// virtual base is not a failure. The tree is written with markers in it
/// and the fold goes on, which is what lets the recursion terminate, and
/// it is what libgit2 does under `GIT_MERGE_VIRTUAL_BASE`.
pub fn mergeCommits(
    gpa: Allocator,
    repo: *Repository,
    ours: Oid,
    theirs: Oid,
    options: Options,
    diag: ?*?Diagnostic,
) Error!Result {
    const bases = try revwalk_mod.mergeBases(gpa, repo, ours, theirs, diag);
    defer gpa.free(bases);

    if (bases.len == 0) return error.UnrelatedHistories;

    const our_tree = try revwalk_mod.peel(gpa, repo, ours, .tree);
    const their_tree = try revwalk_mod.peel(gpa, repo, theirs, .tree);

    const base_tree = try foldBases(gpa, repo, bases, options, diag);
    return merge_trees_mod.mergeTrees(gpa, &repo.odb, base_tree, our_tree, their_tree, options, diag);
}

/// The one tree to use as the base. With a single merge base that is its
/// own tree; with several it is the fold described on `mergeCommits`.
///
/// Each step merges two base COMMITS through `mergeCommits`, so the step
/// finds its own base and the merge really is recursive. Folding the base
/// trees directly against a null base instead treats everything both bases
/// hold as an add against an add, which fills the virtual base with
/// conflict markers and then conflicts the real merge against that.
fn foldBases(
    gpa: Allocator,
    repo: *Repository,
    bases: []const Oid,
    options: Options,
    diag: ?*?Diagnostic,
) Error!Oid {
    if (bases.len == 1) return revwalk_mod.peel(gpa, repo, bases[0], .tree);

    var acc = bases[0];
    var folded: usize = 0;
    for (bases[1..]) |base| {
        // Reaching the limit uses the next ancestor as it is rather than
        // merging it, which is what libgit2 documents for
        // `recursion_limit`.
        if (options.recursion_limit) |limit| {
            if (folded >= limit) break;
        }

        var result = try mergeCommits(gpa, repo, acc, base, options, diag);
        defer result.deinit(gpa);
        const tree = try write_tree_mod.writeTree(gpa, &repo.odb, result, diag);

        // A real commit object, with both bases as parents, so the next
        // step can still walk the graph. libgit2 builds the same virtual
        // commit for this. A conflict inside it is not a failure: the tree
        // is written with markers and the fold goes on.
        acc = try writeVirtualCommit(gpa, repo, tree, &.{ acc, base });
        folded += 1;
    }
    return revwalk_mod.peel(gpa, repo, acc, .tree);
}

/// Writes a commit holding `tree` with `parents`, used only as a virtual
/// merge base. Nothing references it, the same as the objects git leaves
/// behind for its own recursive merges.
fn writeVirtualCommit(gpa: Allocator, repo: *Repository, tree: Oid, parents: []const Oid) Error!Oid {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var hex: [Oid.max_formatted_length]u8 = undefined;
    out.writer.print("tree {s}\n", .{tree.toHex(&hex)}) catch return error.OutOfMemory;
    for (parents) |p| {
        var phex: [Oid.max_formatted_length]u8 = undefined;
        out.writer.print("parent {s}\n", .{p.toHex(&phex)}) catch return error.OutOfMemory;
    }
    out.writer.writeAll(
        "author ziggit <ziggit@localhost> 0 +0000\n" ++
            "committer ziggit <ziggit@localhost> 0 +0000\n" ++
            "\nvirtual merge base\n",
    ) catch return error.OutOfMemory;
    return repo.odb.write(.commit, out.written(), null);
}

const testing = std.testing;

const Fixture = struct {
    tmp: testing.TmpDir,
    repo: Repository,

    fn init(gpa: Allocator, io: std.Io) !Fixture {
        var tmp = testing.tmpDir(.{ .iterate = true });
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "objects/pack");
        try tmp.dir.createDirPath(io, "refs/heads");
        try tmp.dir.writeFile(io, .{ .sub_path = "HEAD", .data = "ref: refs/heads/main\n" });
        const layout = try repo_mod.discover(gpa, io, tmp.dir, .{}, null);
        const repo = try Repository.open(gpa, io, layout, .{}, null);
        return .{ .tmp = tmp, .repo = repo };
    }

    fn deinit(fx: *Fixture) void {
        fx.repo.deinit();
        fx.tmp.cleanup();
    }

    fn blob(fx: *Fixture, content: []const u8) !Oid {
        return fx.repo.odb.write(.blob, content, null);
    }

    fn tree(fx: *Fixture, gpa: Allocator, entries: []Tree.Entry) !Oid {
        Tree.sortEntries(entries);
        var aw = try std.Io.Writer.Allocating.initCapacity(gpa, 256);
        defer aw.deinit();
        const t: Tree = .{ .entries = entries };
        try t.write(&aw.writer);
        return fx.repo.odb.write(.tree, aw.writer.buffered(), null);
    }

    /// A commit with a real tree, unlike the dummy-tree fixtures in
    /// `ziggit-revwalk`: a merge has to read the tree, not just the graph.
    fn commit(fx: *Fixture, gpa: Allocator, tree_oid: Oid, parents: []const Oid, when: i64) !Oid {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        var hex: [Oid.max_formatted_length]u8 = undefined;
        try out.writer.print("tree {s}\n", .{tree_oid.toHex(&hex)});
        for (parents) |p| {
            var phex: [Oid.max_formatted_length]u8 = undefined;
            try out.writer.print("parent {s}\n", .{p.toHex(&phex)});
        }
        try out.writer.print("author A U Thor <a@b.c> {d} +0000\n", .{when});
        try out.writer.print("committer A U Thor <a@b.c> {d} +0000\n", .{when});
        try out.writer.writeAll("\nfixture\n");
        return fx.repo.odb.write(.commit, out.written(), null);
    }
};

const Tree = @import("ziggit-object").Tree;

fn resolvedOid(result: Result, path: []const u8) ?Oid {
    for (result.index.entries) |e| {
        if (e.stage == .merged and std.mem.eql(u8, e.path, path)) return e.oid;
    }
    return null;
}

test "one merge base behaves like mergeTrees with that base" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init(gpa, io);
    defer fx.deinit();

    const b1 = try fx.blob("base\n");
    const o1 = try fx.blob("ours\n");

    var base_e = [_]Tree.Entry{.{ .mode = .blob, .name = "a.txt", .oid = b1 }};
    const base_tree = try fx.tree(gpa, &base_e);
    const root = try fx.commit(gpa, base_tree, &.{}, 1000);

    var our_e = [_]Tree.Entry{.{ .mode = .blob, .name = "a.txt", .oid = o1 }};
    const our_tree = try fx.tree(gpa, &our_e);
    const ours = try fx.commit(gpa, our_tree, &.{root}, 2000);
    const theirs = try fx.commit(gpa, base_tree, &.{root}, 2001);

    var result = try mergeCommits(gpa, &fx.repo, ours, theirs, .{}, null);
    defer result.deinit(gpa);
    try testing.expect(!result.hasConflicts());
    try testing.expect(resolvedOid(result, "a.txt").?.eql(o1));
}

test "unrelated histories are refused" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init(gpa, io);
    defer fx.deinit();

    const b1 = try fx.blob("one\n");
    var e1 = [_]Tree.Entry{.{ .mode = .blob, .name = "a.txt", .oid = b1 }};
    const t1 = try fx.tree(gpa, &e1);
    const a = try fx.commit(gpa, t1, &.{}, 1000);

    const b2 = try fx.blob("two\n");
    var e2 = [_]Tree.Entry{.{ .mode = .blob, .name = "b.txt", .oid = b2 }};
    const t2 = try fx.tree(gpa, &e2);
    const b = try fx.commit(gpa, t2, &.{}, 1001);

    try testing.expectError(error.UnrelatedHistories, mergeCommits(gpa, &fx.repo, a, b, .{}, null));
}

/// A criss-cross: root, then A and B off it, then two merges each taking
/// both as parents. `mergeBases` then reports A and B, so the fold runs.
const CrissCross = struct { a2: Oid, b2: Oid, shared: Oid, a_blob: Oid, b_blob: Oid };

fn crissCross(fx: *Fixture, gpa: Allocator) !CrissCross {
    const shared = try fx.blob("shared\n");
    const a_blob = try fx.blob("from A\n");
    const b_blob = try fx.blob("from B\n");

    var root_e = [_]Tree.Entry{.{ .mode = .blob, .name = "shared.txt", .oid = shared }};
    const root_tree = try fx.tree(gpa, &root_e);
    const root = try fx.commit(gpa, root_tree, &.{}, 1000);

    var a_e = [_]Tree.Entry{
        .{ .mode = .blob, .name = "shared.txt", .oid = shared },
        .{ .mode = .blob, .name = "a.txt", .oid = a_blob },
    };
    const a_tree = try fx.tree(gpa, &a_e);
    const a = try fx.commit(gpa, a_tree, &.{root}, 2000);

    var b_e = [_]Tree.Entry{
        .{ .mode = .blob, .name = "shared.txt", .oid = shared },
        .{ .mode = .blob, .name = "b.txt", .oid = b_blob },
    };
    const b_tree = try fx.tree(gpa, &b_e);
    const b = try fx.commit(gpa, b_tree, &.{root}, 2001);

    // Both merges hold everything, so the two sides differ only in history.
    var both_e = [_]Tree.Entry{
        .{ .mode = .blob, .name = "shared.txt", .oid = shared },
        .{ .mode = .blob, .name = "a.txt", .oid = a_blob },
        .{ .mode = .blob, .name = "b.txt", .oid = b_blob },
    };
    const both_tree = try fx.tree(gpa, &both_e);
    const a2 = try fx.commit(gpa, both_tree, &.{ a, b }, 3000);
    const b2 = try fx.commit(gpa, both_tree, &.{ b, a }, 3001);

    return .{ .a2 = a2, .b2 = b2, .shared = shared, .a_blob = a_blob, .b_blob = b_blob };
}

test "two merge bases fold into one virtual base" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init(gpa, io);
    defer fx.deinit();

    const cc = try crissCross(&fx, gpa);

    // Two bases, which is what makes this a criss-cross and the fold run.
    const bases = try revwalk_mod.mergeBases(gpa, &fx.repo, cc.a2, cc.b2, null);
    defer gpa.free(bases);
    try testing.expectEqual(@as(usize, 2), bases.len);

    var result = try mergeCommits(gpa, &fx.repo, cc.a2, cc.b2, .{}, null);
    defer result.deinit(gpa);

    // The virtual base holds both additions, so neither side looks like it
    // added anything and the merge is clean.
    try testing.expect(!result.hasConflicts());
    try testing.expect(resolvedOid(result, "a.txt").?.eql(cc.a_blob));
    try testing.expect(resolvedOid(result, "b.txt").?.eql(cc.b_blob));
}

test "recursion_limit zero stops the fold and uses the first base" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init(gpa, io);
    defer fx.deinit();

    const cc = try crissCross(&fx, gpa);

    const bases = try revwalk_mod.mergeBases(gpa, &fx.repo, cc.a2, cc.b2, null);
    defer gpa.free(bases);
    const first_tree = try revwalk_mod.peel(gpa, &fx.repo, bases[0], .tree);
    const folded = try foldBases(gpa, &fx.repo, bases, .{}, null);
    const unfolded = try foldBases(gpa, &fx.repo, bases, .{ .recursion_limit = 0 }, null);

    try testing.expect(unfolded.eql(first_tree));
    try testing.expect(!folded.eql(first_tree));
}

test "mergeCommits keeps ours and theirs the right way round" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init(gpa, io);
    defer fx.deinit();

    // Modify against delete is the asymmetric case: the kind reported names
    // which side did which, so swapping the arguments changes the answer.
    // Both of the other tests here are symmetric and would pass either way.
    const b1 = try fx.blob("base\n");
    const o1 = try fx.blob("ours\n");
    var base_e = [_]Tree.Entry{.{ .mode = .blob, .name = "f.txt", .oid = b1 }};
    const base_tree = try fx.tree(gpa, &base_e);
    const root = try fx.commit(gpa, base_tree, &.{}, 1000);

    var our_e = [_]Tree.Entry{.{ .mode = .blob, .name = "f.txt", .oid = o1 }};
    const our_tree = try fx.tree(gpa, &our_e);
    const ours = try fx.commit(gpa, our_tree, &.{root}, 2000);

    var empty: [0]Tree.Entry = .{};
    const gone_tree = try fx.tree(gpa, &empty);
    const theirs = try fx.commit(gpa, gone_tree, &.{root}, 2001);

    var forward = try mergeCommits(gpa, &fx.repo, ours, theirs, .{}, null);
    defer forward.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), forward.conflicts.len);
    try testing.expectEqual(merge_trees_mod.ConflictKind.modify_delete, forward.conflicts[0].kind);

    var mirror = try mergeCommits(gpa, &fx.repo, theirs, ours, .{}, null);
    defer mirror.deinit(gpa);
    try testing.expectEqual(merge_trees_mod.ConflictKind.delete_modify, mirror.conflicts[0].kind);
}

test "the virtual base is itself merged recursively, not against nothing" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init(gpa, io);
    defer fx.deinit();

    // The shape that caught this: the two bases edit the SAME file in
    // different places, and each side of the criss-cross keeps only its own
    // edit. Folding the base trees against a null base reads every line
    // either base changed as an add against an add, so the virtual base
    // comes out full of conflict markers and the real merge conflicts
    // against that. Merging the two bases over THEIR base gives a clean
    // one, which is what git produces here.
    const root_blob = try fx.blob("l1\nl2\nl3\nl4\nl5\nl6\nl7\n");
    const a_blob = try fx.blob("A line 1\nl2\nl3\nl4\nl5\nl6\nl7\n");
    const b_blob = try fx.blob("l1\nl2\nl3\nl4\nl5\nl6\nB line 7\n");

    var root_e = [_]Tree.Entry{.{ .mode = .blob, .name = "shared.txt", .oid = root_blob }};
    const root_tree = try fx.tree(gpa, &root_e);
    const root = try fx.commit(gpa, root_tree, &.{}, 1000);

    var a_e = [_]Tree.Entry{.{ .mode = .blob, .name = "shared.txt", .oid = a_blob }};
    const a_tree = try fx.tree(gpa, &a_e);
    const a = try fx.commit(gpa, a_tree, &.{root}, 2000);

    var b_e = [_]Tree.Entry{.{ .mode = .blob, .name = "shared.txt", .oid = b_blob }};
    const b_tree = try fx.tree(gpa, &b_e);
    const b = try fx.commit(gpa, b_tree, &.{root}, 2001);

    // Each merge keeps its own side's tree, the way `merge -s ours` does.
    const a2 = try fx.commit(gpa, a_tree, &.{ a, b }, 3000);
    const b2 = try fx.commit(gpa, b_tree, &.{ b, a }, 3001);

    const bases = try revwalk_mod.mergeBases(gpa, &fx.repo, a2, b2, null);
    defer gpa.free(bases);
    try testing.expectEqual(@as(usize, 2), bases.len);

    var result = try mergeCommits(gpa, &fx.repo, a2, b2, .{}, null);
    defer result.deinit(gpa);
    try testing.expect(!result.hasConflicts());
}

test "three merge bases fold in turn, each step walking the one before" {
    const gpa = testing.allocator;
    const io = testing.io;
    var fx = try Fixture.init(gpa, io);
    defer fx.deinit();

    // Three bases make the fold run twice, and the second step has to find
    // the base of the virtual commit the first step wrote. That only works
    // if the virtual commit carries its parents, so this is the shape that
    // tests them: with two bases the fold's result is never walked again.
    const root_blob = try fx.blob("l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\n");
    var root_e = [_]Tree.Entry{.{ .mode = .blob, .name = "f.txt", .oid = root_blob }};
    const root_tree = try fx.tree(gpa, &root_e);
    const root = try fx.commit(gpa, root_tree, &.{}, 1000);

    const a_blob = try fx.blob("A1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\n");
    const b_blob = try fx.blob("l1\nl2\nl3\nB4\nl5\nl6\nl7\nl8\nl9\n");
    const c_blob = try fx.blob("l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nC9\n");

    var a_e = [_]Tree.Entry{.{ .mode = .blob, .name = "f.txt", .oid = a_blob }};
    const a = try fx.commit(gpa, try fx.tree(gpa, &a_e), &.{root}, 2000);
    var b_e = [_]Tree.Entry{.{ .mode = .blob, .name = "f.txt", .oid = b_blob }};
    const b = try fx.commit(gpa, try fx.tree(gpa, &b_e), &.{root}, 2001);
    var c_e = [_]Tree.Entry{.{ .mode = .blob, .name = "f.txt", .oid = c_blob }};
    const c = try fx.commit(gpa, try fx.tree(gpa, &c_e), &.{root}, 2002);

    // Two commits with the same three parents, so none of A, B or C reaches
    // another and all three are best common ancestors.
    var m1_e = [_]Tree.Entry{.{ .mode = .blob, .name = "f.txt", .oid = a_blob }};
    const m1 = try fx.commit(gpa, try fx.tree(gpa, &m1_e), &.{ a, b, c }, 3000);
    var m2_e = [_]Tree.Entry{.{ .mode = .blob, .name = "f.txt", .oid = c_blob }};
    const m2 = try fx.commit(gpa, try fx.tree(gpa, &m2_e), &.{ a, b, c }, 3001);

    const bases = try revwalk_mod.mergeBases(gpa, &fx.repo, m1, m2, null);
    defer gpa.free(bases);
    try testing.expectEqual(@as(usize, 3), bases.len);

    var result = try mergeCommits(gpa, &fx.repo, m1, m2, .{}, null);
    defer result.deinit(gpa);
    try testing.expect(!result.hasConflicts());
}
