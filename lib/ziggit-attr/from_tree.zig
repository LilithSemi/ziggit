//! Loading every `.gitattributes` out of a tree.
//!
//! A checkout writes a tree that carries its own `.gitattributes`, and
//! those are the rules the written bytes must follow. Reading the worktree
//! instead would consult files that are not there yet.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;

const object_mod = @import("ziggit-object");
const Tree = object_mod.Tree;

const attributes_mod = @import("Attributes.zig");
const Attributes = attributes_mod.Attributes;

pub const Error = attributes_mod.Error || error{ ObjectUnreadable, CorruptObject };

/// Where tree and blob objects come from.
///
/// This module takes a reader rather than an `Odb` so that nothing here
/// depends on `ziggit-odb`. `ziggit-odb` already imports `ziggit-index`,
/// and `ziggit-index` needs this module for the clean direction, so an
/// `Odb` here would close a cycle.
pub const ObjectReader = struct {
    ctx: *anyopaque,
    /// Reads the object whole, refusing anything over `max`.
    readAlloc: *const fn (ctx: *anyopaque, gpa: Allocator, oid: Oid, max: usize) Error![]u8,

    pub fn read(r: ObjectReader, gpa: Allocator, oid: Oid, max: usize) Error![]u8 {
        return r.readAlloc(r.ctx, gpa, oid, max);
    }
};

/// How deep a tree this walks looking for attribute files. A real
/// repository is nowhere near this; the bound is against a tree built to
/// exhaust the stack.
pub const max_depth: usize = 64;

/// Reads every `.gitattributes` in `tree_oid` into a fresh `Attributes`,
/// each tagged with the directory it came from. The caller owns the result.
pub fn fromTree(
    gpa: Allocator,
    objects: ObjectReader,
    f: Format,
    tree_oid: Oid,
) Error!Attributes {
    var out = Attributes.init(gpa);
    errdefer out.deinit();
    try walk(gpa, objects, f, tree_oid, "", 0, &out);
    return out;
}

fn walk(
    gpa: Allocator,
    objects: ObjectReader,
    f: Format,
    tree_oid: Oid,
    base: []const u8,
    depth: usize,
    out: *Attributes,
) Error!void {
    if (depth >= max_depth) return;

    const bytes = try objects.read(gpa, tree_oid, max_tree_bytes);
    defer gpa.free(bytes);
    var tree = Tree.parse(gpa, f, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CorruptTree => return error.CorruptObject,
    };
    defer tree.deinit(gpa);

    for (tree.entries) |entry| {
        if (entry.mode.isTree()) continue;
        if (!std.mem.eql(u8, entry.name, ".gitattributes")) continue;
        const text = try objects.read(gpa, entry.oid, attributes_mod.max_file_len);
        defer gpa.free(text);
        try out.addText(text, base);
    }

    for (tree.entries) |entry| {
        if (!entry.mode.isTree()) continue;
        const sub = if (base.len == 0)
            try gpa.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, entry.name });
        defer gpa.free(sub);
        try walk(gpa, objects, f, entry.oid, sub, depth + 1, out);
    }
}

/// A `.gitattributes` past this is refused rather than read, and so is a
/// tree object past it.
const max_tree_bytes: usize = 64 << 20;

pub const Unsupported = struct {
    path: []const u8, // owned
    driver: []const u8, // owned

    pub fn deinit(u: *const Unsupported, gpa: Allocator) void {
        gpa.free(u.path);
        gpa.free(u.driver);
    }
};

/// Every path in `tree_oid` whose attributes name a `filter=` driver,
/// without checking anything out. A caller asks this before a checkout to
/// find out whether one would be refused, and what would refuse it.
///
/// `filter.<name>.required` is deliberately not reported here: this module
/// reads no config, and the flag changes nothing about what this library
/// can do, since it runs no driver either way. A caller that wants to know
/// whether real git would also fail reads `filter.<name>.required` from
/// its own config for each driver named here. Required means git fails
/// too; unset means git would skip the filter and carry on.
pub fn unsupportedFilters(
    gpa: Allocator,
    objects: ObjectReader,
    f: Format,
    tree_oid: Oid,
) Error![]Unsupported {
    var attrs = try fromTree(gpa, objects, f, tree_oid);
    defer attrs.deinit();

    var out: std.ArrayList(Unsupported) = .empty;
    errdefer {
        for (out.items) |u| u.deinit(gpa);
        out.deinit(gpa);
    }
    try collectFiltered(gpa, objects, f, tree_oid, "", 0, &attrs, &out);
    return out.toOwnedSlice(gpa);
}

fn collectFiltered(
    gpa: Allocator,
    objects: ObjectReader,
    f: Format,
    tree_oid: Oid,
    base: []const u8,
    depth: usize,
    attrs: *const Attributes,
    out: *std.ArrayList(Unsupported),
) Error!void {
    if (depth >= max_depth) return;

    const bytes = try objects.read(gpa, tree_oid, max_tree_bytes);
    defer gpa.free(bytes);
    var tree = Tree.parse(gpa, f, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CorruptTree => return error.CorruptObject,
    };
    defer tree.deinit(gpa);

    for (tree.entries) |entry| {
        const path = if (base.len == 0)
            try gpa.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, entry.name });
        defer gpa.free(path);

        if (entry.mode.isTree()) {
            try collectFiltered(gpa, objects, f, entry.oid, path, depth + 1, attrs, out);
            continue;
        }
        // A gitlink names a commit in another repository, which has its own
        // attributes and its own checkout.
        if (entry.mode.isGitlink()) continue;

        const driver = attrs.lookup(path).filter orelse continue;
        const owned_path = try gpa.dupe(u8, path);
        errdefer gpa.free(owned_path);
        const owned_driver = try gpa.dupe(u8, driver);
        errdefer gpa.free(owned_driver);
        try out.append(gpa, .{ .path = owned_path, .driver = owned_driver });
    }
}

const testing = std.testing;
const TextSetting = attributes_mod.TextSetting;

/// An object store for tests alone, so this module's tests need no `Odb`
/// and this module needs no dependency on one.
const TestStore = struct {
    gpa: Allocator,
    objects: std.AutoHashMapUnmanaged(Oid, []u8) = .empty,

    fn deinit(s: *TestStore) void {
        var it = s.objects.valueIterator();
        while (it.next()) |v| s.gpa.free(v.*);
        s.objects.deinit(s.gpa);
    }

    fn put(s: *TestStore, kind: []const u8, payload: []const u8) !Oid {
        var hasher = oid_mod.Hasher.init(.sha1);
        var head: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&head, "{s} {d}\x00", .{ kind, payload.len });
        hasher.update(header);
        hasher.update(payload);
        const oid = hasher.final();
        const owned = try s.gpa.dupe(u8, payload);
        try s.objects.put(s.gpa, oid, owned);
        return oid;
    }

    fn blob(s: *TestStore, content: []const u8) !Oid {
        return s.put("blob", content);
    }

    fn tree(s: *TestStore, entries: []Tree.Entry) !Oid {
        Tree.sortEntries(entries);
        var aw = try std.Io.Writer.Allocating.initCapacity(s.gpa, 256);
        defer aw.deinit();
        const t: Tree = .{ .entries = entries };
        try t.write(&aw.writer);
        return s.put("tree", aw.writer.buffered());
    }

    fn readFn(ctx: *anyopaque, gpa: Allocator, oid: Oid, max: usize) Error![]u8 {
        const s: *TestStore = @ptrCast(@alignCast(ctx));
        const found = s.objects.get(oid) orelse return error.ObjectUnreadable;
        if (found.len > max) return error.ObjectUnreadable;
        return gpa.dupe(u8, found);
    }

    fn reader(s: *TestStore) ObjectReader {
        return .{ .ctx = @ptrCast(s), .readAlloc = readFn };
    }
};

test "attributes come from every directory of the tree" {
    const gpa = testing.allocator;
    var s: TestStore = .{ .gpa = gpa };
    defer s.deinit();

    const root_attr = try s.blob("* text\n");
    const sub_attr = try s.blob("* -text\n");
    const content = try s.blob("x\n");

    var sub_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitattributes", .oid = sub_attr },
        .{ .mode = .blob, .name = "in.txt", .oid = content },
    };
    const sub = try s.tree(&sub_entries);
    var root_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitattributes", .oid = root_attr },
        .{ .mode = .blob, .name = "top.txt", .oid = content },
        .{ .mode = .tree, .name = "d", .oid = sub },
    };
    const root = try s.tree(&root_entries);

    var attrs = try fromTree(gpa, s.reader(), .sha1, root);
    defer attrs.deinit();

    try testing.expectEqual(TextSetting.set, attrs.lookup("top.txt").text);
    try testing.expectEqual(TextSetting.unset, attrs.lookup("d/in.txt").text);
}

test "a tree with no attributes file yields no opinion" {
    const gpa = testing.allocator;
    var s: TestStore = .{ .gpa = gpa };
    defer s.deinit();

    const content = try s.blob("x\n");
    var entries = [_]Tree.Entry{.{ .mode = .blob, .name = "f.txt", .oid = content }};
    const root = try s.tree(&entries);

    var attrs = try fromTree(gpa, s.reader(), .sha1, root);
    defer attrs.deinit();
    try testing.expectEqual(TextSetting.unspecified, attrs.lookup("f.txt").text);
}

test "unsupportedFilters names the lfs paths and nothing else" {
    const gpa = testing.allocator;
    var s: TestStore = .{ .gpa = gpa };
    defer s.deinit();

    const attr_blob = try s.blob("*.psd filter=lfs diff=lfs merge=lfs -text\n");
    const content = try s.blob("pointer\n");

    var art_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = "logo.psd", .oid = content },
        .{ .mode = .blob, .name = "notes.md", .oid = content },
    };
    const art = try s.tree(&art_entries);
    var root_entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = ".gitattributes", .oid = attr_blob },
        .{ .mode = .blob, .name = "README.md", .oid = content },
        .{ .mode = .tree, .name = "art", .oid = art },
    };
    const root = try s.tree(&root_entries);

    const found = try unsupportedFilters(gpa, s.reader(), .sha1, root);
    defer {
        for (found) |u| u.deinit(gpa);
        gpa.free(found);
    }

    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqualStrings("art/logo.psd", found[0].path);
    try testing.expectEqualStrings("lfs", found[0].driver);
}

test "a tree with no filter driver reports nothing" {
    const gpa = testing.allocator;
    var s: TestStore = .{ .gpa = gpa };
    defer s.deinit();

    const content = try s.blob("x\n");
    var entries = [_]Tree.Entry{.{ .mode = .blob, .name = "f.txt", .oid = content }};
    const root = try s.tree(&entries);

    const found = try unsupportedFilters(gpa, s.reader(), .sha1, root);
    defer gpa.free(found);
    try testing.expectEqual(@as(usize, 0), found.len);
}
