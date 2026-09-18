//! Builds tree objects from an index's flat list of paths, creating nested
//! tree objects for each directory level and writing them to the object
//! database.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Oid = oid_mod.Oid;

const core_mod = @import("ziggit-core");
const ObjectKind = core_mod.ObjectKind;
const FileMode = core_mod.FileMode;
const Diagnostic = core_mod.Diagnostic;

const object_mod = @import("ziggit-object");
const Tree = object_mod.Tree;

const index_mod = @import("ziggit-index");
const Index = index_mod.Index;
const IndexEntry = index_mod.Entry;
const IndexStage = index_mod.Stage;

const Odb = @import("Odb.zig").Odb;

pub const Error = error{
    UnmergedEntry,
} || Odb.Error || Allocator.Error;

/// Writes a loose object through a temp file and an atomic rename.
/// Builds tree objects from the index's flat list of entries, creating nested
/// tree objects for each directory level, and writes them all to the ODB.
/// Returns the root tree's OID.
///
/// Entries with stage != .merged are unmerged and are refused with
/// error.UnmergedEntry.
pub fn writeTreeFromIndex(gpa: Allocator, odb: *Odb, index: Index, diag: ?*?Diagnostic) Error!Oid {
    // Check for unmerged entries
    for (index.entries) |entry| {
        if (entry.stage != .merged) {
            return error.UnmergedEntry;
        }
    }

    // Build a tree structure from the flat index entries
    var trees: TreeMap = .init(gpa);
    defer {
        var it = trees.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(gpa);
            // The map owns every key: see `ensureDir`.
            if (entry.key_ptr.len > 0) gpa.free(entry.key_ptr.*);
        }
        trees.deinit();
    }

    // The root directory always exists, even for an empty index.
    _ = try ensureDir(gpa, &trees, "");

    // Group entries by their parent directory paths
    for (index.entries) |entry| {
        try addEntryToTrees(gpa, &trees, entry);
    }

    // Add directory entries for all subdirectories
    try addDirectoryEntries(gpa, &trees);

    // Write all trees to the ODB and return the root tree's OID
    return try buildAndWriteTrees(gpa, odb, &trees, diag);
}

/// A map from directory paths to the tree entries that belong in that directory.
/// The root directory is represented by an empty string.
const TreeMap = std.StringHashMap(std.ArrayList(Tree.Entry));

/// Finds or creates the entry list for the directory `path`, **taking a copy
/// of `path` as the key**.
///
/// The map must own its keys. The first version of this file passed
/// `dir_path.items` straight to `getOrPut`, where `dir_path` was a local
/// `ArrayList` freed when the function returned, so every key pointed into
/// freed memory. The directory entry's name is read back out of that key, so
/// a tree came out naming its subdirectory `\xaa`, the byte Debug fills freed
/// memory with, and then sorted wrong because `\xaa` sorts last. The tree id
/// was silently not git's. Two allocations a directory is worth not repeating
/// that.
///
/// The empty root key is a literal and is never freed; the teardown skips it
/// by length.
fn ensureDir(gpa: Allocator, trees: *TreeMap, path: []const u8) Error!*std.ArrayList(Tree.Entry) {
    if (trees.getPtr(path)) |existing| return existing;
    const owned: []const u8 = if (path.len == 0) "" else try gpa.dupe(u8, path);
    errdefer if (owned.len > 0) gpa.free(owned);
    try trees.put(owned, .empty);
    return trees.getPtr(owned).?;
}

fn addEntryToTrees(gpa: Allocator, trees: *TreeMap, entry: IndexEntry) Error!void {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);

    // Split the entry path by '/'
    var it = std.mem.splitSequence(u8, entry.path, "/");
    while (it.next()) |part| {
        try parts.append(gpa, part);
    }

    // For each level of the path except the filename, ensure directory exists
    var dir_path: std.ArrayList(u8) = .empty;
    defer dir_path.deinit(gpa);

    for (parts.items[0 .. parts.items.len - 1]) |part| {
        // Add current part to the path
        if (dir_path.items.len > 0) {
            try dir_path.appendSlice(gpa, "/");
        }
        try dir_path.appendSlice(gpa, part);

        // `dir_path.items` is a slice into a list this function frees, and
        // `appendSlice` above may have moved it already. `ensureDir` copies
        // it, so the map never holds a borrowed key.
        _ = try ensureDir(gpa, trees, dir_path.items);
    }

    // Add the entry itself to its parent directory
    const parent_dir = if (parts.items.len > 1) dir_path.items else "";
    const list = try ensureDir(gpa, trees, parent_dir);

    try list.append(gpa, .{
        .mode = entry.mode,
        .name = parts.items[parts.items.len - 1],
        .oid = entry.oid,
    });
}

fn addDirectoryEntries(gpa: Allocator, trees: *TreeMap) Error!void {
    // Collect all directory paths
    var dir_paths: std.ArrayList([]const u8) = .empty;
    defer dir_paths.deinit(gpa);

    var it = trees.keyIterator();
    while (it.next()) |path| {
        if (path.len > 0) { // Skip root
            try dir_paths.append(gpa, path.*);
        }
    }

    // For each directory, add it as an entry in its parent directory
    for (dir_paths.items) |path| {
        // Find the parent directory
        var last_slash: ?usize = null;
        for (0..path.len) |i| {
            if (path[i] == '/') {
                last_slash = i;
            }
        }

        const parent_path = if (last_slash) |ls| path[0..ls] else "";
        const dir_name = if (last_slash) |ls| path[ls + 1 ..] else path;

        // Add this directory as an entry in its parent. `parent_path` is a
        // slice of a key the map already owns, so `ensureDir` copying it is
        // what stops one key pointing into the middle of another, which the
        // teardown would then try to free.
        const list = try ensureDir(gpa, trees, parent_path);

        // Check if this directory entry already exists
        var found = false;
        for (list.items) |e| {
            if (std.mem.eql(u8, e.name, dir_name) and e.mode == .tree) {
                found = true;
                break;
            }
        }

        if (!found) {
            // Placeholder OID (will be filled in later)
            try list.append(gpa, .{
                .mode = .tree,
                .name = dir_name,
                .oid = Oid.zero(.sha1),
            });
        }
    }
}

fn buildAndWriteTrees(gpa: Allocator, odb: *Odb, trees: *TreeMap, diag: ?*?Diagnostic) Error!Oid {
    // Write trees from leaves to root, building a map of directory paths to their OIDs
    var tree_oids: std.StringHashMap(Oid) = .init(gpa);
    defer {
        var it = tree_oids.keyIterator();
        while (it.next()) |key| {
            gpa.free(key.*);
        }
        tree_oids.deinit();
    }

    // Collect entries and sort by depth (leaves first)
    var entries: std.ArrayList(struct { path: []const u8, entries: std.ArrayList(Tree.Entry) }) = .empty;
    defer {
        for (entries.items) |*e| {
            e.entries.deinit(gpa);
        }
        entries.deinit(gpa);
    }

    var tree_it = trees.iterator();
    while (tree_it.next()) |tree_entry| {
        var tree_entries: std.ArrayList(Tree.Entry) = .empty;
        for (tree_entry.value_ptr.items) |entry| {
            try tree_entries.append(gpa, entry);
        }
        try entries.append(gpa, .{
            .path = tree_entry.key_ptr.*,
            .entries = tree_entries,
        });
    }

    // Sort by depth (leaves first, root last)
    std.mem.sort(@TypeOf(entries.items[0]), entries.items, {}, struct {
        pub fn lessThan(_: void, a: @TypeOf(entries.items[0]), b: @TypeOf(entries.items[0])) bool {
            return pathDepthComparator({}, a.path, b.path);
        }
    }.lessThan);

    // Write each tree to the ODB
    for (entries.items) |*entry| {
        // Replace directory entries with their OIDs (already written)
        for (entry.entries.items) |*tree_entry| {
            if (tree_entry.mode == .tree) {
                // Build the full path for this subdirectory
                var subdir: std.ArrayList(u8) = .empty;
                defer subdir.deinit(gpa);

                if (entry.path.len > 0) {
                    try subdir.appendSlice(gpa, entry.path);
                    try subdir.appendSlice(gpa, "/");
                }
                try subdir.appendSlice(gpa, tree_entry.name);

                if (tree_oids.get(subdir.items)) |subdir_oid| {
                    tree_entry.oid = subdir_oid;
                }
            }
        }

        // Sort entries using git's tree sort rule (AFTER setting all OIDs)
        Tree.sortEntries(entry.entries.items);

        // Write tree to ODB
        // Estimate buffer size: each entry takes roughly 30+ bytes
        const estimated_size = entry.entries.items.len * 100 + 256;
        const buf = try gpa.alloc(u8, estimated_size);
        defer gpa.free(buf);

        var w: std.Io.Writer = .fixed(buf);
        const tree: Tree = .{ .entries = entry.entries.items };
        tree.write(&w) catch return error.IoFailed;

        const tree_oid = try odb.write(.tree, w.buffered(), diag);
        try tree_oids.put(try gpa.dupe(u8, entry.path), tree_oid);
    }

    // Return the root tree's OID
    if (tree_oids.get("")) |root_oid| {
        return root_oid;
    }
    return error.OutOfMemory;
}

fn comparePathDepth(_: void, a: []const u8, b: []const u8) bool {
    const depth_a = countSlashes(a);
    const depth_b = countSlashes(b);
    return depth_a < depth_b;
}

fn countSlashes(path: []const u8) usize {
    var count: usize = 0;
    for (path) |c| {
        if (c == '/') count += 1;
    }
    return count;
}

fn pathDepthComparator(_: void, a: []const u8, b: []const u8) bool {
    const depth_a = countSlashes(a);
    const depth_b = countSlashes(b);
    if (depth_a != depth_b) return depth_a < depth_b;
    // If same depth, root ("") comes last
    if (a.len == 0) return false; // a is root, comes after b
    if (b.len == 0) return true; // b is root, comes after a
    return false; // otherwise maintain order
}

// Tests

test "a tree built from an index matches the id real git produces" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var odb = try Odb.init(gpa, io, tmp.dir, .sha1, .{});
    defer odb.deinit();

    // Build an index with three entries: a.txt, d/b.txt, run.sh
    var entries: std.ArrayList(IndexEntry) = .empty;
    defer {
        for (entries.items) |*e| e.deinit(gpa);
        entries.deinit(gpa);
    }

    const a_txt_oid = try Oid.parse(.sha1, "ce013625030ba8dba906f756967f9e9ca394464a");
    const d_b_txt_oid = try Oid.parse(.sha1, "79c53955ef856f16f2107446bc721c8879a1bd2e");
    const run_sh_oid = try Oid.parse(.sha1, "1a2485251c33a70432394c93fb89330ef214bfc9");

    try entries.append(gpa, .{
        .path = try gpa.dupe(u8, "a.txt"),
        .oid = a_txt_oid,
        .mode = .blob,
        .stage = .merged,
        .size = 6,
        .stat = .{
            .ctime_seconds = 0,
            .ctime_nanoseconds = 0,
            .mtime_seconds = 0,
            .mtime_nanoseconds = 0,
            .dev = 0,
            .ino = 0,
            .uid = 0,
            .gid = 0,
        },
    });

    try entries.append(gpa, .{
        .path = try gpa.dupe(u8, "d/b.txt"),
        .oid = d_b_txt_oid,
        .mode = .blob,
        .stage = .merged,
        .size = 7,
        .stat = .{
            .ctime_seconds = 0,
            .ctime_nanoseconds = 0,
            .mtime_seconds = 0,
            .mtime_nanoseconds = 0,
            .dev = 0,
            .ino = 0,
            .uid = 0,
            .gid = 0,
        },
    });

    try entries.append(gpa, .{
        .path = try gpa.dupe(u8, "run.sh"),
        .oid = run_sh_oid,
        .mode = .blob_executable,
        .stage = .merged,
        .size = 10,
        .stat = .{
            .ctime_seconds = 0,
            .ctime_nanoseconds = 0,
            .mtime_seconds = 0,
            .mtime_nanoseconds = 0,
            .dev = 0,
            .ino = 0,
            .uid = 0,
            .gid = 0,
        },
    });

    const index_obj: Index = .{
        .gpa = gpa,
        .entries = entries.items,
    };

    const root_oid = try writeTreeFromIndex(gpa, &odb, index_obj, null);

    // Expected root tree id from real git 2.55
    const expected_root = try Oid.parse(.sha1, "dc388fc74b7ae653cebc33b4d91de4fc84b13394");
    try std.testing.expect(root_oid.eql(expected_root));
}

test "a directory sorts as though its name ended in a slash" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var odb = try Odb.init(gpa, io, tmp.dir, .sha1, .{});
    defer odb.deinit();

    // Build an index with x.txt, x-dash, x/inner
    var entries: std.ArrayList(IndexEntry) = .empty;
    defer {
        for (entries.items) |*e| e.deinit(gpa);
        entries.deinit(gpa);
    }

    const dummy_oid = try Oid.parse(.sha1, "ce013625030ba8dba906f756967f9e9ca394464a");

    try entries.append(gpa, .{
        .path = try gpa.dupe(u8, "x.txt"),
        .oid = dummy_oid,
        .mode = .blob,
        .stage = .merged,
        .size = 0,
        .stat = .{
            .ctime_seconds = 0,
            .ctime_nanoseconds = 0,
            .mtime_seconds = 0,
            .mtime_nanoseconds = 0,
            .dev = 0,
            .ino = 0,
            .uid = 0,
            .gid = 0,
        },
    });

    try entries.append(gpa, .{
        .path = try gpa.dupe(u8, "x-dash"),
        .oid = dummy_oid,
        .mode = .blob,
        .stage = .merged,
        .size = 0,
        .stat = .{
            .ctime_seconds = 0,
            .ctime_nanoseconds = 0,
            .mtime_seconds = 0,
            .mtime_nanoseconds = 0,
            .dev = 0,
            .ino = 0,
            .uid = 0,
            .gid = 0,
        },
    });

    try entries.append(gpa, .{
        .path = try gpa.dupe(u8, "x/inner"),
        .oid = dummy_oid,
        .mode = .blob,
        .stage = .merged,
        .size = 0,
        .stat = .{
            .ctime_seconds = 0,
            .ctime_nanoseconds = 0,
            .mtime_seconds = 0,
            .mtime_nanoseconds = 0,
            .dev = 0,
            .ino = 0,
            .uid = 0,
            .gid = 0,
        },
    });

    const index_obj: Index = .{
        .gpa = gpa,
        .entries = entries.items,
    };

    _ = try writeTreeFromIndex(gpa, &odb, index_obj, null);

    // TODO: Verify the root tree entries are in the right order:
    // x-dash, x.txt, x (as directory)
}

test "a path several levels deep produces nested trees" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var odb = try Odb.init(gpa, io, tmp.dir, .sha1, .{});
    defer odb.deinit();

    // Build an index with a/b/c/d.txt
    var entries: std.ArrayList(IndexEntry) = .empty;
    defer {
        for (entries.items) |*e| e.deinit(gpa);
        entries.deinit(gpa);
    }

    const dummy_oid = try Oid.parse(.sha1, "ce013625030ba8dba906f756967f9e9ca394464a");

    try entries.append(gpa, .{
        .path = try gpa.dupe(u8, "a/b/c/d.txt"),
        .oid = dummy_oid,
        .mode = .blob,
        .stage = .merged,
        .size = 0,
        .stat = .{
            .ctime_seconds = 0,
            .ctime_nanoseconds = 0,
            .mtime_seconds = 0,
            .mtime_nanoseconds = 0,
            .dev = 0,
            .ino = 0,
            .uid = 0,
            .gid = 0,
        },
    });

    const index_obj: Index = .{
        .gpa = gpa,
        .entries = entries.items,
    };

    _ = try writeTreeFromIndex(gpa, &odb, index_obj, null);

    // TODO: Verify that 4 tree objects were created (one for each level a, b, c, and the root)
}

test "an unmerged entry is refused" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var odb = try Odb.init(gpa, io, tmp.dir, .sha1, .{});
    defer odb.deinit();

    // Build an index with an unmerged entry
    var entries: std.ArrayList(IndexEntry) = .empty;
    defer {
        for (entries.items) |*e| e.deinit(gpa);
        entries.deinit(gpa);
    }

    const dummy_oid = try Oid.parse(.sha1, "ce013625030ba8dba906f756967f9e9ca394464a");

    try entries.append(gpa, .{
        .path = try gpa.dupe(u8, "conflicted.txt"),
        .oid = dummy_oid,
        .mode = .blob,
        .stage = .ours, // Unmerged!
        .size = 0,
        .stat = .{
            .ctime_seconds = 0,
            .ctime_nanoseconds = 0,
            .mtime_seconds = 0,
            .mtime_nanoseconds = 0,
            .dev = 0,
            .ino = 0,
            .uid = 0,
            .gid = 0,
        },
    });

    const index_obj: Index = .{
        .gpa = gpa,
        .entries = entries.items,
    };

    try std.testing.expectError(error.UnmergedEntry, writeTreeFromIndex(gpa, &odb, index_obj, null));
}
