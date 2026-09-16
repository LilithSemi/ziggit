//! Writes a `.idx` version 2 file for a pack: the fanout table, sorted
//! ids, per-object crc32, 32 bit offsets, and a 64 bit overflow table for
//! any offset a 31 bit field cannot hold.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;

const pack_mod = @import("Pack.zig");
const Pack = pack_mod.Pack;

const object_mod = @import("ziggit-object");

/// Writes a v2 `.idx` for `pack` into `out`. Two passes, delegated to
/// `Pack.zig`'s `computeOidOffsets`: the first hashes every non-delta
/// object and records the deltas it could not resolve yet, the second
/// drains the pending deltas until none are left, so a delta whose base
/// appears later in the pack still resolves.
///
/// `out` failing to accept a write is `error.IoFailed`, distinct from
/// `error.CorruptPack`: the fault is in the destination this write is
/// going to, not in the pack being read to build it.
pub fn writeIndex(
    gpa: Allocator,
    f: Format,
    pack: *std.Io.File.Reader,
    out: *std.Io.File.Writer,
    diag: ?*?Diagnostic,
) Pack.Error!void {
    var entries = try pack_mod.computeOidOffsets(gpa, f, pack, diag);
    defer entries.deinit(gpa);

    const n = entries.count();
    const oids = try gpa.alloc(Oid, n);
    defer gpa.free(oids);
    {
        var it = entries.keyIterator();
        var idx: usize = 0;
        while (it.next()) |k| : (idx += 1) oids[idx] = k.*;
    }
    std.mem.sortUnstable(Oid, oids, {}, lessThanOid);

    var fanout: [256]u32 = undefined;
    buildFanout(&fanout, oids);

    var big_offsets: std.ArrayList(u64) = .empty;
    defer big_offsets.deinit(gpa);

    var hashed = out.interface.hashed(oid_mod.Hasher.init(f), &.{});
    const w = &hashed.writer;

    w.writeAll("\xfftOc") catch return error.IoFailed;
    w.writeInt(u32, 2, .big) catch return error.IoFailed;
    for (fanout) |v| w.writeInt(u32, v, .big) catch return error.IoFailed;
    for (oids) |oid| w.writeAll(oid.slice()) catch return error.IoFailed;
    for (oids) |oid| {
        const e = entries.get(oid).?;
        w.writeInt(u32, e.crc32, .big) catch return error.IoFailed;
    }
    for (oids) |oid| {
        const e = entries.get(oid).?;
        if (e.offset <= std.math.maxInt(u31)) {
            w.writeInt(u32, @intCast(e.offset), .big) catch return error.IoFailed;
        } else {
            const big_index = big_offsets.items.len;
            if (big_index > std.math.maxInt(u31)) return error.CorruptPack;
            big_offsets.append(gpa, e.offset) catch |err| return err;
            w.writeInt(u32, @as(u32, @intCast(big_index)) | 0x8000_0000, .big) catch return error.IoFailed;
        }
    }
    for (big_offsets.items) |off| w.writeInt(u64, off, .big) catch return error.IoFailed;

    // The pack checksum embedded in the index is the pack's own trailer,
    // not a value re-derived here: `computeOidOffsets` leaves `pack`
    // positioned right after the last object's compressed bytes, exactly
    // where that trailer starts.
    const pack_checksum = try readPackTrailer(f, pack);
    w.writeAll(pack_checksum.slice()) catch return error.IoFailed;

    const idx_checksum = hashed.hasher.final();
    out.interface.writeAll(idx_checksum.slice()) catch return error.IoFailed;
    out.end() catch return error.IoFailed;
}

fn lessThanOid(_: void, a: Oid, b: Oid) bool {
    return a.order(b) == .lt;
}

/// `fanout[k]` must end up holding the count of ids whose first byte is at
/// most `k`, so a bucket is not finalized as soon as its key is reached: it
/// is finalized only once every id sharing that key has been counted,
/// which this only knows once a strictly higher key (or the end of
/// `sorted_oids`) is reached.
fn buildFanout(fanout: *[256]u32, sorted_oids: []const Oid) void {
    var bucket: u16 = 0;
    var count: u32 = 0;
    for (sorted_oids) |oid| {
        const key = oid.slice()[0];
        while (bucket < key) : (bucket += 1) fanout[bucket] = count;
        count += 1;
    }
    while (bucket <= 255) : (bucket += 1) fanout[bucket] = count;
}

fn readPackTrailer(f: Format, pack: *std.Io.File.Reader) Pack.Error!Oid {
    const len = f.byteLength();
    var buf: [Oid.max_byte_length]u8 = undefined;
    const bytes = pack.interface.take(len) catch return error.CorruptPack;
    @memcpy(buf[0..len], bytes);
    return Oid.fromBytes(f, buf[0..len]);
}

const index_mod = @import("Index.zig");
const Index = index_mod.Index;

fn buildAndOpenIndex(
    gpa: Allocator,
    tmp_dir: std.Io.Dir,
    io: std.Io,
    f: Format,
    pack_bytes: []const u8,
) !Index {
    try tmp_dir.writeFile(io, .{ .sub_path = "w.pack", .data = pack_bytes });
    const pack_file = try tmp_dir.openFile(io, "w.pack", .{});
    defer pack_file.close(io);
    var pack_read_buf: [4096]u8 = undefined;
    var pack_reader = pack_file.reader(io, &pack_read_buf);

    const idx_file = try tmp_dir.createFile(io, "w.idx", .{ .read = true });
    defer idx_file.close(io);
    var idx_write_buf: [4096]u8 = undefined;
    var idx_writer = idx_file.writer(io, &idx_write_buf);

    try writeIndex(gpa, f, &pack_reader, &idx_writer, null);

    return Index.open(gpa, io, idx_file, f);
}

// expected

test "writeIndex produces an index whose offsets readAt can use" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_payload = "hello world";
    const base_id = object_mod.loose.hash(f_sha1, .blob, base_payload);
    // base_size=11, result_size=5, copy(offset=0, size=5) -> "hello".
    const patch = [_]u8{ 11, 5, 0x91, 0, 5 };

    var built = try buildTestPack(gpa, f_sha1, &.{
        .{ .object = .{ .kind = .blob, .payload = base_payload } },
        .{ .ref_delta = .{ .base_id = base_id, .patch = &patch } },
    });
    defer built.deinit(gpa);

    var idx = try buildAndOpenIndex(gpa, tmp.dir, io, f_sha1, built.bytes);
    defer idx.deinit();
    try std.testing.expectEqual(@as(u32, 2), idx.count());

    const delta_offset = idx.offsetOf(base_id) orelse unreachable;
    try std.testing.expectEqual(built.offsets[0], delta_offset);

    try tmp.dir.writeFile(io, .{ .sub_path = "w2.pack", .data = built.bytes });
    const pack_file = try tmp.dir.openFile(io, "w2.pack", .{});
    defer pack_file.close(io);
    var pack = try Pack.open(gpa, io, pack_file, f_sha1);
    defer pack.deinit();

    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    _ = try pack.readAt(gpa, built.offsets[1], &out, null);
    try std.testing.expectEqualStrings("hello", out.buffered());
}

test "writeIndex resolves a delta whose base appears after it in the pack" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_payload = "hello world";
    const base_id = object_mod.loose.hash(f_sha1, .blob, base_payload);
    // base_size=11, result_size=5, copy(offset=6, size=5) -> "world".
    const patch = [_]u8{ 11, 5, 0x91, 6, 5 };

    // The ref-delta is written first; its base, the plain blob, follows it.
    var built = try buildTestPack(gpa, f_sha1, &.{
        .{ .ref_delta = .{ .base_id = base_id, .patch = &patch } },
        .{ .object = .{ .kind = .blob, .payload = base_payload } },
    });
    defer built.deinit(gpa);

    var idx = try buildAndOpenIndex(gpa, tmp.dir, io, f_sha1, built.bytes);
    defer idx.deinit();
    try std.testing.expectEqual(@as(u32, 2), idx.count());

    const delta_oid = object_mod.loose.hash(f_sha1, .blob, "world");
    const found_offset = idx.offsetOf(delta_oid) orelse unreachable;
    try std.testing.expectEqual(built.offsets[0], found_offset);
}

test "buildFanout finds both ids when two ids share a leading byte" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Chosen by search, not guessed: both blob ids happen to start with
    // 0x00. sha1("blob 11\x00payload-850") =
    // 00ed1f0a43181a43c1542de00d8adba34914d4c7; sha1("blob 11\x00payload-892")
    // = 00c3a1596b7ebffe187229206260c36aa00e57f5. A `buildFanout` that
    // finalizes a bucket the moment its key is first seen, instead of once
    // every id sharing that key has been counted, only misbehaves when two
    // ids actually share a leading byte; this drives that path through
    // `writeIndex` itself, not a hand-written index vector.
    const payload_a = "payload-850";
    const payload_b = "payload-892";
    const id_a = object_mod.loose.hash(f_sha1, .blob, payload_a);
    const id_b = object_mod.loose.hash(f_sha1, .blob, payload_b);
    try std.testing.expectEqual(id_a.slice()[0], id_b.slice()[0]);

    var built = try buildTestPack(gpa, f_sha1, &.{
        .{ .object = .{ .kind = .blob, .payload = payload_a } },
        .{ .object = .{ .kind = .blob, .payload = payload_b } },
    });
    defer built.deinit(gpa);

    var idx = try buildAndOpenIndex(gpa, tmp.dir, io, f_sha1, built.bytes);
    defer idx.deinit();
    try std.testing.expectEqual(@as(u32, 2), idx.count());

    try std.testing.expectEqual(built.offsets[0], idx.offsetOf(id_a) orelse unreachable);
    try std.testing.expectEqual(built.offsets[1], idx.offsetOf(id_b) orelse unreachable);
}

// suspicious

test "writeIndex reports a write failure on out as IoFailed, not CorruptPack" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var built = try buildTestPack(gpa, f_sha1, &.{
        .{ .object = .{ .kind = .blob, .payload = "hello\n" } },
    });
    defer built.deinit(gpa);
    try tmp.dir.writeFile(io, .{ .sub_path = "src.pack", .data = built.bytes });
    const pack_file = try tmp.dir.openFile(io, "src.pack", .{});
    defer pack_file.close(io);
    var pack_read_buf: [4096]u8 = undefined;
    var pack_reader = pack_file.reader(io, &pack_read_buf);

    // Opened read only (`openFile`'s own default), standing in for a
    // destination that can accept no more bytes, a full disk or a closed
    // pipe: the write itself fails at the OS level, not anything about
    // `src.pack`.
    try tmp.dir.writeFile(io, .{ .sub_path = "ro.idx", .data = "" });
    const idx_file = try tmp.dir.openFile(io, "ro.idx", .{});
    defer idx_file.close(io);
    var idx_write_buf: [4096]u8 = undefined;
    var idx_writer = idx_file.writer(io, &idx_write_buf);

    try std.testing.expectError(error.IoFailed, writeIndex(gpa, f_sha1, &pack_reader, &idx_writer, null));
}

const f_sha1: Format = .sha1;
const buildTestPack = pack_mod.buildTestPack;
