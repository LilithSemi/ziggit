//! The packed object half of `Odb`: every `.pack`/`.idx` pair under one
//! `objects/pack` directory, kept open for as long as the `PackSet` lives.
//! `Odb` decides which directories to build one of these for; this file
//! only ever looks inside the single directory it was given.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;

const core_mod = @import("ziggit-core");
const ObjectKind = core_mod.ObjectKind;
const Diagnostic = core_mod.Diagnostic;

const pack_mod = @import("ziggit-pack");
const Pack = pack_mod.Pack;
const Index = pack_mod.Index;

const ObjectStat = @import("object_stat.zig").ObjectStat;

// `Index.Error`'s two members, `CorruptIndex` and `UnsupportedIndexVersion`,
// both mean the same thing to a caller: the on-disk index is bad data, not
// a transient fault. Both map to `CorruptObject` below, the member
// `Odb.Error` already declares for exactly that shape of failure, rather
// than folding them into `IoFailed`, which reads as retryable.
pub const Error = error{ IoFailed, CorruptObject } || Pack.Error || Allocator.Error;

const Entry = struct {
    /// The pack's file stem, e.g. "pack-<sha>", shared by its `.pack` and
    /// `.idx` files. Owned by this entry, freed by `deinit`.
    stem: []u8,
    /// Kept open for the pack's whole lifetime: `Pack.readAt` reads
    /// through it lazily on every call, not only when the pack is opened.
    file: std.Io.File,
    pack: Pack,
    index: Index,

    fn deinit(e: *Entry, gpa: Allocator, io: std.Io) void {
        e.pack.deinit();
        e.index.deinit();
        e.file.close(io);
        gpa.free(e.stem);
        e.* = undefined;
    }
};

pub const PackSet = struct {
    gpa: Allocator,
    io: std.Io,
    format: Format,
    /// Owned by this set, freed (each entry, then the list) by `deinit`.
    entries: std.ArrayList(Entry),

    pub fn init(gpa: Allocator, io: std.Io, format: Format) PackSet {
        return .{ .gpa = gpa, .io = io, .format = format, .entries = .empty };
    }

    pub fn deinit(ps: *PackSet) void {
        for (ps.entries.items) |*e| e.deinit(ps.gpa, ps.io);
        ps.entries.deinit(ps.gpa);
        ps.* = undefined;
    }

    /// Scans `objects_dir`'s `pack` subdirectory for `.idx` files this set
    /// does not already know about, and opens each one together with its
    /// matching `.pack` file. A missing `pack` subdirectory is not an
    /// error: a fresh repository, or an alternate holding only loose
    /// objects, has none.
    pub fn refresh(ps: *PackSet, objects_dir: std.Io.Dir) Error!void {
        var pack_dir = objects_dir.openDir(ps.io, "pack", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return error.IoFailed,
        };
        defer pack_dir.close(ps.io);

        var it = pack_dir.iterate();
        while (it.next(ps.io) catch return error.IoFailed) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".idx")) continue;
            // `endsWith` just above guarantees `entry.name.len >=
            // ".idx".len`, so this cannot underflow.
            const stem = entry.name[0 .. entry.name.len - ".idx".len];
            if (ps.knows(stem)) continue;

            const pack_name = try std.fmt.allocPrint(ps.gpa, "{s}.pack", .{stem});
            defer ps.gpa.free(pack_name);

            var pack_file = pack_dir.openFile(ps.io, pack_name, .{}) catch return error.IoFailed;
            errdefer pack_file.close(ps.io);

            var index = blk: {
                var idx_file = pack_dir.openFile(ps.io, entry.name, .{}) catch return error.IoFailed;
                defer idx_file.close(ps.io);
                break :blk Index.open(ps.gpa, ps.io, idx_file, ps.format) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.CorruptIndex, error.UnsupportedIndexVersion => return error.CorruptObject,
                };
            };
            errdefer index.deinit();

            const pack = try Pack.open(ps.gpa, ps.io, pack_file, ps.format);

            const stem_owned = try ps.gpa.dupe(u8, stem);
            try ps.entries.append(ps.gpa, .{ .stem = stem_owned, .file = pack_file, .pack = pack, .index = index });
        }
    }

    fn knows(ps: PackSet, stem: []const u8) bool {
        for (ps.entries.items) |e| {
            if (std.mem.eql(u8, e.stem, stem)) return true;
        }
        return false;
    }

    fn find(ps: *PackSet, oid: Oid) ?struct { entry: *Entry, offset: u64 } {
        for (ps.entries.items) |*e| {
            if (e.index.offsetOf(oid)) |off| return .{ .entry = e, .offset = off };
        }
        return null;
    }

    pub fn exists(ps: *PackSet, oid: Oid) bool {
        return ps.find(oid) != null;
    }

    /// Streams `oid`'s reconstructed payload into `w`. Returns null when
    /// no pack in this set holds `oid`.
    pub fn read(ps: *PackSet, gpa: Allocator, oid: Oid, w: *std.Io.Writer, diag: ?*?Diagnostic) Error!?ObjectKind {
        const found = ps.find(oid) orelse return null;
        return try found.entry.pack.readAt(gpa, found.offset, w, diag);
    }

    /// The kind and final size of `oid`, or null when no pack in this set
    /// holds it. A non-delta entry could answer this from its own header
    /// alone, but the pack format gives a delta entry's final size only by
    /// resolving its chain; this always resolves fully, streaming the
    /// reconstructed bytes into a discarding writer rather than an
    /// allocation, so it never costs more memory than `read` would.
    pub fn stat(ps: *PackSet, gpa: Allocator, oid: Oid, diag: ?*?Diagnostic) Error!?ObjectStat {
        const found = ps.find(oid) orelse return null;
        var discarding: std.Io.Writer.Discarding = .init(&.{});
        const kind = try found.entry.pack.readAt(gpa, found.offset, &discarding.writer, diag);
        return .{ .kind = kind, .size = discarding.fullCount() };
    }

    /// Adds every id in this set matching `hex_prefix` to `acc`, the
    /// caller's running total across every backend and every alternate.
    pub fn findPrefix(ps: *PackSet, hex_prefix: []const u8, acc: anytype) void {
        for (ps.entries.items) |e| {
            var out: [4]Oid = undefined;
            const matched = e.index.findPrefix(hex_prefix, &out);
            acc.addMany(matched, out[0..@min(matched, out.len)]);
        }
    }
};

// expected

test "read finds an object that lives in a pack" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try buildPackAndIndex(gpa, io, tmp.dir, &.{"hello\n"});

    var ps = PackSet.init(gpa, io, .sha1);
    defer ps.deinit();
    try ps.refresh(tmp.dir);

    const oid = object_hash(.blob, "hello\n");
    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const kind = (try ps.read(gpa, oid, &out, null)).?;
    try std.testing.expectEqual(ObjectKind.blob, kind);
    try std.testing.expectEqualStrings("hello\n", out.buffered());
}

test "refreshPacks picks up a pack added after init" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var ps = PackSet.init(gpa, io, .sha1);
    defer ps.deinit();
    try ps.refresh(tmp.dir);

    const oid = object_hash(.blob, "hello\n");
    try std.testing.expect(!ps.exists(oid));

    try buildPackAndIndex(gpa, io, tmp.dir, &.{"hello\n"});
    try ps.refresh(tmp.dir);
    try std.testing.expect(ps.exists(oid));
}

// suspicious

test "PackSet stat resolves a plain packed object to its kind and size" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try buildPackAndIndex(gpa, io, tmp.dir, &.{"hello world"});

    var ps = PackSet.init(gpa, io, .sha1);
    defer ps.deinit();
    try ps.refresh(tmp.dir);

    const oid = object_hash(.blob, "hello world");
    const info = (try ps.stat(gpa, oid, null)).?;
    try std.testing.expectEqual(ObjectKind.blob, info.kind);
    try std.testing.expectEqual(@as(u64, "hello world".len), info.size);
}

test "PackSet read returns null for an id no pack in the set holds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try buildPackAndIndex(gpa, io, tmp.dir, &.{"hello\n"});

    var ps = PackSet.init(gpa, io, .sha1);
    defer ps.deinit();
    try ps.refresh(tmp.dir);

    const absent = Oid.zero(.sha1);
    var out_buf: [16]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try std.testing.expect((try ps.read(gpa, absent, &out, null)) == null);
}

test "refresh is idempotent: calling it twice does not open a pack twice" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try buildPackAndIndex(gpa, io, tmp.dir, &.{"hello\n"});

    var ps = PackSet.init(gpa, io, .sha1);
    defer ps.deinit();
    try ps.refresh(tmp.dir);
    try ps.refresh(tmp.dir);
    try std.testing.expectEqual(@as(usize, 1), ps.entries.items.len);
}

// Test helpers: `ziggit-pack`'s own byte-exact pack builder is a private
// test helper of that module, not part of the surface `ziggit-odb`
// consumes, so a small one is built here instead: plain (non-delta) blob
// entries only, since nothing this file tests needs a delta chain (that
// belongs to `ziggit-pack`'s own suite). `writeIndex`, the one genuinely
// shared piece, is `ziggit-pack`'s real public entry point.
fn object_hash(kind: ObjectKind, payload: []const u8) Oid {
    const object_mod = @import("ziggit-object");
    return object_mod.loose.hash(.sha1, kind, payload);
}

fn writeVarintHeader(w: *std.Io.Writer, type_bits: u3, size_in: u64) !void {
    var value = size_in;
    var first_byte: u8 = (@as(u8, type_bits) << 4) | @as(u8, @truncate(value & 0x0f));
    value >>= 4;
    if (value != 0) first_byte |= 0x80;
    try w.writeByte(first_byte);
    while (value != 0) {
        var b: u8 = @truncate(value & 0x7f);
        value >>= 7;
        if (value != 0) b |= 0x80;
        try w.writeByte(b);
    }
}

fn buildRawPack(gpa: Allocator, format: Format, payloads: []const []const u8) ![]u8 {
    var aw = try std.Io.Writer.Allocating.initCapacity(gpa, 256);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("PACK");
    try w.writeInt(u32, 2, .big);
    try w.writeInt(u32, @intCast(payloads.len), .big);

    for (payloads) |p| {
        try writeVarintHeader(w, 3, p.len); // 3 == blob, matching EntryType
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var compress = try std.compress.flate.Compress.init(w, &window, .zlib, .default);
        try compress.writer.writeAll(p);
        try compress.finish();
    }

    var hasher = oid_mod.Hasher.init(format);
    hasher.update(aw.writer.buffered());
    const trailer = hasher.final();
    try w.writeAll(trailer.slice());

    return aw.toOwnedSlice();
}

fn buildPackAndIndex(gpa: Allocator, io: std.Io, objects_dir: std.Io.Dir, payloads: []const []const u8) !void {
    const bytes = try buildRawPack(gpa, .sha1, payloads);
    defer gpa.free(bytes);

    try objects_dir.createDirPath(io, "pack");
    try objects_dir.writeFile(io, .{ .sub_path = "pack/pack-1.pack", .data = bytes });

    var pack_dir = try objects_dir.openDir(io, "pack", .{ .iterate = true });
    defer pack_dir.close(io);

    var pack_read_buf: [4096]u8 = undefined;
    var pack_file_for_index = try pack_dir.openFile(io, "pack-1.pack", .{});
    defer pack_file_for_index.close(io);
    var pack_reader = pack_file_for_index.reader(io, &pack_read_buf);

    var idx_write_buf: [4096]u8 = undefined;
    var idx_file = try pack_dir.createFile(io, "pack-1.idx", .{ .read = true });
    defer idx_file.close(io);
    var idx_writer = idx_file.writer(io, &idx_write_buf);

    try pack_mod.writeIndex(gpa, .sha1, &pack_reader, &idx_writer, null);
}
