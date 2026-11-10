//! Writes a packfile: the "PACK" header, every object whole and
//! zlib-deflated behind its type and size varint, then the hash of
//! everything written.
//!
//! No deltas. Each object goes out at full size, which keeps a push of a
//! few commits small and spends bandwidth on a long history. A later
//! delta pass fits behind this same signature.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;
const ObjectKind = core_mod.ObjectKind;

pub const Error = error{
    IoFailed,
    ObjectMissing,
    ObjectUnreadable,
    SizeMismatch,
    TooManyObjects,
};

/// Where the objects come from. This module keeps no database policy, so
/// the caller supplies the two reads a pack needs. `ziggit-push` wires
/// this to an `Odb`.
pub const Source = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const Stat = struct { kind: ObjectKind, size: u64 };

    pub const VTable = struct {
        stat: *const fn (ctx: *anyopaque, oid: Oid) Error!Stat,
        /// Writes the payload alone, `stat`'s `size` bytes of it, with no
        /// loose object header in front.
        read: *const fn (ctx: *anyopaque, oid: Oid, w: *std.Io.Writer) Error!void,
    };

    pub fn stat(s: Source, oid: Oid) Error!Stat {
        return s.vtable.stat(s.ctx, oid);
    }

    pub fn read(s: Source, oid: Oid, w: *std.Io.Writer) Error!void {
        return s.vtable.read(s.ctx, oid, w);
    }
};

/// Writes `oids` to `out` as one pack and answers with the pack's own
/// trailing hash, which is the name a receiver stores it under.
pub fn writePack(
    gpa: Allocator,
    f: Format,
    source: Source,
    oids: []const Oid,
    out: *std.Io.Writer,
    diag: ?*?Diagnostic,
) Error!Oid {
    if (oids.len > std.math.maxInt(u32)) return error.TooManyObjects;

    // `Compress` asserts its destination holds a buffer, and the hash only
    // advances as that buffer drains, so the flush below the loop is what
    // makes the trailer cover every byte.
    var hash_buf: [4096]u8 = undefined;
    var hashed = out.hashed(oid_mod.Hasher.init(f), &hash_buf);
    const w = &hashed.writer;

    w.writeAll("PACK") catch return error.IoFailed;
    w.writeInt(u32, 2, .big) catch return error.IoFailed;
    w.writeInt(u32, @intCast(oids.len), .big) catch return error.IoFailed;

    for (oids) |oid| {
        const info = try source.stat(oid);
        writeEntryHeader(w, packType(info.kind), info.size) catch return error.IoFailed;

        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var compress = std.compress.flate.Compress.init(w, &window, .zlib, .default) catch
            return error.IoFailed;

        // The entry header already states the payload length, so a source
        // that writes a different number of bytes produces a pack the
        // receiver rejects. Counting catches that here instead.
        var counted = compress.writer.hashed(Counter{}, &.{});
        try source.read(oid, &counted.writer);
        counted.writer.flush() catch return error.IoFailed;
        compress.finish() catch return error.IoFailed;

        if (counted.hasher.n != info.size) {
            reportPack(diag, gpa, "an object's payload length disagrees with its header");
            return error.SizeMismatch;
        }
    }

    w.flush() catch return error.IoFailed;
    const checksum = hashed.hasher.final();
    out.writeAll(checksum.slice()) catch return error.IoFailed;
    return checksum;
}

fn reportPack(diag: ?*?Diagnostic, gpa: Allocator, detail: []const u8) void {
    if (!core_mod.wants(diag)) return;
    const detail_dup = gpa.dupe(u8, detail) catch null;
    core_mod.report(diag, gpa, .{ .kind = .corrupt_pack, .path = null, .detail = detail_dup });
}

/// Rides `std.Io.Writer.Hashed`, which asks only for `update`, to count
/// bytes rather than hash them.
const Counter = struct {
    n: u64 = 0,

    pub fn update(self: *Counter, bytes: []const u8) void {
        self.n += bytes.len;
    }
};

/// The pack entry type numbers, which are not the `ObjectKind` tag
/// values: a pack counts from one and leaves room for the two delta
/// types at six and seven.
fn packType(kind: ObjectKind) u3 {
    return switch (kind) {
        .commit => 1,
        .tree => 2,
        .blob => 3,
        .tag => 4,
    };
}

/// The type in the top three bits of the first byte, then the size in
/// little endian groups: four bits in that same first byte and seven in
/// each byte after it, high bit set while more follow.
fn writeEntryHeader(w: *std.Io.Writer, type_bits: u3, size_in: u64) !void {
    var value = size_in;
    var first: u8 = (@as(u8, type_bits) << 4) | @as(u8, @truncate(value & 0x0f));
    value >>= 4;
    if (value != 0) first |= 0x80;
    try w.writeByte(first);
    while (value != 0) {
        var b: u8 = @truncate(value & 0x7f);
        value >>= 7;
        if (value != 0) b |= 0x80;
        try w.writeByte(b);
    }
}

const testing = std.testing;
const pack_mod = @import("Pack.zig");
const Pack = pack_mod.Pack;

/// Serves objects from a fixed list, keyed by the id of their payload.
const MapSource = struct {
    items: []const Item,

    const Item = struct { oid: Oid, kind: ObjectKind, payload: []const u8 };

    fn find(self: *const MapSource, oid: Oid) ?Item {
        for (self.items) |it| {
            if (it.oid.eql(oid)) return it;
        }
        return null;
    }

    fn statFn(ctx: *anyopaque, oid: Oid) Error!Source.Stat {
        const self: *const MapSource = @ptrCast(@alignCast(ctx));
        const it = self.find(oid) orelse return error.ObjectMissing;
        return .{ .kind = it.kind, .size = it.payload.len };
    }

    fn readFn(ctx: *anyopaque, oid: Oid, w: *std.Io.Writer) Error!void {
        const self: *const MapSource = @ptrCast(@alignCast(ctx));
        const it = self.find(oid) orelse return error.ObjectMissing;
        w.writeAll(it.payload) catch return error.IoFailed;
    }

    const vtable: Source.VTable = .{ .stat = statFn, .read = readFn };

    fn source(self: *const MapSource) Source {
        return .{ .ctx = @ptrCast(@constCast(self)), .vtable = &vtable };
    }
};

fn oidOf(kind: ObjectKind, payload: []const u8) Oid {
    var hasher = oid_mod.Hasher.init(.sha1);
    var head_buf: [64]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "{s} {d}\x00", .{ @tagName(kind), payload.len }) catch
        unreachable;
    hasher.update(head);
    hasher.update(payload);
    return hasher.final();
}

test "a written pack carries the header, the count and the trailer" {
    const gpa = testing.allocator;
    const payload = "hello\n";
    const items = [_]MapSource.Item{
        .{ .oid = oidOf(.blob, payload), .kind = .blob, .payload = payload },
    };
    var src: MapSource = .{ .items = &items };

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const oids = [_]Oid{items[0].oid};
    const pack_oid = try writePack(gpa, .sha1, src.source(), &oids, &aw.writer, null);

    const bytes = aw.written();
    try testing.expectEqualStrings("PACK", bytes[0..4]);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, bytes[4..8], .big));
    try testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, bytes[8..12], .big));

    // The answer is the trailer, which is the name a receiver files the
    // pack under.
    try testing.expectEqualSlices(u8, pack_oid.slice(), bytes[bytes.len - 20 ..]);
}

test "every object written comes back out of the pack reader" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const commit = "tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n";
    const tree = "";
    const blob = "contents\n";
    const items = [_]MapSource.Item{
        .{ .oid = oidOf(.commit, commit), .kind = .commit, .payload = commit },
        .{ .oid = oidOf(.tree, tree), .kind = .tree, .payload = tree },
        .{ .oid = oidOf(.blob, blob), .kind = .blob, .payload = blob },
    };
    var src: MapSource = .{ .items = &items };

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var oids: [3]Oid = undefined;
    for (items, 0..) |it, i| oids[i] = it.oid;
    _ = try writePack(gpa, .sha1, src.source(), &oids, &aw.writer, null);

    try tmp.dir.writeFile(io, .{ .sub_path = "t.pack", .data = aw.written() });
    const file = try tmp.dir.openFile(io, "t.pack", .{});
    defer file.close(io);
    var pack = try Pack.open(gpa, io, file, .sha1);
    defer pack.deinit();

    try testing.expectEqual(@as(u32, 3), pack.objectCount());
    try pack.verifyChecksum();

    // Reading by id rather than by offset proves the ids the reader
    // derives from the written bytes are the ids that went in.
    var entries = try pack_mod.computeOidOffsets(gpa, .sha1, &pack.reader, null);
    defer entries.deinit(gpa);
    for (items) |it| {
        const entry = entries.get(it.oid) orelse return error.TestExpectedObjectInPack;
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const kind = try pack.readAt(gpa, entry.offset, &out.writer, null);
        try testing.expectEqual(it.kind, kind);
        try testing.expectEqualStrings(it.payload, out.written());
    }
}

test "an empty object set writes a pack of no objects" {
    const gpa = testing.allocator;
    var src: MapSource = .{ .items = &.{} };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    _ = try writePack(gpa, .sha1, src.source(), &.{}, &aw.writer, null);
    const bytes = aw.written();
    try testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, bytes[8..12], .big));
    try testing.expectEqual(@as(usize, 32), bytes.len);
}

test "a source whose payload is shorter than its stat is refused" {
    const gpa = testing.allocator;
    const items = [_]MapSource.Item{
        .{ .oid = oidOf(.blob, "x"), .kind = .blob, .payload = "x" },
    };
    var src: MapSource = .{ .items = &items };
    // Claim four bytes and hand over one.
    const lying: Source.VTable = .{
        .stat = struct {
            fn f(_: *anyopaque, _: Oid) Error!Source.Stat {
                return .{ .kind = .blob, .size = 4 };
            }
        }.f,
        .read = MapSource.readFn,
    };
    const source: Source = .{ .ctx = @ptrCast(@constCast(&src)), .vtable = &lying };

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const oids = [_]Oid{items[0].oid};
    try testing.expectError(
        error.SizeMismatch,
        writePack(gpa, .sha1, source, &oids, &aw.writer, null),
    );
}
