//! Turning a merge result into the tree `git merge-tree --write-tree`
//! prints.
//!
//! The result itself carries conflict stages, which is libgit2's answer.
//! Git's command instead writes one tree where a conflicted path holds the
//! marked content, and reports the conflict through its exit status. Both
//! callers are served from one result: this reads it the way git does.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Oid = oid_mod.Oid;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;

const odb_mod = @import("ziggit-odb");
const Odb = odb_mod.Odb;

const index_mod = @import("ziggit-index");
const Index = index_mod.Index;
const IndexEntry = index_mod.Entry;

const merge_trees_mod = @import("merge_trees.zig");
const Result = merge_trees_mod.Result;

pub const Error = merge_trees_mod.Error || odb_mod.TreeBuilderError;

/// Writes `result` as one tree.
///
/// A resolved path contributes its stage 0 entry. A conflicted path
/// contributes its marked content where there is some, and otherwise ours'
/// side, which is what git leaves in the tree for a modify/delete and says
/// so in its message: "Version ours of f.txt left in tree". A conflicted
/// path with no marked content and no side of ours, which is delete/modify,
/// contributes nothing.
pub fn writeTree(
    gpa: Allocator,
    odb: *Odb,
    result: Result,
    diag: ?*?Diagnostic,
) Error!Oid {
    var entries: std.ArrayList(IndexEntry) = .empty;
    defer entries.deinit(gpa);

    for (result.index.entries) |entry| {
        if (entry.stage == .merged) try entries.append(gpa, entry);
    }

    // One entry per conflicted path. Git keeps whichever side still has the
    // file, ours or theirs, and says so in its message: "Version theirs of
    // f.txt left in tree" when ours deleted it. The marked content replaces
    // that side's oid where the merge produced some.
    for (result.conflicts) |conflict| {
        const side = stageEntry(result.index, conflict.path, .ours) orelse
            stageEntry(result.index, conflict.path, .theirs) orelse continue;
        var out = side;
        out.stage = .merged;
        if (conflict.marked) |marked| out.oid = marked;
        try entries.append(gpa, out);
    }

    std.mem.sort(IndexEntry, entries.items, {}, lessThanPath);

    const flat: Index = .{ .gpa = gpa, .entries = entries.items };
    return odb_mod.writeTreeFromIndex(gpa, odb, flat, diag);
}

fn stageEntry(index: Index, path: []const u8, stage: index_mod.Stage) ?IndexEntry {
    for (index.entries) |e| {
        if (e.stage == stage and std.mem.eql(u8, e.path, path)) return e;
    }
    return null;
}

fn lessThanPath(_: void, a: IndexEntry, b: IndexEntry) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

const testing = std.testing;
const TestRepo = merge_trees_mod.TestRepo;
const Tree = @import("ziggit-object").Tree;

test "a clean merge writes the tree its entries describe" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try TestRepo.init(gpa, io);
    defer r.deinit(io);

    const b1 = try r.blob("base\n");
    const o1 = try r.blob("ours\n");
    var base_e = [_]Tree.Entry{
        .{ .mode = .blob, .name = "a.txt", .oid = b1 },
        .{ .mode = .blob, .name = "keep.txt", .oid = b1 },
    };
    const base = try r.tree(gpa, &base_e);
    var our_e = [_]Tree.Entry{
        .{ .mode = .blob, .name = "a.txt", .oid = o1 },
        .{ .mode = .blob, .name = "keep.txt", .oid = b1 },
    };
    const ours = try r.tree(gpa, &our_e);

    var result = try merge_trees_mod.mergeTrees(gpa, &r.odb, base, ours, base, .{}, null);
    defer result.deinit(gpa);
    const written = try writeTree(gpa, &r.odb, result, null);

    // Ours is the only side that changed, so the merge is ours' tree.
    try testing.expect(written.eql(ours));
}

test "a content conflict puts the marked blob in the tree" {
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

    var result = try merge_trees_mod.mergeTrees(gpa, &r.odb, base, ours, theirs, .{}, null);
    defer result.deinit(gpa);
    try testing.expect(result.hasConflicts());

    const written = try writeTree(gpa, &r.odb, result, null);
    const tree_bytes = try r.odb.readAlloc(gpa, written, 1 << 16, null);
    defer gpa.free(tree_bytes);
    var tree = try Tree.parse(gpa, .sha1, tree_bytes);
    defer tree.deinit(gpa);

    const entry = tree.find("a.txt").?;
    const content = try r.odb.readAlloc(gpa, entry.oid, 1 << 16, null);
    defer gpa.free(content);
    try testing.expectEqualStrings(
        "one\n<<<<<<< ours\nOURS\n=======\nTHEIRS\n>>>>>>> theirs\nthree\n",
        content,
    );
}

test "modify against delete leaves ours' version in the tree" {
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

    var result = try merge_trees_mod.mergeTrees(gpa, &r.odb, base, ours, gone, .{}, null);
    defer result.deinit(gpa);

    const written = try writeTree(gpa, &r.odb, result, null);
    const tree_bytes = try r.odb.readAlloc(gpa, written, 1 << 16, null);
    defer gpa.free(tree_bytes);
    var tree = try Tree.parse(gpa, .sha1, tree_bytes);
    defer tree.deinit(gpa);
    try testing.expect(tree.find("a.txt").?.oid.eql(o1));
}

test "delete against modify leaves the surviving side in the tree" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try TestRepo.init(gpa, io);
    defer r.deinit(io);

    const b1 = try r.blob("base\n");
    const t1 = try r.blob("theirs\n");
    var base_e = [_]Tree.Entry{.{ .mode = .blob, .name = "f.txt", .oid = b1 }};
    const base = try r.tree(gpa, &base_e);
    var empty: [0]Tree.Entry = .{};
    const gone = try r.tree(gpa, &empty);
    var their_e = [_]Tree.Entry{.{ .mode = .blob, .name = "f.txt", .oid = t1 }};
    const theirs = try r.tree(gpa, &their_e);

    // Ours deleted it, so there is no stage 2 entry. Git keeps theirs'
    // version anyway: "Version theirs of f.txt left in tree".
    var result = try merge_trees_mod.mergeTrees(gpa, &r.odb, base, gone, theirs, .{}, null);
    defer result.deinit(gpa);
    try testing.expect(result.hasConflicts());

    const written = try writeTree(gpa, &r.odb, result, null);
    const tree_bytes = try r.odb.readAlloc(gpa, written, 1 << 16, null);
    defer gpa.free(tree_bytes);
    var tree = try Tree.parse(gpa, .sha1, tree_bytes);
    defer tree.deinit(gpa);
    try testing.expect(tree.find("f.txt").?.oid.eql(t1));
}

test "a path two directories deep survives the tree write" {
    const gpa = testing.allocator;
    const io = testing.io;
    var r = try TestRepo.init(gpa, io);
    defer r.deinit(io);

    // The tree builder used to write a parent before its child, leaving a
    // zero id for the nested directory, so a path this deep came back as a
    // tree git could not read.
    const b1 = try r.blob("deep\n");
    var inner = [_]Tree.Entry{.{ .mode = .blob, .name = "d.txt", .oid = b1 }};
    const deep = try r.tree(gpa, &inner);
    var mid = [_]Tree.Entry{.{ .mode = .tree, .name = "deep", .oid = deep }};
    const sub = try r.tree(gpa, &mid);
    var root = [_]Tree.Entry{.{ .mode = .tree, .name = "sub", .oid = sub }};
    const tree_oid = try r.tree(gpa, &root);

    var result = try merge_trees_mod.mergeTrees(gpa, &r.odb, tree_oid, tree_oid, tree_oid, .{}, null);
    defer result.deinit(gpa);
    const written = try writeTree(gpa, &r.odb, result, null);
    try testing.expect(written.eql(tree_oid));
}
