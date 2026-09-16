//! Reads a `.idx` version 2 file: the fanout table, sorted ids, per-object
//! crc32 table, 32 bit offsets, and the 64 bit overflow table a pack over
//! 2 GiB needs. Version 1 is a different, older layout; this file rejects
//! it rather than guessing at it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;

pub const Index = struct {
    gpa: Allocator,
    format: Format,
    fanout: [256]u32,
    /// Sorted id bytes, `count() * format.byteLength()` bytes long. Owned
    /// by this Index, freed by `deinit`.
    ids: []u8,
    /// Resolved offsets, one per id in `ids`, in the same order. The 32/64
    /// bit split the file stores is resolved once here, at open time, so
    /// every later lookup is a plain array read. Owned by this Index,
    /// freed by `deinit`.
    offsets: []u64,
    /// crc32 of each entry's raw pack bytes, one per id in `ids`, in the
    /// same order. Owned by this Index, freed by `deinit`.
    crc: []u32,

    pub const Error = error{ CorruptIndex, UnsupportedIndexVersion } || Allocator.Error;

    const magic = "\xfftOc";
    const supported_version = 2;

    /// Reads and validates the whole index into memory. `file` is read from
    /// its current contents; `open` seeks it to the start first.
    pub fn open(gpa: Allocator, io: std.Io, file: std.Io.File, f: Format) Error!Index {
        var read_buffer: [8192]u8 = undefined;
        var reader = file.reader(io, &read_buffer);
        reader.seekTo(0) catch return error.CorruptIndex;
        const r = &reader.interface;

        const got_magic = r.take(4) catch return error.CorruptIndex;
        if (!std.mem.eql(u8, got_magic, magic)) return error.CorruptIndex;
        const version = r.takeInt(u32, .big) catch return error.CorruptIndex;
        if (version != supported_version) return error.UnsupportedIndexVersion;

        var fanout: [256]u32 = undefined;
        r.readSliceEndian(u32, &fanout, .big) catch return error.CorruptIndex;
        var prev: u32 = 0;
        for (fanout) |v| {
            if (v < prev) return error.CorruptIndex;
            prev = v;
        }
        const n = fanout[255];
        const id_len = f.byteLength();

        // `n` is whatever the file claims; nothing above this point checks
        // it against how many bytes the file actually has left. A tiny
        // hostile file can claim a count in the billions and drive an
        // allocation the real file could never back. A genuine v2 index
        // holding `n` ids always has at least the ids, the crc32 table, the
        // 32 bit offset table, and the two trailing checksums still ahead
        // of the current position; reject before allocating anything sized
        // by `n` when the file is too short to hold even that minimum.
        const size = reader.getSize() catch return error.CorruptIndex;
        const pos = reader.logicalPos();
        const remaining = std.math.sub(u64, size, pos) catch return error.CorruptIndex;

        const n64: u64 = n;
        const id_len64: u64 = id_len;
        const ids_bytes = std.math.mul(u64, n64, id_len64) catch return error.CorruptIndex;
        const crc_bytes = std.math.mul(u64, n64, 4) catch return error.CorruptIndex;
        const off_bytes = std.math.mul(u64, n64, 4) catch return error.CorruptIndex;
        const trailer_bytes = std.math.mul(u64, 2, id_len64) catch return error.CorruptIndex;
        var min_remaining = std.math.add(u64, ids_bytes, crc_bytes) catch return error.CorruptIndex;
        min_remaining = std.math.add(u64, min_remaining, off_bytes) catch return error.CorruptIndex;
        min_remaining = std.math.add(u64, min_remaining, trailer_bytes) catch return error.CorruptIndex;
        if (remaining < min_remaining) return error.CorruptIndex;

        const ids_len = std.math.cast(usize, ids_bytes) orelse return error.CorruptIndex;
        const ids = try gpa.alloc(u8, ids_len);
        errdefer gpa.free(ids);
        r.readSliceAll(ids) catch return error.CorruptIndex;

        const crc = try gpa.alloc(u32, n);
        errdefer gpa.free(crc);
        r.readSliceEndian(u32, crc, .big) catch return error.CorruptIndex;

        const raw_offsets = try gpa.alloc(u32, n);
        defer gpa.free(raw_offsets);
        r.readSliceEndian(u32, raw_offsets, .big) catch return error.CorruptIndex;

        var overflow_count: u32 = 0;
        for (raw_offsets) |v| {
            if (v & 0x8000_0000 != 0) overflow_count += 1;
        }
        const overflow = try gpa.alloc(u64, overflow_count);
        defer gpa.free(overflow);
        r.readSliceEndian(u64, overflow, .big) catch return error.CorruptIndex;

        const offsets = try gpa.alloc(u64, n);
        errdefer gpa.free(offsets);
        for (raw_offsets, 0..) |v, i| {
            if (v & 0x8000_0000 != 0) {
                const overflow_index = v & 0x7fff_ffff;
                if (overflow_index >= overflow.len) return error.CorruptIndex;
                offsets[i] = overflow[overflow_index];
            } else {
                offsets[i] = v;
            }
        }

        // Two trailing checksums, each one digest long: the pack's own
        // checksum, then this index's checksum over everything before it.
        // Neither is validated against anything here (there is nothing to
        // validate the index's own checksum against, and the pack is not
        // open), only checked for presence, then the file is checked for
        // ending exactly there.
        _ = r.take(f.byteLength()) catch return error.CorruptIndex;
        _ = r.take(f.byteLength()) catch return error.CorruptIndex;
        if (r.takeByte()) |_| {
            return error.CorruptIndex; // bytes remain past the last trailer
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return error.CorruptIndex,
        }

        return .{
            .gpa = gpa,
            .format = f,
            .fanout = fanout,
            .ids = ids,
            .offsets = offsets,
            .crc = crc,
        };
    }

    pub fn deinit(i: *Index) void {
        i.gpa.free(i.ids);
        i.gpa.free(i.offsets);
        i.gpa.free(i.crc);
        i.* = undefined;
    }

    pub fn count(i: Index) u32 {
        return i.fanout[255];
    }

    /// The crc32 of the `n`th id's raw pack bytes. Asserts `n < count()`; a
    /// caller walking past the end of the index is a caller mistake, not a
    /// data error.
    pub fn crc32At(i: Index, n: u32) u32 {
        std.debug.assert(n < i.count());
        return i.crc[n];
    }

    /// The pack offset of `oid`, or null when the index holds no such id.
    pub fn offsetOf(i: Index, oid: Oid) ?u64 {
        const id_len = i.format.byteLength();
        const key = oid.slice()[0];
        var lo: u32 = if (key > 0) i.fanout[key - 1] else 0;
        var hi: u32 = i.fanout[key];
        while (lo < hi) {
            // `lo < hi` here, so `hi - lo` cannot underflow, and the
            // midpoint cannot pass `hi`, so it cannot overflow `u32` either;
            // checked anyway, since a bare `+` here would overflow silently
            // on a target where this invariant ever stopped holding.
            const half = (hi - lo) / 2;
            const mid = std.math.add(u32, lo, half) catch unreachable;
            const mid_bytes = i.ids[mid * id_len ..][0..id_len];
            switch (std.mem.order(u8, mid_bytes, oid.slice())) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return i.offsets[mid],
            }
        }
        return null;
    }

    /// The `n`th id in ascending order. Asserts `n < count()`; a caller
    /// walking past the end of the index is a caller mistake, not a data
    /// error.
    pub fn oidAt(i: Index, n: u32) Oid {
        std.debug.assert(n < i.count());
        const id_len = i.format.byteLength();
        return Oid.fromBytes(i.format, i.ids[n * id_len ..][0..id_len]);
    }

    /// Every id sharing `hex_prefix`, up to `out.len`. Returns how many
    /// matched, which may exceed `out.len`: a caller with room for only a
    /// few ids can still tell an ambiguous prefix from a unique one.
    pub fn findPrefix(i: Index, hex_prefix: []const u8, out: []Oid) usize {
        const n = i.count();
        const id_len = i.format.byteLength();

        var lo: u32 = 0;
        var hi: u32 = n;
        while (lo < hi) {
            // Same overflow argument as `offsetOf`'s binary search: `lo <
            // hi` holds on every iteration, so this cannot overflow.
            const half = (hi - lo) / 2;
            const mid = std.math.add(u32, lo, half) catch unreachable;
            const bytes = i.ids[mid * id_len ..][0..id_len];
            if (prefixOrder(i.format, bytes, hex_prefix) == .lt) lo = mid + 1 else hi = mid;
        }

        var matched: usize = 0;
        var idx = lo;
        while (idx < n) : (idx += 1) {
            const bytes = i.ids[idx * id_len ..][0..id_len];
            const oid = Oid.fromBytes(i.format, bytes);
            if (!oid.hasPrefix(hex_prefix)) break;
            if (matched < out.len) out[matched] = oid;
            matched += 1;
        }
        return matched;
    }
};

fn prefixOrder(format: Format, id_bytes: []const u8, hex_prefix: []const u8) std.math.Order {
    var buf: [Oid.max_formatted_length]u8 = undefined;
    const oid = Oid.fromBytes(format, id_bytes);
    const hex = oid.toHex(&buf);
    const cmp_len = @min(hex.len, hex_prefix.len);
    return std.mem.order(u8, hex[0..cmp_len], hex_prefix[0..cmp_len]);
}

// Byte-exact vector: a hand-written v2 index holding three sha1 ids, chosen
// so their first bytes are 0x00, 0x01, and 0xff. The fanout table is
// verified by hand below rather than by construction, so a bug in a
// fanout-building helper cannot also hide itself in the vector.
//
//   id 0: 00 11 ... (20 bytes), offset 12
//   id 1: 01 22 ... (20 bytes), offset 400000000 (needs the overflow table)
//   id 2: ff 33 ... (20 bytes), offset 99
//
// fanout[0x00..0xff) = 1 (only id 0 has first byte <= 0x00)
// fanout[0x01..0xff) = 2 (ids 0 and 1 have first byte <= 0x01..0xfe)
// fanout[0xff]        = 3 (all three ids have first byte <= 0xff)
const test_id_0 = [_]u8{0x00} ++ [_]u8{0x11} ** 19;
const test_id_1 = [_]u8{0x01} ++ [_]u8{0x22} ** 19;
const test_id_2 = [_]u8{0xff} ++ [_]u8{0x33} ** 19;

fn buildTestIndexBytes(gpa: Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll(Index.magic);
    try w.writeInt(u32, Index.supported_version, .big);

    var fanout: [256]u32 = undefined;
    for (0..0x00) |b| fanout[b] = 0;
    fanout[0x00] = 1;
    for (0x01..0xff) |b| fanout[b] = 2;
    fanout[0xff] = 3;
    for (fanout) |v| try w.writeInt(u32, v, .big);

    try w.writeAll(&test_id_0);
    try w.writeAll(&test_id_1);
    try w.writeAll(&test_id_2);

    // crc32 table: arbitrary but distinct per id, so a read-back test can
    // tell which entry's value it got.
    try w.writeInt(u32, 0x11111111, .big);
    try w.writeInt(u32, 0x22222222, .big);
    try w.writeInt(u32, 0x33333333, .big);

    // offsets: id 0 -> 12 (direct), id 1 -> overflow[0] (400000000, > 2^31),
    // id 2 -> 99 (direct).
    try w.writeInt(u32, 12, .big);
    try w.writeInt(u32, 0x8000_0000, .big);
    try w.writeInt(u32, 99, .big);
    try w.writeInt(u64, 400_000_000, .big);

    try w.writeAll(&([_]u8{0xaa} ** 20)); // pack checksum, unchecked
    try w.writeAll(&([_]u8{0xbb} ** 20)); // index checksum, unchecked

    return aw.toOwnedSlice();
}

fn openTestIndex(gpa: Allocator, tmp_dir: std.Io.Dir, io: std.Io) !Index {
    const bytes = try buildTestIndexBytes(gpa);
    defer gpa.free(bytes);
    try tmp_dir.writeFile(io, .{ .sub_path = "test.idx", .data = bytes });
    const file = try tmp_dir.openFile(io, "test.idx", .{});
    defer file.close(io);
    return Index.open(gpa, io, file, .sha1);
}

// expected

test "Index offsetOf finds an id that is in the pack" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var idx = try openTestIndex(gpa, tmp.dir, io);
    defer idx.deinit();

    const id0 = Oid.fromBytes(.sha1, &test_id_0);
    const id1 = Oid.fromBytes(.sha1, &test_id_1);
    try std.testing.expectEqual(@as(?u64, 12), idx.offsetOf(id0));
    try std.testing.expectEqual(@as(?u64, 400_000_000), idx.offsetOf(id1));
}

test "Index oidAt walks the ids in ascending order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var idx = try openTestIndex(gpa, tmp.dir, io);
    defer idx.deinit();

    try std.testing.expectEqual(@as(u32, 3), idx.count());
    try std.testing.expect(idx.oidAt(0).eql(Oid.fromBytes(.sha1, &test_id_0)));
    try std.testing.expect(idx.oidAt(1).eql(Oid.fromBytes(.sha1, &test_id_1)));
    try std.testing.expect(idx.oidAt(2).eql(Oid.fromBytes(.sha1, &test_id_2)));
}

test "Index writes and reads back a stored crc32" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var idx = try openTestIndex(gpa, tmp.dir, io);
    defer idx.deinit();

    try std.testing.expectEqual(@as(u32, 0x11111111), idx.crc32At(0));
    try std.testing.expectEqual(@as(u32, 0x22222222), idx.crc32At(1));
    try std.testing.expectEqual(@as(u32, 0x33333333), idx.crc32At(2));
}

// suspicious

test "Index open rejects a v1 index" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [8]u8 = undefined;
    @memcpy(buf[0..4], Index.magic);
    std.mem.writeInt(u32, buf[4..8], 1, .big);
    try tmp.dir.writeFile(io, .{ .sub_path = "v1.idx", .data = &buf });
    const file = try tmp.dir.openFile(io, "v1.idx", .{});
    defer file.close(io);

    try std.testing.expectError(error.UnsupportedIndexVersion, Index.open(gpa, io, file, .sha1));
}

test "Index open rejects a fanout count the file could not possibly hold" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(Index.magic);
    try w.writeInt(u32, Index.supported_version, .big);
    var fanout: [256]u32 = undefined;
    for (0..255) |b| fanout[b] = 0;
    // Billions of ids, claimed by a file that is a few bytes long: the ids,
    // crc32, offset, and trailer bytes this many ids would need cannot
    // possibly fit in what actually follows.
    fanout[255] = 0xffff_fff0;
    for (fanout) |v| try w.writeInt(u32, v, .big);
    const bytes = try aw.toOwnedSlice();
    defer gpa.free(bytes);

    try tmp.dir.writeFile(io, .{ .sub_path = "huge.idx", .data = bytes });
    const file = try tmp.dir.openFile(io, "huge.idx", .{});
    defer file.close(io);

    // This must fail on the bounds check, not attempt an allocation sized
    // by the claimed count: a leak-detecting allocator failing here would
    // also mean the huge allocation was attempted.
    try std.testing.expectError(error.CorruptIndex, Index.open(gpa, io, file, .sha1));
}

test "Index offsetOf returns null for an id that is absent" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var idx = try openTestIndex(gpa, tmp.dir, io);
    defer idx.deinit();

    const absent = Oid.fromBytes(.sha1, &([_]u8{0x02} ++ [_]u8{0x00} ** 19));
    try std.testing.expectEqual(@as(?u64, null), idx.offsetOf(absent));
}

test "Index reads a 64 bit offset out of the overflow table" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var idx = try openTestIndex(gpa, tmp.dir, io);
    defer idx.deinit();

    const id1 = Oid.fromBytes(.sha1, &test_id_1);
    try std.testing.expectEqual(@as(?u64, 400_000_000), idx.offsetOf(id1));
}

test "findPrefix reports two matches for an ambiguous prefix" {
    // Rebuild with two ids sharing the hex prefix "01".
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const id_a = [_]u8{0x01} ++ [_]u8{0x10} ** 19;
    const id_b = [_]u8{0x01} ++ [_]u8{0x20} ** 19;
    const id_c = [_]u8{0x02} ++ [_]u8{0x00} ** 19;

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(Index.magic);
    try w.writeInt(u32, Index.supported_version, .big);
    var fanout: [256]u32 = undefined;
    for (0..0x02) |b| fanout[b] = 0;
    fanout[0x01] = 2;
    for (0x02..256) |b| fanout[b] = 3;
    for (fanout) |v| try w.writeInt(u32, v, .big);
    try w.writeAll(&id_a);
    try w.writeAll(&id_b);
    try w.writeAll(&id_c);
    try w.writeInt(u32, 0, .big);
    try w.writeInt(u32, 0, .big);
    try w.writeInt(u32, 0, .big);
    try w.writeInt(u32, 1, .big);
    try w.writeInt(u32, 2, .big);
    try w.writeInt(u32, 3, .big);
    try w.writeAll(&([_]u8{0xaa} ** 20));
    try w.writeAll(&([_]u8{0xbb} ** 20));
    const bytes = try aw.toOwnedSlice();
    defer gpa.free(bytes);

    try tmp.dir.writeFile(io, .{ .sub_path = "ambiguous.idx", .data = bytes });
    const file = try tmp.dir.openFile(io, "ambiguous.idx", .{});
    defer file.close(io);
    var idx = try Index.open(gpa, io, file, .sha1);
    defer idx.deinit();

    var out: [1]Oid = undefined;
    const matched = idx.findPrefix("01", &out);
    try std.testing.expectEqual(@as(usize, 2), matched);
}

test "findPrefix reports one match for a unique prefix" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var idx = try openTestIndex(gpa, tmp.dir, io);
    defer idx.deinit();

    var out: [4]Oid = undefined;
    const matched = idx.findPrefix("ff", &out);
    try std.testing.expectEqual(@as(usize, 1), matched);
    try std.testing.expect(out[0].eql(Oid.fromBytes(.sha1, &test_id_2)));
}

test "an id at a fanout bucket boundary is found" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var idx = try openTestIndex(gpa, tmp.dir, io);
    defer idx.deinit();

    // `test_id_1`'s first byte, 0x01, is exactly the fanout boundary
    // between bucket 0x00 (one id) and every bucket from 0x01 up (two
    // ids). Finding it exercises that boundary directly.
    const id1 = Oid.fromBytes(.sha1, &test_id_1);
    try std.testing.expectEqual(@as(?u64, 400_000_000), idx.offsetOf(id1));
}
