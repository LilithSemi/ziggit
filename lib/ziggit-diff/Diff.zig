//! A diff is data first. Renderers can consume `Patch`, `Hunk`, and `Line`
//! directly; `writeUnified` is provided for callers that want Git's familiar
//! textual form.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Oid = @import("ziggit-oid").Oid;
const FileMode = @import("ziggit-core").FileMode;
const Diagnostic = @import("ziggit-core").Diagnostic;
const object_mod = @import("ziggit-object");
const Tree = object_mod.Tree;
const Commit = object_mod.Commit;
const Odb = @import("ziggit-odb").Odb;

pub const Error = error{
    BlobTooLarge,
    TooManyLines,
    DiffTooLarge,
    CorruptObject,
} || Odb.Error || Allocator.Error;

pub const Origin = enum { context, addition, deletion };

pub const Line = struct {
    origin: Origin,
    /// One-based source positions. The side on which an addition/deletion
    /// does not exist is null.
    old_lineno: ?usize,
    new_lineno: ?usize,
    /// Owned. Includes the terminating LF when the source line had one.
    content: []const u8,

    pub fn deinit(line: *Line, gpa: Allocator) void {
        gpa.free(line.content);
        line.* = undefined;
    }
};

pub const Hunk = struct {
    old_start: usize,
    old_lines: usize,
    new_start: usize,
    new_lines: usize,
    /// Ordered context/addition/deletion lines. Owned.
    lines: []Line,

    pub fn deinit(hunk: *Hunk, gpa: Allocator) void {
        for (hunk.lines) |*line| line.deinit(gpa);
        gpa.free(hunk.lines);
        hunk.* = undefined;
    }
};

pub const Status = enum { added, deleted, modified, renamed, copied, type_changed };

pub const Patch = struct {
    /// Both paths are owned. For additions/deletions, the absent side is
    /// represented by `status`, leaving the useful path available on both.
    old_path: []const u8,
    new_path: []const u8,
    status: Status,
    old_mode: ?FileMode = null,
    new_mode: ?FileMode = null,
    old_oid: ?Oid = null,
    new_oid: ?Oid = null,
    /// Rename/copy similarity percentage. Exact detection currently yields
    /// 100; ordinary additions, deletions, and modifications use zero.
    similarity: u8 = 0,
    /// Binary patches deliberately carry metadata but no text hunks.
    binary: bool = false,
    hunks: []Hunk = &.{},

    pub fn deinit(patch: *Patch, gpa: Allocator) void {
        gpa.free(patch.old_path);
        gpa.free(patch.new_path);
        for (patch.hunks) |*hunk| hunk.deinit(gpa);
        gpa.free(patch.hunks);
        patch.* = undefined;
    }

    pub fn additions(patch: Patch) usize {
        var n: usize = 0;
        for (patch.hunks) |h| for (h.lines) |line| if (line.origin == .addition) {
            n += 1;
        };
        return n;
    }

    pub fn deletions(patch: Patch) usize {
        var n: usize = 0;
        for (patch.hunks) |h| for (h.lines) |line| if (line.origin == .deletion) {
            n += 1;
        };
        return n;
    }

    pub fn writeUnified(patch: Patch, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("diff --git ");
        try writePath(w, "a/", patch.old_path);
        try w.writeByte(' ');
        try writePath(w, "b/", patch.new_path);
        try w.writeByte('\n');
        switch (patch.status) {
            .added => try w.print("new file mode {o}\n", .{@backingInt(patch.new_mode orelse .blob)}),
            .deleted => try w.print("deleted file mode {o}\n", .{@backingInt(patch.old_mode orelse .blob)}),
            .renamed => {
                if (patch.old_mode != patch.new_mode) try w.print("old mode {o}\nnew mode {o}\n", .{ @backingInt(patch.old_mode.?), @backingInt(patch.new_mode.?) });
                try w.print("similarity index {d}%\nrename from ", .{patch.similarity});
                try writePath(w, "", patch.old_path);
                try w.writeAll("\nrename to ");
                try writePath(w, "", patch.new_path);
                try w.writeByte('\n');
            },
            .copied => {
                if (patch.old_mode != patch.new_mode) try w.print("old mode {o}\nnew mode {o}\n", .{ @backingInt(patch.old_mode.?), @backingInt(patch.new_mode.?) });
                try w.print("similarity index {d}%\ncopy from ", .{patch.similarity});
                try writePath(w, "", patch.old_path);
                try w.writeAll("\ncopy to ");
                try writePath(w, "", patch.new_path);
                try w.writeByte('\n');
            },
            .type_changed, .modified => if (patch.old_mode != patch.new_mode and patch.old_mode != null and patch.new_mode != null) {
                try w.print("old mode {o}\nnew mode {o}\n", .{ @backingInt(patch.old_mode.?), @backingInt(patch.new_mode.?) });
            },
        }
        if (patch.status != .renamed and patch.status != .copied and (patch.old_oid != null or patch.new_oid != null)) {
            var a: [Oid.max_formatted_length]u8 = undefined;
            var b: [Oid.max_formatted_length]u8 = undefined;
            const old_oid = patch.old_oid orelse Oid.zero(std.meta.activeTag(patch.new_oid orelse unreachable));
            const new_oid = patch.new_oid orelse Oid.zero(std.meta.activeTag(old_oid));
            const ah = old_oid.toHex(&a);
            const bh = new_oid.toHex(&b);
            try w.print("index {s}..{s}", .{ ah[0..@min(7, ah.len)], bh[0..@min(7, bh.len)] });
            if (patch.old_mode == patch.new_mode and patch.new_mode != null) try w.print(" {o}", .{@backingInt(patch.new_mode.?)});
            try w.writeByte('\n');
        }
        if (patch.binary) {
            try w.writeAll("Binary files ");
            if (patch.status == .added) try w.writeAll("/dev/null") else try writePath(w, "a/", patch.old_path);
            try w.writeAll(" and ");
            if (patch.status == .deleted) try w.writeAll("/dev/null") else try writePath(w, "b/", patch.new_path);
            try w.writeAll(" differ\n");
            return;
        }
        if (patch.hunks.len == 0) return;
        try w.writeAll("--- ");
        if (patch.status == .added) {
            try w.writeAll("/dev/null");
        } else {
            try writePath(w, "a/", patch.old_path);
        }
        try w.writeByte('\n');
        try w.writeAll("+++ ");
        if (patch.status == .deleted) {
            try w.writeAll("/dev/null");
        } else {
            try writePath(w, "b/", patch.new_path);
        }
        try w.writeByte('\n');
        for (patch.hunks) |hunk| {
            try w.writeAll("@@ -");
            try writeRange(w, hunk.old_start, hunk.old_lines);
            try w.writeAll(" +");
            try writeRange(w, hunk.new_start, hunk.new_lines);
            try w.writeAll(" @@\n");
            for (hunk.lines) |line| {
                try w.writeByte(switch (line.origin) {
                    .context => ' ',
                    .addition => '+',
                    .deletion => '-',
                });
                try w.writeAll(line.content);
                if (line.content.len == 0 or line.content[line.content.len - 1] != '\n') {
                    try w.writeAll("\n\\ No newline at end of file\n");
                }
            }
        }
    }
};

/// Git's default `core.quotePath` form. Spaces remain readable; bytes that
/// could split a patch line (and non-ASCII bytes) use C-style quoting.
fn writePath(w: *std.Io.Writer, prefix: []const u8, path: []const u8) std.Io.Writer.Error!void {
    var quoted = false;
    for (path) |c| {
        if (c < 0x20 or c >= 0x7f or c == '"' or c == '\\') {
            quoted = true;
            break;
        }
    }
    if (!quoted) {
        try w.writeAll(prefix);
        return w.writeAll(path);
    }
    try w.writeByte('"');
    try w.writeAll(prefix);
    for (path) |c| switch (c) {
        '\\', '"' => try w.print("\\{c}", .{c}),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        '\x08' => try w.writeAll("\\b"),
        '\x0c' => try w.writeAll("\\f"),
        else => if (c < 0x20 or c >= 0x7f) try w.print("\\{o:0>3}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn writeRange(w: *std.Io.Writer, start: usize, count: usize) std.Io.Writer.Error!void {
    if (count == 1) return w.print("{d}", .{start});
    return w.print("{d},{d}", .{ start, count });
}

pub const Diff = struct {
    /// Sorted by the destination path (the source path for deletions). Owned.
    patches: []Patch,

    pub fn deinit(diff: *Diff, gpa: Allocator) void {
        for (diff.patches) |*patch| patch.deinit(gpa);
        gpa.free(diff.patches);
        diff.* = undefined;
    }

    pub fn writeUnified(diff: Diff, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (diff.patches) |patch| try patch.writeUnified(w);
    }
};

pub const Options = struct {
    context_lines: usize = 3,
    /// Per blob. A review should refuse an accidental giant allocation.
    max_blob_bytes: usize = 64 * 1024 * 1024,
    /// The Myers trace is bounded through this line-count limit.
    max_lines: usize = 200_000,
    /// Upper bound for the Myers trace. Highly dissimilar giant files fail
    /// explicitly instead of turning a review into an unbounded allocation.
    max_diff_memory_bytes: usize = 256 * 1024 * 1024,
    detect_renames: bool = true,
    /// Git enables renames by default but requires `--find-copies` for this.
    detect_copies: bool = false,
};

const Op = struct { origin: Origin, content: []const u8 };

/// Computes a textual patch without touching an object database. The byte
/// slices are borrowed only for the duration of this call; the result owns
/// every path and line.
pub fn diffBlobs(gpa: Allocator, old_path: []const u8, new_path: []const u8, old: []const u8, new: []const u8, options: Options) Error!Patch {
    if (old.len > options.max_blob_bytes or new.len > options.max_blob_bytes) return error.BlobTooLarge;
    const owned_old_path = try gpa.dupe(u8, old_path);
    const owned_new_path = gpa.dupe(u8, new_path) catch |err| {
        gpa.free(owned_old_path);
        return err;
    };
    var patch = Patch{
        .old_path = owned_old_path,
        .new_path = owned_new_path,
        .status = .modified,
    };
    errdefer patch.deinit(gpa);
    if (isBinary(old) or isBinary(new)) {
        patch.binary = !std.mem.eql(u8, old, new);
        return patch;
    }
    if (std.mem.eql(u8, old, new)) return patch;

    const a = try splitLines(gpa, old, options.max_lines);
    defer gpa.free(a);
    const b = try splitLines(gpa, new, options.max_lines);
    defer gpa.free(b);
    const ops = try myers(gpa, a, b, options.max_diff_memory_bytes);
    defer gpa.free(ops);
    patch.hunks = try makeHunks(gpa, ops, options.context_lines);
    return patch;
}

fn isBinary(bytes: []const u8) bool {
    return std.mem.indexOfScalar(u8, bytes[0..@min(bytes.len, 8000)], 0) != null;
}

fn splitLines(gpa: Allocator, bytes: []const u8, max_lines: usize) Error![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(gpa);
    var start: usize = 0;
    while (start < bytes.len) {
        if (lines.items.len == max_lines) return error.TooManyLines;
        const nl = std.mem.indexOfScalarPos(u8, bytes, start, '\n');
        const end = if (nl) |at| at + 1 else bytes.len;
        try lines.append(gpa, bytes[start..end]);
        start = end;
    }
    return lines.toOwnedSlice(gpa);
}

fn myers(gpa: Allocator, a: []const []const u8, b: []const []const u8, max_memory: usize) Error![]Op {
    const max = a.len + b.len;
    const width = max * 2 + 3;
    const offset: isize = @intCast(max + 1);
    var v = try gpa.alloc(isize, width);
    defer gpa.free(v);
    @memset(v, 0);
    var trace: std.ArrayList([]isize) = .empty;
    defer {
        for (trace.items) |row| gpa.free(row);
        trace.deinit(gpa);
    }

    var found_d: usize = 0;
    outer: for (0..max + 1) |d| {
        const rows = std.math.add(usize, d, 1) catch return error.DiffTooLarge;
        const cells = std.math.mul(usize, rows, width) catch return error.DiffTooLarge;
        const bytes = std.math.mul(usize, cells, @sizeOf(isize)) catch return error.DiffTooLarge;
        if (bytes > max_memory) return error.DiffTooLarge;
        const row = try gpa.dupe(isize, v);
        errdefer gpa.free(row);
        try trace.append(gpa, row);
        var k: isize = -@as(isize, @intCast(d));
        while (k <= @as(isize, @intCast(d))) : (k += 2) {
            const idx: usize = @intCast(offset + k);
            var x = if (k == -@as(isize, @intCast(d)) or (k != @as(isize, @intCast(d)) and v[idx - 1] < v[idx + 1])) v[idx + 1] else v[idx - 1] + 1;
            var y = x - k;
            while (x < a.len and y < b.len and std.mem.eql(u8, a[@intCast(x)], b[@intCast(y)])) {
                x += 1;
                y += 1;
            }
            v[idx] = x;
            if (x >= a.len and y >= b.len) {
                found_d = d;
                break :outer;
            }
        }
    }

    var reversed: std.ArrayList(Op) = .empty;
    defer reversed.deinit(gpa);
    var x: isize = @intCast(a.len);
    var y: isize = @intCast(b.len);
    var d = found_d;
    while (d > 0) : (d -= 1) {
        const row = trace.items[d];
        const k = x - y;
        const di: isize = @intCast(d);
        const idx: usize = @intCast(offset + k);
        const prev_k: isize = if (k == -di or (k != di and row[idx - 1] < row[idx + 1])) k + 1 else k - 1;
        const prev_x = row[@intCast(offset + prev_k)];
        const prev_y = prev_x - prev_k;
        while (x > prev_x and y > prev_y) {
            x -= 1;
            y -= 1;
            try reversed.append(gpa, .{ .origin = .context, .content = a[@intCast(x)] });
        }
        if (x == prev_x) {
            y -= 1;
            try reversed.append(gpa, .{ .origin = .addition, .content = b[@intCast(y)] });
        } else {
            x -= 1;
            try reversed.append(gpa, .{ .origin = .deletion, .content = a[@intCast(x)] });
        }
    }
    while (x > 0 and y > 0) {
        x -= 1;
        y -= 1;
        try reversed.append(gpa, .{ .origin = .context, .content = a[@intCast(x)] });
    }
    std.mem.reverse(Op, reversed.items);
    return reversed.toOwnedSlice(gpa);
}

fn makeHunks(gpa: Allocator, ops: []const Op, context: usize) Allocator.Error![]Hunk {
    var changed: std.ArrayList(usize) = .empty;
    defer changed.deinit(gpa);
    for (ops, 0..) |op, i| if (op.origin != .context) try changed.append(gpa, i);
    if (changed.items.len == 0) return gpa.alloc(Hunk, 0);

    var hunks: std.ArrayList(Hunk) = .empty;
    errdefer {
        for (hunks.items) |*h| h.deinit(gpa);
        hunks.deinit(gpa);
    }
    var ci: usize = 0;
    const twice_context = std.math.mul(usize, context, 2) catch std.math.maxInt(usize);
    const join_distance = std.math.add(usize, twice_context, 1) catch std.math.maxInt(usize);
    while (ci < changed.items.len) {
        const first = changed.items[ci];
        var last = first;
        ci += 1;
        while (ci < changed.items.len and changed.items[ci] - last <= join_distance) : (ci += 1) last = changed.items[ci];
        const start = first - @min(first, context);
        const end = @min(ops.len, last + 1 + context);

        var old_start: usize = 1;
        var new_start: usize = 1;
        for (ops[0..start]) |op| switch (op.origin) {
            .context => {
                old_start += 1;
                new_start += 1;
            },
            .deletion => old_start += 1,
            .addition => new_start += 1,
        };
        var old_count: usize = 0;
        var new_count: usize = 0;
        var old_lineno = old_start;
        var new_lineno = new_start;
        var lines: std.ArrayList(Line) = .empty;
        errdefer {
            for (lines.items) |*line| line.deinit(gpa);
            lines.deinit(gpa);
        }
        for (ops[start..end]) |op| {
            if (op.origin != .addition) old_count += 1;
            if (op.origin != .deletion) new_count += 1;
            const content = try gpa.dupe(u8, op.content);
            errdefer gpa.free(content);
            try lines.append(gpa, .{
                .origin = op.origin,
                .old_lineno = if (op.origin == .addition) null else old_lineno,
                .new_lineno = if (op.origin == .deletion) null else new_lineno,
                .content = content,
            });
            if (op.origin != .addition) old_lineno += 1;
            if (op.origin != .deletion) new_lineno += 1;
        }
        var hunk = Hunk{
            .old_start = if (old_count == 0) old_start - 1 else old_start,
            .old_lines = old_count,
            .new_start = if (new_count == 0) new_start - 1 else new_start,
            .new_lines = new_count,
            .lines = try lines.toOwnedSlice(gpa),
        };
        errdefer hunk.deinit(gpa);
        try hunks.append(gpa, hunk);
    }
    return hunks.toOwnedSlice(gpa);
}

const TreeEntry = struct { path: []const u8, mode: FileMode, oid: Oid };

/// Compares two trees. A null side is Git's empty tree. Exact-content
/// renames and copies are recognized without reading a blob twice.
pub fn diffTrees(gpa: Allocator, odb: *Odb, old_tree: ?Oid, new_tree: ?Oid, options: Options, diag: ?*?Diagnostic) Error!Diff {
    var old: std.ArrayList(TreeEntry) = .empty;
    defer freeEntries(gpa, &old);
    var new: std.ArrayList(TreeEntry) = .empty;
    defer freeEntries(gpa, &new);
    if (old_tree) |oid| try flattenTree(gpa, odb, oid, "", &old, diag);
    if (new_tree) |oid| try flattenTree(gpa, odb, oid, "", &new, diag);
    std.mem.sort(TreeEntry, old.items, {}, treeEntryLessThan);
    std.mem.sort(TreeEntry, new.items, {}, treeEntryLessThan);

    var patches: std.ArrayList(Patch) = .empty;
    errdefer {
        for (patches.items) |*p| p.deinit(gpa);
        patches.deinit(gpa);
    }
    var used_old = try gpa.alloc(bool, old.items.len);
    defer gpa.free(used_old);
    @memset(used_old, false);
    var used_new = try gpa.alloc(bool, new.items.len);
    defer gpa.free(used_new);
    @memset(used_new, false);

    // Both flattened trees are sorted, so matching the overwhelmingly common
    // unchanged paths is linear in repository size rather than quadratic.
    var old_at: usize = 0;
    var new_at: usize = 0;
    while (old_at < old.items.len and new_at < new.items.len) {
        const a = old.items[old_at];
        const b = new.items[new_at];
        switch (std.mem.order(u8, a.path, b.path)) {
            .lt => {
                old_at += 1;
                continue;
            },
            .gt => {
                new_at += 1;
                continue;
            },
            .eq => {},
        }
        const ai = old_at;
        const bi = new_at;
        used_old[ai] = true;
        used_new[bi] = true;
        if (!a.oid.eql(b.oid) or a.mode != b.mode) {
            var p = try patchEntries(gpa, odb, a, b, options, diag);
            p.status = if (a.mode != b.mode and modeKind(a.mode) != modeKind(b.mode)) .type_changed else .modified;
            try appendPatch(gpa, &patches, p);
        }
        old_at += 1;
        new_at += 1;
    }

    // Exact renames consume a deletion and addition. Exact copies leave the
    // source available, because it still exists under its original name.
    if (options.detect_renames) for (old.items, 0..) |a, ai| {
        if (used_old[ai]) continue;
        for (new.items, 0..) |b, bi| {
            if (used_new[bi] or !a.oid.eql(b.oid) or modeKind(a.mode) != modeKind(b.mode)) continue;
            const p = try metadataPatch(gpa, a.path, b.path, .renamed, a, b);
            try appendPatch(gpa, &patches, p);
            used_old[ai] = true;
            used_new[bi] = true;
            break;
        }
    };
    if (options.detect_copies) for (new.items, 0..) |b, bi| {
        if (used_new[bi]) continue;
        for (old.items) |a| {
            if (!a.oid.eql(b.oid) or a.mode != b.mode) continue;
            const p = try metadataPatch(gpa, a.path, b.path, .copied, a, b);
            try appendPatch(gpa, &patches, p);
            used_new[bi] = true;
            break;
        }
    };
    for (old.items, 0..) |a, i| if (!used_old[i]) {
        const empty = TreeEntry{ .path = a.path, .mode = a.mode, .oid = Oid.zero(odb.format) };
        var p = try patchEntries(gpa, odb, a, empty, options, diag);
        p.status = .deleted;
        p.new_oid = null;
        p.new_mode = null;
        try appendPatch(gpa, &patches, p);
    };
    for (new.items, 0..) |b, i| if (!used_new[i]) {
        const empty = TreeEntry{ .path = b.path, .mode = b.mode, .oid = Oid.zero(odb.format) };
        var p = try patchEntries(gpa, odb, empty, b, options, diag);
        p.status = .added;
        p.old_oid = null;
        p.old_mode = null;
        try appendPatch(gpa, &patches, p);
    };
    const owned = try patches.toOwnedSlice(gpa);
    std.mem.sort(Patch, owned, {}, struct {
        fn lessThan(_: void, a: Patch, b: Patch) bool {
            const ap = if (a.status == .deleted) a.old_path else a.new_path;
            const bp = if (b.status == .deleted) b.old_path else b.new_path;
            return std.mem.order(u8, ap, bp) == .lt;
        }
    }.lessThan);
    return .{ .patches = owned };
}

/// Reads two commit objects and compares the trees they name.
pub fn diffCommits(gpa: Allocator, odb: *Odb, old_commit: Oid, new_commit: Oid, options: Options, diag: ?*?Diagnostic) Error!Diff {
    const old_bytes = try odb.readAlloc(gpa, old_commit, options.max_blob_bytes, diag);
    defer gpa.free(old_bytes);
    const new_bytes = try odb.readAlloc(gpa, new_commit, options.max_blob_bytes, diag);
    defer gpa.free(new_bytes);
    var old = Commit.parse(gpa, odb.format, old_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CorruptCommit => return error.CorruptObject,
    };
    defer old.deinit(gpa);
    var new = Commit.parse(gpa, odb.format, new_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CorruptCommit => return error.CorruptObject,
    };
    defer new.deinit(gpa);
    return diffTrees(gpa, odb, old.tree, new.tree, options, diag);
}

fn flattenTree(gpa: Allocator, odb: *Odb, oid: Oid, prefix: []const u8, out: *std.ArrayList(TreeEntry), diag: ?*?Diagnostic) Error!void {
    const bytes = try odb.readAlloc(gpa, oid, 16 * 1024 * 1024, diag);
    defer gpa.free(bytes);
    var tree = Tree.parse(gpa, odb.format, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CorruptTree => return error.CorruptObject,
    };
    defer tree.deinit(gpa);
    for (tree.entries) |entry| {
        const path = if (prefix.len == 0) try gpa.dupe(u8, entry.name) else try std.fmt.allocPrint(gpa, "{s}/{s}", .{ prefix, entry.name });
        if (entry.mode == .tree) {
            defer gpa.free(path);
            try flattenTree(gpa, odb, entry.oid, path, out, diag);
        } else {
            out.append(gpa, .{ .path = path, .mode = entry.mode, .oid = entry.oid }) catch |err| {
                gpa.free(path);
                return err;
            };
        }
    }
}

fn freeEntries(gpa: Allocator, entries: *std.ArrayList(TreeEntry)) void {
    for (entries.items) |entry| gpa.free(entry.path);
    entries.deinit(gpa);
}

fn treeEntryLessThan(_: void, a: TreeEntry, b: TreeEntry) bool {
    return std.mem.order(u8, a.path, b.path) == .lt;
}

fn modeKind(mode: FileMode) enum { blob, symlink, gitlink } {
    return switch (mode) {
        .blob, .blob_executable => .blob,
        .symlink => .symlink,
        .gitlink => .gitlink,
        .tree => unreachable,
    };
}

fn metadataPatch(gpa: Allocator, old_path: []const u8, new_path: []const u8, status: Status, old: TreeEntry, new: TreeEntry) Allocator.Error!Patch {
    const owned_old_path = try gpa.dupe(u8, old_path);
    errdefer gpa.free(owned_old_path);
    const owned_new_path = try gpa.dupe(u8, new_path);
    return .{
        .old_path = owned_old_path,
        .new_path = owned_new_path,
        .status = status,
        .old_mode = old.mode,
        .new_mode = new.mode,
        .old_oid = old.oid,
        .new_oid = new.oid,
        .similarity = if (status == .renamed or status == .copied) 100 else 0,
    };
}

fn appendPatch(gpa: Allocator, list: *std.ArrayList(Patch), patch: Patch) Allocator.Error!void {
    var owned = patch;
    errdefer owned.deinit(gpa);
    try list.append(gpa, owned);
}

fn patchEntries(gpa: Allocator, odb: *Odb, old: TreeEntry, new: TreeEntry, options: Options, diag: ?*?Diagnostic) Error!Patch {
    if (old.mode == .gitlink or new.mode == .gitlink) return metadataPatch(gpa, old.path, new.path, .modified, old, new);
    const old_bytes = if (old.oid.isZero()) try gpa.alloc(u8, 0) else try odb.readAlloc(gpa, old.oid, options.max_blob_bytes, diag);
    defer gpa.free(old_bytes);
    const new_bytes = if (new.oid.isZero()) try gpa.alloc(u8, 0) else try odb.readAlloc(gpa, new.oid, options.max_blob_bytes, diag);
    defer gpa.free(new_bytes);
    var p = try diffBlobs(gpa, old.path, new.path, old_bytes, new_bytes, options);
    p.old_mode = old.mode;
    p.new_mode = new.mode;
    p.old_oid = old.oid;
    p.new_oid = new.oid;
    return p;
}

const testing = std.testing;

test "diffBlobs exposes separated hunks and owns their lines" {
    const old = "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\n";
    const new = "one\nTWO\nthree\nfour\nfive\nsix\nSEVEN\neight\n";
    var patch = try diffBlobs(testing.allocator, "notes.txt", "notes.txt", old, new, .{ .context_lines = 1 });
    defer patch.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), patch.hunks.len);
    try testing.expectEqual(@as(usize, 2), patch.additions());
    try testing.expectEqual(@as(usize, 2), patch.deletions());
    try testing.expectEqualStrings("two\n", patch.hunks[0].lines[1].content);
    try testing.expectEqual(Origin.deletion, patch.hunks[0].lines[1].origin);
    try testing.expectEqual(@as(?usize, 2), patch.hunks[0].lines[1].old_lineno);
    try testing.expectEqual(@as(?usize, null), patch.hunks[0].lines[1].new_lineno);
}

test "unified rendering marks a missing final newline" {
    var patch = try diffBlobs(testing.allocator, "a", "a", "old", "new", .{});
    defer patch.deinit(testing.allocator);
    var storage: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&storage);
    try patch.writeUnified(&w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "-old\n\\ No newline at end of file\n+new") != null);
}

test "binary input produces metadata without text hunks" {
    var patch = try diffBlobs(testing.allocator, "image", "image", "a\x00b", "c\x00d", .{});
    defer patch.deinit(testing.allocator);
    try testing.expect(patch.binary);
    try testing.expectEqual(@as(usize, 0), patch.hunks.len);
}

test "the diff memory budget is an explicit refusal" {
    try testing.expectError(error.DiffTooLarge, diffBlobs(
        testing.allocator,
        "large.txt",
        "large.txt",
        "one\ntwo\nthree\n",
        "four\nfive\nsix\n",
        .{ .max_diff_memory_bytes = 1 },
    ));
}

test "tree diffs expose additions modifications and exact renames" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "objects");
    const objects = try tmp.dir.openDir(io, "objects", .{ .iterate = true });
    var odb = try Odb.init(gpa, io, objects, .sha1, .{});
    defer odb.deinit();

    const old_edit = try odb.write(.blob, "before\n", null);
    const new_edit = try odb.write(.blob, "after\n", null);
    const renamed = try odb.write(.blob, "same bytes\n", null);
    const added = try odb.write(.blob, "new\n", null);
    const old_tree = try writeTestTree(&odb, &.{
        .{ .mode = .blob, .name = "edit.txt", .oid = old_edit },
        .{ .mode = .blob, .name = "old.txt", .oid = renamed },
    });
    const new_tree = try writeTestTree(&odb, &.{
        .{ .mode = .blob, .name = "added.txt", .oid = added },
        .{ .mode = .blob, .name = "edit.txt", .oid = new_edit },
        .{ .mode = .blob, .name = "new.txt", .oid = renamed },
    });

    var result = try diffTrees(gpa, &odb, old_tree, new_tree, .{}, null);
    defer result.deinit(gpa);
    try testing.expectEqual(@as(usize, 3), result.patches.len);
    try testing.expectEqual(Status.added, result.patches[0].status);
    try testing.expectEqual(Status.modified, result.patches[1].status);
    try testing.expectEqual(Status.renamed, result.patches[2].status);
    try testing.expectEqual(@as(u8, 100), result.patches[2].similarity);
    try testing.expectEqualStrings("old.txt", result.patches[2].old_path);
    try testing.expectEqualStrings("new.txt", result.patches[2].new_path);
}

fn writeTestTree(odb: *Odb, entries: []const Tree.Entry) !Oid {
    const tree: Tree = .{ .entries = entries };
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try tree.write(&w);
    return odb.write(.tree, w.buffered(), null);
}
