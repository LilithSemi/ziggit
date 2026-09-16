//! The packfile format: the "PACK" header, the delta-compressed entry
//! stream, and the trailing checksum. This file resolves delta chains on
//! its own; it holds no `.idx` and decides nothing about which pack to
//! open or which offset to ask for. `ziggit-odb`, in a later task, is what
//! makes that decision and hands this module an offset.
//!
//! Every length below is a number the pack's writer chose, never a value
//! this file trusts on its own: a hostile pack can claim a delta chain
//! that never terminates, a copy instruction reading past its base, an
//! object count larger than the file, or a 64 bit offset past EOF. Each of
//! those is checked and reported as an error, never asserted away.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;
const Hasher = oid_mod.Hasher;

const core_mod = @import("ziggit-core");
const ObjectKind = core_mod.ObjectKind;
const Diagnostic = core_mod.Diagnostic;

const object_mod = @import("ziggit-object");

const delta_mod = @import("delta.zig");

/// The on-disk tag of one pack entry. 0 and 5 are reserved by the format
/// and never appear.
pub const EntryType = enum(u3) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    ofs_delta = 6,
    ref_delta = 7,
};

/// The final id and pack offset of one object, discovered while scanning a
/// pack. `crc32` covers the entry's raw bytes as stored in the pack (its
/// type/size header plus its compressed payload); `writeIndex` is the only
/// reader of this field, `Pack` itself never needs it.
pub const IndexEntry = struct { offset: u64, crc32: u32 };

/// The final id of every object in a pack, keyed by that id. Built by
/// `computeOidOffsets`.
pub const Entries = std.AutoHashMapUnmanaged(Oid, IndexEntry);

pub const Pack = struct {
    gpa: Allocator,
    io: std.Io,
    format: Format,
    object_count: u32,
    /// Backs `reader`'s buffered interface. Owned by this Pack, freed by
    /// `deinit`.
    read_buffer: []u8,
    reader: std.Io.File.Reader,
    /// The final id and offset of every object in the pack, built the
    /// first time a ref-delta needs to find its base by id. Owned by this
    /// Pack, freed by `deinit`. Building it decompresses every object
    /// once, so a pack that never uses a ref-delta never pays for it.
    base_offsets: ?Entries = null,

    pub const Error = error{
        CorruptPack,
        UnsupportedPackVersion,
        BadPackChecksum,
        DeltaChainTooDeep,
        DeltaCycle,
        CorruptDelta,
        /// A write to the caller's own destination failed: a full disk, a
        /// closed pipe, anything on the write side rather than the pack
        /// being read. `index_writer.zig`'s `writeIndex` is the one place
        /// this can happen, since every other function in this file only
        /// ever reads a pack.
        IoFailed,
    } || Allocator.Error;

    /// The deepest delta chain this file follows before giving up. Git's
    /// own packs stay well under this; a chain that exceeds it is treated
    /// as hostile, not as merely unusual.
    pub const max_delta_depth: usize = 50;

    const read_buffer_len = 8192;

    /// Opens `file` as a version 2 pack, reading only its header. `file`
    /// must outlive `p`; `open` does not take ownership of it and `deinit`
    /// never closes it.
    pub fn open(gpa: Allocator, io: std.Io, file: std.Io.File, f: Format) Error!Pack {
        const read_buffer = try gpa.alloc(u8, read_buffer_len);
        errdefer gpa.free(read_buffer);
        var reader = file.reader(io, read_buffer);
        reader.seekTo(0) catch return error.CorruptPack;
        // `open`'s own signature has no `diag` to report through (the
        // brief's interface fixes it); a bad magic or version here is
        // silent to the caller beyond the error value itself.
        const header = try readPackHeader(&reader.interface, gpa, null);
        return .{
            .gpa = gpa,
            .io = io,
            .format = f,
            .object_count = header.object_count,
            .read_buffer = read_buffer,
            .reader = reader,
        };
    }

    pub fn deinit(p: *Pack) void {
        if (p.base_offsets) |*m| m.deinit(p.gpa);
        p.gpa.free(p.read_buffer);
        p.* = undefined;
    }

    pub fn objectCount(p: Pack) u32 {
        return p.object_count;
    }

    /// Reads the fully reconstructed object at `offset`, resolving any
    /// delta chain, and writes the payload to `out`. Never buffers the
    /// whole object itself for a non-delta entry; a delta chain still
    /// needs its base fully in memory, since a copy instruction can read
    /// from anywhere in it.
    pub fn readAt(
        p: *Pack,
        gpa: Allocator,
        offset: u64,
        out: *std.Io.Writer,
        diag: ?*?Diagnostic,
    ) Error!ObjectKind {
        var ctx: LazyRefContext = .{ .pack = p, .diag = diag };
        const resolver: RefResolver = .{ .ctx = &ctx, .findFn = lazyFind };
        const kind = try resolveChain(gpa, p.format, &p.reader, offset, resolver, out, diag);
        return kind orelse {
            // `resolver` here always resolves against the pack's complete
            // id map (built once, on first need), so a null return means
            // the ref-delta's base id genuinely does not exist in the
            // pack, not merely "not found yet".
            reportPack(diag, gpa, "ref-delta base id does not exist in this pack");
            return error.CorruptPack;
        };
    }

    /// Hashes every byte of the pack except its trailing checksum, and
    /// compares the result against that checksum.
    pub fn verifyChecksum(p: *Pack) Error!void {
        const trailer_len = p.format.byteLength();
        const size = p.reader.getSize() catch return error.CorruptPack;
        if (size < trailer_len) return error.CorruptPack;
        const data_len = size - trailer_len;

        p.reader.seekTo(0) catch return error.CorruptPack;
        var hasher = Hasher.init(p.format);
        var remaining = data_len;
        var buf: [4096]u8 = undefined;
        while (remaining > 0) {
            const want: usize = @intCast(@min(@as(u64, buf.len), remaining));
            const n = p.reader.interface.readSliceShort(buf[0..want]) catch return error.CorruptPack;
            if (n == 0) return error.CorruptPack;
            hasher.update(buf[0..n]);
            remaining -= n;
        }
        const expected = hasher.final();

        var trailer: [Oid.max_byte_length]u8 = undefined;
        const trailer_bytes = p.reader.interface.take(trailer_len) catch return error.CorruptPack;
        @memcpy(trailer[0..trailer_len], trailer_bytes);
        const actual = Oid.fromBytes(p.format, trailer[0..trailer_len]);
        if (!expected.eql(actual)) return error.BadPackChecksum;
    }

    const LazyRefContext = struct { pack: *Pack, diag: ?*?Diagnostic };

    fn lazyFind(ctx: *const anyopaque, id: Oid) Error!?u64 {
        const c: *const LazyRefContext = @ptrCast(@alignCast(ctx));
        try c.pack.ensureBaseOffsets(c.diag);
        return if (c.pack.base_offsets.?.get(id)) |v| v.offset else null;
    }

    fn ensureBaseOffsets(p: *Pack, diag: ?*?Diagnostic) Error!void {
        if (p.base_offsets != null) return;
        p.base_offsets = try computeOidOffsets(p.gpa, p.format, &p.reader, diag);
    }
};

/// Reports one pack-shaped fault: every rejection in this file is a fault
/// in the pack format itself (never the index format), so `kind` is always
/// `.corrupt_pack`. `detail` names the specific condition a bare error
/// value cannot carry; `wants(diag)` guards the allocation it costs, so a
/// null `diag` is free.
fn reportPack(diag: ?*?Diagnostic, gpa: Allocator, detail: []const u8) void {
    if (!core_mod.wants(diag)) return;
    const detail_dup = gpa.dupe(u8, detail) catch null;
    core_mod.report(diag, gpa, .{ .kind = .corrupt_pack, .path = null, .detail = detail_dup });
}

const PackHeader = struct { object_count: u32 };

fn readPackHeader(r: *std.Io.Reader, gpa: Allocator, diag: ?*?Diagnostic) Pack.Error!PackHeader {
    const magic = r.take(4) catch {
        reportPack(diag, gpa, "pack header is truncated");
        return error.CorruptPack;
    };
    if (!std.mem.eql(u8, magic, "PACK")) {
        reportPack(diag, gpa, "pack file does not start with the PACK magic bytes");
        return error.CorruptPack;
    }
    const version = r.takeInt(u32, .big) catch {
        reportPack(diag, gpa, "pack header is truncated");
        return error.CorruptPack;
    };
    if (version != 2) {
        reportPack(diag, gpa, "pack version is not 2");
        return error.UnsupportedPackVersion;
    }
    const object_count = r.takeInt(u32, .big) catch {
        reportPack(diag, gpa, "pack header is truncated");
        return error.CorruptPack;
    };
    return .{ .object_count = object_count };
}

const EntryHeader = union(EntryType) {
    commit: Sized,
    tree: Sized,
    blob: Sized,
    tag: Sized,
    ofs_delta: OfsDelta,
    ref_delta: RefDelta,

    const Sized = struct { size: u64 };
    const OfsDelta = struct { base_distance: u64, size: u64 };
    const RefDelta = struct { base_id: Oid, size: u64 };

    fn size(h: EntryHeader) u64 {
        return switch (h) {
            inline else => |e| e.size,
        };
    }

    /// The kind a non-delta entry holds. Null for a delta entry: a delta
    /// borrows its kind from the base at the bottom of its chain.
    fn kind(h: EntryHeader) ?ObjectKind {
        return switch (h) {
            .commit => .commit,
            .tree => .tree,
            .blob => .blob,
            .tag => .tag,
            .ofs_delta, .ref_delta => null,
        };
    }

    fn read(format: Format, r: *std.Io.Reader, gpa: Allocator, diag: ?*?Diagnostic) Pack.Error!EntryHeader {
        const first = r.takeByte() catch {
            reportPack(diag, gpa, "pack entry header is truncated");
            return error.CorruptPack;
        };
        const type_bits: u3 = @truncate((first >> 4) & 0x07);
        const entry_type = std.enums.fromInt(EntryType, type_bits) orelse {
            reportPack(diag, gpa, "pack entry has an unknown type tag");
            return error.CorruptPack;
        };

        var value: u64 = first & 0x0f;
        var shift: u6 = 4;
        var more = (first & 0x80) != 0;
        while (more) {
            const b = r.takeByte() catch {
                reportPack(diag, gpa, "pack entry size varint is truncated");
                return error.CorruptPack;
            };
            const part = std.math.shlExact(u64, @as(u64, b & 0x7f), shift) catch {
                reportPack(diag, gpa, "pack entry size varint overflows");
                return error.CorruptPack;
            };
            value = std.math.add(u64, value, part) catch {
                reportPack(diag, gpa, "pack entry size varint overflows");
                return error.CorruptPack;
            };
            more = (b & 0x80) != 0;
            if (more) shift = std.math.add(u6, shift, 7) catch {
                reportPack(diag, gpa, "pack entry size varint overflows");
                return error.CorruptPack;
            };
        }

        return switch (entry_type) {
            .commit => .{ .commit = .{ .size = value } },
            .tree => .{ .tree = .{ .size = value } },
            .blob => .{ .blob = .{ .size = value } },
            .tag => .{ .tag = .{ .size = value } },
            .ofs_delta => .{ .ofs_delta = .{ .base_distance = try readOffsetVarint(r, gpa, diag), .size = value } },
            .ref_delta => blk: {
                const len = format.byteLength();
                var raw: [Oid.max_byte_length]u8 = undefined;
                const bytes = r.take(len) catch {
                    reportPack(diag, gpa, "ref-delta base id is truncated");
                    return error.CorruptPack;
                };
                @memcpy(raw[0..len], bytes);
                break :blk .{ .ref_delta = .{ .base_id = Oid.fromBytes(format, raw[0..len]), .size = value } };
            },
        };
    }
};

/// The OFS_DELTA offset encoding: distinct from `EntryHeader.read`'s size
/// varint, since each continuation byte adds one before shifting, so the
/// same magnitude never has two spellings.
fn readOffsetVarint(r: *std.Io.Reader, gpa: Allocator, diag: ?*?Diagnostic) Pack.Error!u64 {
    var b = r.takeByte() catch {
        reportPack(diag, gpa, "ofs-delta offset varint is truncated");
        return error.CorruptPack;
    };
    var value: u64 = b & 0x7f;
    while ((b & 0x80) != 0) {
        b = r.takeByte() catch {
            reportPack(diag, gpa, "ofs-delta offset varint is truncated");
            return error.CorruptPack;
        };
        const bumped = std.math.add(u64, value, 1) catch {
            reportPack(diag, gpa, "ofs-delta offset varint overflows");
            return error.CorruptPack;
        };
        value = std.math.shlExact(u64, bumped, 7) catch {
            reportPack(diag, gpa, "ofs-delta offset varint overflows");
            return error.CorruptPack;
        };
        value |= (b & 0x7f);
    }
    return value;
}

/// Deflate can expand what it reads by a bounded factor; no single stream
/// this short can legitimately decompress to something dramatically
/// larger. 1032 mirrors the deflate format's documented worst case for one
/// pass of inflate (a long back-reference costs very few compressed bits),
/// generous enough that no real object trips it, tight enough that a
/// hostile entry claiming gigabytes from a few compressed bytes cannot
/// drive an allocation anywhere near that size.
const max_inflate_ratio: u64 = 1032;

/// Checks `declared_size`, the size a pack entry claims for the bytes
/// starting at `pack`'s current position, against how many bytes the file
/// actually has left. A size only a much larger file could ever back is
/// corrupt on its own; this runs before any allocation sized by it.
fn checkDeclaredSize(
    pack: *std.Io.File.Reader,
    declared_size: u64,
    gpa: Allocator,
    diag: ?*?Diagnostic,
) Pack.Error!void {
    const size = pack.getSize() catch {
        reportPack(diag, gpa, "cannot determine the pack file's size");
        return error.CorruptPack;
    };
    const pos = pack.logicalPos();
    const remaining = std.math.sub(u64, size, pos) catch {
        reportPack(diag, gpa, "pack reader position is past the end of the file");
        return error.CorruptPack;
    };
    // Overflow here means `remaining` is already implausibly large (well
    // past any real file); treat the bound as unlimited rather than reject
    // a file for being too big to multiply.
    const bound = std.math.mul(u64, remaining, max_inflate_ratio) catch std.math.maxInt(u64);
    if (declared_size > bound) {
        reportPack(diag, gpa, "declared object size cannot fit in the bytes left in the pack");
        return error.CorruptPack;
    }
}

/// Wraps the pack's live input so `std.compress.flate.Decompress` never
/// observes a genuine, zero-byte end of stream while it is mid-bitstream.
///
/// `Decompress`'s own tail handling computes `buffered_bytes * 8 -
/// consumed_bits` with no guard against the wrapped reader running out of
/// bytes entirely; when a pack is truncated inside a deflate entry, that
/// subtraction underflows and traps the process (`std` bug, not ours: the
/// same trap reproduces with a plain in-memory reader over the identical
/// truncated bytes, so this is not specific to a file-backed reader). A
/// short run of synthetic zero bytes past the wrapped reader's real end
/// keeps that subtraction's operands sane, so `Decompress` always reports
/// an ordinary error instead of trapping.
///
/// `touched_padding` becomes true the moment any synthetic byte is served.
/// That is this file's only signal that the pack ran out before the
/// deflate stream did: every caller must treat it as `CorruptPack`, even on
/// a call that otherwise reports success (the deflate stream's own trailer
/// checksum can sit past the true end, letting decompression of the object
/// body "succeed" on padding alone).
const PaddedInput = struct {
    inner: *std.Io.Reader,
    pad_left: usize,
    touched_padding: bool = false,
    interface: std.Io.Reader,

    /// More than `Decompress` ever looks ahead for one zlib container
    /// (a 4 byte bit-level lookahead), with margin.
    const pad_len: usize = 8;

    fn init(buffer: []u8, inner: *std.Io.Reader) PaddedInput {
        return .{
            .inner = inner,
            .pad_left = pad_len,
            .interface = .{
                .vtable = &.{ .stream = stream, .readVec = readVec },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    /// Fills `dest` from `inner`, then zero-pads whatever `inner` could not
    /// supply. `inner` is `pack`'s own live, persistent reader: draining it
    /// through its ordinary buffered read path (`readSliceShort`) is what
    /// keeps this call transparent to every other reader of the same pack,
    /// unlike `inner.stream`, whose `File.Reader` backing can select an
    /// OS-level `sendFile` fast path irrelevant to a plain memory
    /// destination and, on falling back from it, mutates `inner`'s `mode`
    /// field -- a change that outlives this one call and corrupts every
    /// later read of the same pack.
    fn fill(self: *PaddedInput, dest: []u8) std.Io.Reader.Error!usize {
        if (dest.len == 0) return 0;
        const n = self.inner.readSliceShort(dest) catch return error.ReadFailed;
        if (n == dest.len) return n;
        const pad_want = @min(dest.len - n, self.pad_left);
        if (pad_want == 0) {
            if (n == 0) return error.EndOfStream;
            return n;
        }
        self.touched_padding = true;
        @memset(dest[n..][0..pad_want], 0);
        self.pad_left -= pad_want;
        return n + pad_want;
    }

    fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *PaddedInput = @alignCast(@fieldParentPtr("interface", r));
        // `data[0]` empty is the caller's way of asking this reader to
        // fill its own buffer instead (the common case, driven by `fill`
        // on `r` itself); give that request real capacity either way.
        if (data[0].len == 0) {
            const n = try self.fill(r.buffer[r.end..]);
            r.end += n;
            return 0;
        }
        return self.fill(data[0]);
    }

    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *PaddedInput = @alignCast(@fieldParentPtr("interface", r));
        var scratch: [256]u8 = undefined;
        const want = limit.minInt(scratch.len);
        const n = try self.fill(scratch[0..want]);
        try w.writeAll(scratch[0..n]);
        return n;
    }
};

/// Undoes `padded`'s own read-ahead against `pack` once decompression is
/// done with it. `fill` above draws real bytes from `pack.interface` a
/// buffer's worth at a time; whatever `Decompress` never actually asked
/// for is left sitting, still unread, in `padded`'s own buffer rather than
/// `pack`'s, so `pack`'s position must be walked back by exactly that much
/// or the very next read anywhere in this file -- the next entry's header,
/// the pack's own trailing checksum -- starts short by however many bytes
/// `padded` happened to prefetch.
///
/// Skipped once `padded` has served any padding: the caller is about to
/// reject this pack as corrupt regardless of position, and past the pack's
/// real end there is nothing genuine left to rewind to.
fn rewindUnused(
    pack: *std.Io.File.Reader,
    padded: *const PaddedInput,
    gpa: Allocator,
    diag: ?*?Diagnostic,
) Pack.Error!void {
    if (padded.touched_padding) return;
    const leftover = padded.interface.bufferedLen();
    if (leftover == 0) return;
    const pos = pack.logicalPos();
    const back = std.math.sub(u64, pos, leftover) catch {
        reportPack(diag, gpa, "pack reader position underflows while rewinding after decompression");
        return error.CorruptPack;
    };
    pack.seekTo(back) catch {
        reportPack(diag, gpa, "cannot rewind the pack reader after decompression");
        return error.CorruptPack;
    };
}

/// Decompresses exactly `declared_size` bytes starting at `pack`'s current
/// position into a fresh allocation, and confirms nothing follows in the
/// same deflate stream. Owned by the caller.
fn decompressAlloc(
    gpa: Allocator,
    pack: *std.Io.File.Reader,
    declared_size: u64,
    diag: ?*?Diagnostic,
) Pack.Error![]u8 {
    try checkDeclaredSize(pack, declared_size, gpa, diag);
    const len = std.math.cast(usize, declared_size) orelse {
        reportPack(diag, gpa, "declared object size does not fit in memory on this target");
        return error.CorruptPack;
    };
    const buf = try gpa.alloc(u8, len);
    errdefer gpa.free(buf);

    var pad_buf: [PaddedInput.pad_len]u8 = undefined;
    var padded_input: PaddedInput = .init(&pad_buf, &pack.interface);

    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&padded_input.interface, .zlib, &window);
    var w: std.Io.Writer = .fixed(buf);
    decompress.reader.streamExact(&w, len) catch {
        reportPack(diag, gpa, "corrupt or truncated deflate stream");
        return error.CorruptPack;
    };

    var extra: [1]u8 = undefined;
    const extra_n = decompress.reader.readSliceShort(&extra) catch {
        reportPack(diag, gpa, "corrupt or truncated deflate stream");
        return error.CorruptPack;
    };
    if (extra_n != 0) {
        reportPack(diag, gpa, "compressed object payload is longer than its declared size");
        return error.CorruptPack;
    }
    if (padded_input.touched_padding) {
        reportPack(diag, gpa, "pack is truncated mid deflate stream");
        return error.CorruptPack;
    }
    try rewindUnused(pack, &padded_input, gpa, diag);

    return buf;
}

/// Decompresses exactly `declared_size` bytes from `r`, discarding them.
/// Used for a pending delta in the first pass, when only the length needs
/// checking, not the bytes.
fn discardCompressed(
    pack: *std.Io.File.Reader,
    declared_size: u64,
    gpa: Allocator,
    diag: ?*?Diagnostic,
) Pack.Error!void {
    try checkDeclaredSize(pack, declared_size, gpa, diag);
    var pad_buf: [PaddedInput.pad_len]u8 = undefined;
    var padded_input: PaddedInput = .init(&pad_buf, &pack.interface);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&padded_input.interface, .zlib, &window);
    const n = decompress.reader.discardRemaining() catch {
        reportPack(diag, gpa, "corrupt or truncated deflate stream");
        return error.CorruptPack;
    };
    if (padded_input.touched_padding) {
        reportPack(diag, gpa, "pack is truncated mid deflate stream");
        return error.CorruptPack;
    }
    if (n != declared_size) {
        reportPack(diag, gpa, "declared object size does not match its decompressed length");
        return error.CorruptPack;
    }
    try rewindUnused(pack, &padded_input, gpa, diag);
}

/// Hashes a non-delta pack entry's decompressed bytes as a loose object of
/// `kind`, without ever holding the whole object in memory: the loose
/// object header and the decompressed body both flow through a hashing
/// `Io.Writer` that discards what it hashes, so hashing a pack's largest
/// blob costs no more memory than hashing its smallest.
fn hashDecompressedObject(
    pack: *std.Io.File.Reader,
    format: Format,
    kind: ObjectKind,
    declared_size: u64,
    gpa: Allocator,
    diag: ?*?Diagnostic,
) Pack.Error!Oid {
    try checkDeclaredSize(pack, declared_size, gpa, diag);
    var hashing = std.Io.Writer.Hashing(Hasher).initHasher(Hasher.init(format), &.{});
    // A discarding hashing writer with no underlying stream never fails:
    // `Hashing.drain` only calls `Hasher.update` and reports a count.
    object_mod.Header.write(.{ .kind = kind, .size = declared_size }, &hashing.writer) catch unreachable;

    var pad_buf: [PaddedInput.pad_len]u8 = undefined;
    var padded_input: PaddedInput = .init(&pad_buf, &pack.interface);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress = std.compress.flate.Decompress.init(&padded_input.interface, .zlib, &window);
    const n = decompress.reader.streamRemaining(&hashing.writer) catch {
        reportPack(diag, gpa, "corrupt or truncated deflate stream");
        return error.CorruptPack;
    };
    if (padded_input.touched_padding) {
        reportPack(diag, gpa, "pack is truncated mid deflate stream");
        return error.CorruptPack;
    }
    if (n != declared_size) {
        reportPack(diag, gpa, "declared object size does not match its decompressed length");
        return error.CorruptPack;
    }
    try rewindUnused(pack, &padded_input, gpa, diag);
    return hashing.hasher.final();
}

fn seekOrCorrupt(r: *std.Io.File.Reader, pos: u64, gpa: Allocator, diag: ?*?Diagnostic) Pack.Error!void {
    r.seekTo(pos) catch {
        reportPack(diag, gpa, "cannot seek to a pack offset the entry needs");
        return error.CorruptPack;
    };
}

/// crc32 of the raw pack bytes in `[start, end)`, read through a second,
/// independent positional reader over the same file so the main sequential
/// reader's buffering is never disturbed.
fn crc32Range(
    r: *std.Io.File.Reader,
    start: u64,
    end: u64,
    gpa: Allocator,
    diag: ?*?Diagnostic,
) Pack.Error!u32 {
    try seekOrCorrupt(r, start, gpa, diag);
    var hasher = std.hash.Crc32.init();
    var remaining = std.math.sub(u64, end, start) catch {
        reportPack(diag, gpa, "pack entry end offset precedes its start offset");
        return error.CorruptPack;
    };
    var buf: [4096]u8 = undefined;
    while (remaining > 0) {
        const want: usize = @intCast(@min(@as(u64, buf.len), remaining));
        const n = r.interface.readSliceShort(buf[0..want]) catch {
            reportPack(diag, gpa, "pack is truncated while computing an entry's crc32");
            return error.CorruptPack;
        };
        if (n == 0) {
            reportPack(diag, gpa, "pack is truncated while computing an entry's crc32");
            return error.CorruptPack;
        }
        hasher.update(buf[0..n]);
        remaining -= n;
    }
    return hasher.final();
}

/// Answers "which pack offset holds this id" for a ref-delta base. A
/// caller with a complete map (`Pack`, once built) returns null only for a
/// genuinely absent id; a caller still filling one in (`computeOidOffsets`'s
/// second pass) returns null for "not known yet" too, and tells the two
/// apart itself once every pending delta stops making progress.
const RefResolver = struct {
    ctx: *const anyopaque,
    findFn: *const fn (ctx: *const anyopaque, id: Oid) Pack.Error!?u64,

    fn find(self: RefResolver, id: Oid) Pack.Error!?u64 {
        return self.findFn(self.ctx, id);
    }
};

fn entriesResolver(entries: *const Entries) RefResolver {
    return .{ .ctx = @ptrCast(entries), .findFn = entriesFind };
}

fn entriesFind(ctx: *const anyopaque, id: Oid) Pack.Error!?u64 {
    const e: *const Entries = @ptrCast(@alignCast(ctx));
    return if (e.get(id)) |v| v.offset else null;
}

/// Walks from `start_offset` down through any ofs/ref delta chain to its
/// non-delta base, then applies every delta back up in order, writing the
/// final reconstructed bytes to `out`. Returns the ultimate object kind, or
/// null when `resolve_ref` could not place a ref-delta's base (either it is
/// genuinely absent, or the caller is still filling its map in; the caller
/// tells the two apart).
///
/// `out` receives bytes only once the whole chain is known to resolve: a
/// null return never leaves partial output in `out`.
fn resolveChain(
    gpa: Allocator,
    format: Format,
    pack: *std.Io.File.Reader,
    start_offset: u64,
    resolve_ref: RefResolver,
    out: *std.Io.Writer,
    diag: ?*?Diagnostic,
) Pack.Error!?ObjectKind {
    var chain: std.ArrayList(u64) = .empty;
    defer chain.deinit(gpa);

    var offset = start_offset;
    var base_kind: ObjectKind = undefined;
    var current: []u8 = while (true) {
        if (chain.items.len >= Pack.max_delta_depth) {
            reportPack(diag, gpa, "delta chain is deeper than max_delta_depth");
            return error.DeltaChainTooDeep;
        }
        for (chain.items) |seen| {
            if (seen == offset) {
                reportPack(diag, gpa, "delta chain revisits an offset it already walked");
                return error.DeltaCycle;
            }
        }

        try seekOrCorrupt(pack, offset, gpa, diag);
        const header = try EntryHeader.read(format, &pack.interface, gpa, diag);
        switch (header) {
            .ofs_delta => |d| {
                try chain.append(gpa, offset);
                offset = std.math.sub(u64, offset, d.base_distance) catch {
                    reportPack(diag, gpa, "ofs-delta base distance reaches before the start of the pack");
                    return error.CorruptPack;
                };
            },
            .ref_delta => |d| {
                const found = try resolve_ref.find(d.base_id) orelse return null;
                try chain.append(gpa, offset);
                offset = found;
            },
            else => {
                base_kind = header.kind().?;
                if (chain.items.len == 0) {
                    // `start_offset` itself is non-delta: stream straight
                    // to `out` without ever holding the object in memory,
                    // since nothing needs random access into it. The size
                    // bound runs first, so a hostile declared size cannot
                    // hand a zip bomb to the caller's writer before this
                    // file has checked it against the bytes actually left
                    // in the pack.
                    try checkDeclaredSize(pack, header.size(), gpa, diag);
                    var pad_buf: [PaddedInput.pad_len]u8 = undefined;
                    var padded_input: PaddedInput = .init(&pad_buf, &pack.interface);
                    var window: [std.compress.flate.max_window_len]u8 = undefined;
                    var decompress = std.compress.flate.Decompress.init(&padded_input.interface, .zlib, &window);
                    const n = decompress.reader.streamRemaining(out) catch {
                        reportPack(diag, gpa, "corrupt or truncated deflate stream");
                        return error.CorruptPack;
                    };
                    if (padded_input.touched_padding) {
                        reportPack(diag, gpa, "pack is truncated mid deflate stream");
                        return error.CorruptPack;
                    }
                    if (n != header.size()) {
                        reportPack(diag, gpa, "declared object size does not match its decompressed length");
                        return error.CorruptPack;
                    }
                    try rewindUnused(pack, &padded_input, gpa, diag);
                    return base_kind;
                }
                break try decompressAlloc(gpa, pack, header.size(), diag);
            },
        }
    };
    errdefer gpa.free(current);

    var i: usize = chain.items.len;
    while (i > 0) {
        i -= 1;
        const delta_offset = chain.items[i];
        try seekOrCorrupt(pack, delta_offset, gpa, diag);
        const dheader = try EntryHeader.read(format, &pack.interface, gpa, diag);
        const patch = try decompressAlloc(gpa, pack, dheader.size(), diag);
        defer gpa.free(patch);

        if (i == 0) {
            delta_mod.delta.apply(current, patch, out) catch {
                reportPack(diag, gpa, "delta instruction stream is corrupt or its result size disagrees");
                return error.CorruptDelta;
            };
            gpa.free(current);
            return base_kind;
        }

        var aw: std.Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        delta_mod.delta.apply(current, patch, &aw.writer) catch {
            reportPack(diag, gpa, "delta instruction stream is corrupt or its result size disagrees");
            aw.deinit();
            return error.CorruptDelta;
        };
        gpa.free(current);
        current = try aw.toOwnedSlice();
    }

    // `current` is bound above only by walking at least one delta (the
    // direct, no-delta case returns from inside that loop instead), so
    // `chain.items.len` is always at least 1 here and the loop above
    // always returns through its `i == 0` branch.
    unreachable;
}

/// Computes the final object id and pack offset of every object in `pack`,
/// resolving delta chains as needed. Used both to answer a ref-delta's
/// "which offset holds this id" question, and to build a `.idx`.
///
/// Two passes: the first hashes every non-delta object directly and
/// records the deltas it cannot yet resolve; the second drains those
/// deltas, one full pass at a time, until every one resolves or a full
/// pass makes no progress. No progress means the pack's delta graph never
/// bottoms out, whether that is a true cycle or a base that is simply
/// absent; both are reported as `DeltaCycle`, since from this algorithm's
/// view they are the same failure to converge.
pub fn computeOidOffsets(
    gpa: Allocator,
    format: Format,
    pack: *std.Io.File.Reader,
    diag: ?*?Diagnostic,
) Pack.Error!Entries {
    try seekOrCorrupt(pack, 0, gpa, diag);

    var entries: Entries = .empty;
    errdefer entries.deinit(gpa);

    const Pending = struct { offset: u64, crc32: u32 };
    var pending: std.ArrayList(Pending) = .empty;
    defer pending.deinit(gpa);

    var crc_buf: [4096]u8 = undefined;
    var crc_reader = pack.file.reader(pack.io, &crc_buf);

    const header = try readPackHeader(&pack.interface, gpa, diag);

    var i: u32 = 0;
    while (i < header.object_count) : (i += 1) {
        const entry_start = pack.logicalPos();
        const entry_header = try EntryHeader.read(format, &pack.interface, gpa, diag);
        switch (entry_header) {
            .commit, .tree, .blob, .tag => {
                const kind = entry_header.kind().?;
                // Streamed straight into a hashing writer: a pack holding
                // one large blob must not spike memory just to learn its id.
                const oid = try hashDecompressedObject(pack, format, kind, entry_header.size(), gpa, diag);
                const entry_end = pack.logicalPos();
                const crc = try crc32Range(&crc_reader, entry_start, entry_end, gpa, diag);
                try entries.put(gpa, oid, .{ .offset = entry_start, .crc32 = crc });
            },
            .ofs_delta, .ref_delta => {
                try discardCompressed(pack, entry_header.size(), gpa, diag);
                const entry_end = pack.logicalPos();
                const crc = try crc32Range(&crc_reader, entry_start, entry_end, gpa, diag);
                try pending.append(gpa, .{ .offset = entry_start, .crc32 = crc });
            },
        }
    }

    while (pending.items.len != 0) {
        var progressed = false;
        var idx: usize = pending.items.len;
        while (idx > 0) {
            idx -= 1;
            const item = pending.items[idx];
            var aw: std.Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            const resolver = entriesResolver(&entries);
            const kind = try resolveChain(gpa, format, pack, item.offset, resolver, &aw.writer, diag);
            if (kind) |k| {
                const oid = object_mod.loose.hash(format, k, aw.writer.buffered());
                try entries.put(gpa, oid, .{ .offset = item.offset, .crc32 = item.crc32 });
                _ = pending.swapRemove(idx);
                progressed = true;
            }
        }
        if (!progressed) {
            reportPack(diag, gpa, "delta chain never resolves: a cycle, or a base that never appears");
            return error.DeltaCycle;
        }
    }

    return entries;
}

// Byte-exact vectors. Every pack below is assembled from a small builder
// that writes the same varint and zlib framing `EntryHeader.read` parses,
// rather than a literal byte table: the framing is explicit and hand
// checked here, and the deflate bit stream itself comes from the same
// library code the rest of ziggit relies on, exactly as `loose.write`
// leans on it for loose objects.

pub const TestEntry = union(enum) {
    object: struct { kind: ObjectKind, payload: []const u8 },
    ofs_delta: struct { base_index: usize, patch: []const u8 },
    ref_delta: struct { base_id: Oid, patch: []const u8 },
};

pub const BuiltPack = struct {
    bytes: []u8,
    /// The start offset of each entry in `bytes`, in the order given to
    /// `buildTestPack`. Owned by this struct, freed by `deinit`.
    offsets: []u64,

    pub fn deinit(bp: *BuiltPack, gpa: Allocator) void {
        gpa.free(bp.bytes);
        gpa.free(bp.offsets);
    }
};

fn entryTypeOf(kind: ObjectKind) EntryType {
    return switch (kind) {
        .commit => .commit,
        .tree => .tree,
        .blob => .blob,
        .tag => .tag,
    };
}

fn writeVarintHeader(w: *std.Io.Writer, entry_type: EntryType, size_in: u64) !void {
    var value = size_in;
    var first_byte: u8 = (@as(u8, @intFromEnum(entry_type)) << 4) | @as(u8, @truncate(value & 0x0f));
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

/// Inverts `readOffsetVarint`. Transliterated from git's own encoder rather
/// than derived by hand, since the "+1 before each shift" decode rule is
/// easy to invert wrong; the pack tests below round trip through it to
/// confirm it agrees with this file's own decoder.
fn writeOffsetVarint(w: *std.Io.Writer, distance_in: u64) !void {
    var buf: [10]u8 = undefined;
    var pos: usize = buf.len - 1;
    var offset = distance_in;
    buf[pos] = @truncate(offset & 0x7f);
    offset >>= 7;
    while (offset != 0) {
        offset -= 1;
        pos -= 1;
        buf[pos] = 0x80 | @as(u8, @truncate(offset & 0x7f));
        offset >>= 7;
    }
    try w.writeAll(buf[pos..]);
}

fn writeZlib(w: *std.Io.Writer, payload: []const u8) !void {
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compress = try std.compress.flate.Compress.init(w, &window, .zlib, .default);
    try compress.writer.writeAll(payload);
    try compress.finish();
}

pub fn buildTestPack(gpa: Allocator, format: Format, test_entries: []const TestEntry) !BuiltPack {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("PACK");
    try w.writeInt(u32, 2, .big);
    try w.writeInt(u32, @intCast(test_entries.len), .big);

    const offsets = try gpa.alloc(u64, test_entries.len);
    errdefer gpa.free(offsets);

    for (test_entries, 0..) |e, idx| {
        const start: u64 = aw.writer.buffered().len;
        offsets[idx] = start;
        switch (e) {
            .object => |o| {
                try writeVarintHeader(w, entryTypeOf(o.kind), o.payload.len);
                try writeZlib(w, o.payload);
            },
            .ofs_delta => |d| {
                const distance = start - offsets[d.base_index];
                try writeVarintHeader(w, .ofs_delta, d.patch.len);
                try writeOffsetVarint(w, distance);
                try writeZlib(w, d.patch);
            },
            .ref_delta => |d| {
                try writeVarintHeader(w, .ref_delta, d.patch.len);
                try w.writeAll(d.base_id.slice());
                try writeZlib(w, d.patch);
            },
        }
    }

    var hasher = Hasher.init(format);
    hasher.update(aw.writer.buffered());
    const trailer = hasher.final();
    try w.writeAll(trailer.slice());

    const bytes = try aw.toOwnedSlice();
    return .{ .bytes = bytes, .offsets = offsets };
}

/// Opens `bytes` as a pack under `tmp_dir`. `file_out` receives the open
/// file handle, which the caller must keep open (and close) for as long as
/// the returned `Pack` is in use: `Pack` reads through it lazily on every
/// `readAt`, not only at `open`.
fn openTestPack(
    gpa: Allocator,
    tmp_dir: std.Io.Dir,
    io: std.Io,
    bytes: []const u8,
    f: Format,
    file_out: *std.Io.File,
) !Pack {
    try tmp_dir.writeFile(io, .{ .sub_path = "t.pack", .data = bytes });
    file_out.* = try tmp_dir.openFile(io, "t.pack", .{});
    return Pack.open(gpa, io, file_out.*, f);
}

// expected

// A crc32 that silently disagreed with real git would be accepted here and
// rejected by every other implementation forever, with this suite staying
// green throughout. Pinning the hash itself against a published vector,
// independent of any pack or index I/O, is what would catch that class of
// regression immediately.
test "std.hash.Crc32 matches the published CRC-32 check value" {
    var hasher = std.hash.Crc32.init();
    hasher.update("123456789");
    try std.testing.expectEqual(@as(u32, 0xCBF43926), hasher.final());
}

test "Pack open reads the header version and object count" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var built = try buildTestPack(gpa, .sha1, &.{
        .{ .object = .{ .kind = .blob, .payload = "hello\n" } },
        .{ .object = .{ .kind = .blob, .payload = "world\n" } },
    });
    defer built.deinit(gpa);

    var file: std.Io.File = undefined;
    var pack = try openTestPack(gpa, tmp.dir, io, built.bytes, .sha1, &file);
    defer file.close(io);
    defer pack.deinit();
    try std.testing.expectEqual(@as(u32, 2), pack.objectCount());
}

test "readAt returns a whole blob that is not a delta" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var built = try buildTestPack(gpa, .sha1, &.{
        .{ .object = .{ .kind = .blob, .payload = "hello\n" } },
    });
    defer built.deinit(gpa);

    var file: std.Io.File = undefined;
    var pack = try openTestPack(gpa, tmp.dir, io, built.bytes, .sha1, &file);
    defer file.close(io);
    defer pack.deinit();

    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const kind = try pack.readAt(gpa, built.offsets[0], &out, null);
    try std.testing.expectEqual(ObjectKind.blob, kind);
    try std.testing.expectEqualStrings("hello\n", out.buffered());
}

test "readAt reconstructs an object stored as an ofs delta" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // base_size=11, result_size=5, copy(offset=6, size=5) of "hello world" -> "world".
    const patch = [_]u8{ 11, 5, 0x91, 6, 5 };
    var built = try buildTestPack(gpa, .sha1, &.{
        .{ .object = .{ .kind = .blob, .payload = "hello world" } },
        .{ .ofs_delta = .{ .base_index = 0, .patch = &patch } },
    });
    defer built.deinit(gpa);

    var file: std.Io.File = undefined;
    var pack = try openTestPack(gpa, tmp.dir, io, built.bytes, .sha1, &file);
    defer file.close(io);
    defer pack.deinit();

    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const kind = try pack.readAt(gpa, built.offsets[1], &out, null);
    try std.testing.expectEqual(ObjectKind.blob, kind);
    try std.testing.expectEqualStrings("world", out.buffered());
}

test "readAt reconstructs an object stored as a ref delta" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const base_payload = "hello world";
    const base_id = object_mod.loose.hash(.sha1, .blob, base_payload);
    // base_size=11, result_size=5, copy(offset=0, size=5) of "hello world" -> "hello".
    const patch = [_]u8{ 11, 5, 0x91, 0, 5 };
    var built = try buildTestPack(gpa, .sha1, &.{
        .{ .object = .{ .kind = .blob, .payload = base_payload } },
        .{ .ref_delta = .{ .base_id = base_id, .patch = &patch } },
    });
    defer built.deinit(gpa);

    var file: std.Io.File = undefined;
    var pack = try openTestPack(gpa, tmp.dir, io, built.bytes, .sha1, &file);
    defer file.close(io);
    defer pack.deinit();

    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const kind = try pack.readAt(gpa, built.offsets[1], &out, null);
    try std.testing.expectEqual(ObjectKind.blob, kind);
    try std.testing.expectEqualStrings("hello", out.buffered());
}

// suspicious

test "Pack open rejects a version that is not 2" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [12]u8 = undefined;
    @memcpy(buf[0..4], "PACK");
    std.mem.writeInt(u32, buf[4..8], 3, .big);
    std.mem.writeInt(u32, buf[8..12], 0, .big);

    var file: std.Io.File = undefined;
    defer file.close(io);
    try std.testing.expectError(
        error.UnsupportedPackVersion,
        openTestPack(gpa, tmp.dir, io, &buf, .sha1, &file),
    );
}

test "Pack open rejects a file whose magic is not PACK" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [12]u8 = undefined;
    @memcpy(buf[0..4], "XXXX");
    std.mem.writeInt(u32, buf[4..8], 2, .big);
    std.mem.writeInt(u32, buf[8..12], 0, .big);

    var file: std.Io.File = undefined;
    defer file.close(io);
    try std.testing.expectError(
        error.CorruptPack,
        openTestPack(gpa, tmp.dir, io, &buf, .sha1, &file),
    );
}

test "verifyChecksum rejects a pack whose trailing hash does not match" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var built = try buildTestPack(gpa, .sha1, &.{
        .{ .object = .{ .kind = .blob, .payload = "hello\n" } },
    });
    defer built.deinit(gpa);
    // Flip the last trailer byte so it no longer matches the pack's hash.
    built.bytes[built.bytes.len - 1] ^= 0xff;

    var file: std.Io.File = undefined;
    var pack = try openTestPack(gpa, tmp.dir, io, built.bytes, .sha1, &file);
    defer file.close(io);
    defer pack.deinit();

    try std.testing.expectError(error.BadPackChecksum, pack.verifyChecksum());
}

test "readAt rejects a delta entry claiming a decompressed size the file cannot back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;

    try w.writeAll("PACK");
    try w.writeInt(u32, 2, .big);
    try w.writeInt(u32, 2, .big);

    const base_offset: u64 = aw.writer.buffered().len;
    try writeVarintHeader(w, .blob, "hello world".len);
    try writeZlib(w, "hello world");

    const delta_offset: u64 = aw.writer.buffered().len;
    // Claims a patch that decompresses to 50 billion bytes. The pack this
    // entry lives in is a few dozen bytes long; no real patch this short
    // could ever decompress to anywhere near that. Before the fix, this
    // declared size alone drove the allocation, before a single further
    // byte of the entry was checked.
    try writeVarintHeader(w, .ofs_delta, 50_000_000_000);
    try writeOffsetVarint(w, delta_offset - base_offset);
    try writeZlib(w, &[_]u8{ 11, 5, 0x91, 0, 5 }); // a well-formed but irrelevant patch

    var hasher = Hasher.init(.sha1);
    hasher.update(aw.writer.buffered());
    const trailer = hasher.final();
    try w.writeAll(trailer.slice());
    const bytes = try aw.toOwnedSlice();
    defer gpa.free(bytes);

    var file: std.Io.File = undefined;
    var pack = try openTestPack(gpa, tmp.dir, io, bytes, .sha1, &file);
    defer file.close(io);
    defer pack.deinit();

    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    // Checking `diag`'s detail, not only the error value, is what tells this
    // rejection apart from one that only happened to fail later for an
    // unrelated reason (for example, decompression running out of input
    // after a huge allocation had already been attempted): a bound-check
    // rejection names the bound, nothing else in this path does.
    var diag: ?Diagnostic = null;
    try std.testing.expectError(error.CorruptPack, pack.readAt(gpa, delta_offset, &out, &diag));
    defer if (diag) |*d| d.deinit(gpa);
    try std.testing.expect(diag != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.?.detail.?, "cannot fit in the bytes left") != null);
}

test "a delta chain deeper than max_delta_depth fails with DeltaChainTooDeep" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Each link copies the whole 5 byte base unchanged: base_size=5,
    // result_size=5, copy(offset=0, size=5).
    const patch = [_]u8{ 5, 5, 0x91, 0, 5 };

    var test_entries: std.ArrayList(TestEntry) = .empty;
    defer test_entries.deinit(gpa);
    try test_entries.append(gpa, .{ .object = .{ .kind = .blob, .payload = "abcde" } });
    var link: usize = 0;
    while (link < Pack.max_delta_depth + 1) : (link += 1) {
        try test_entries.append(gpa, .{ .ofs_delta = .{ .base_index = link, .patch = &patch } });
    }

    var built = try buildTestPack(gpa, .sha1, test_entries.items);
    defer built.deinit(gpa);

    var file: std.Io.File = undefined;
    var pack = try openTestPack(gpa, tmp.dir, io, built.bytes, .sha1, &file);
    defer file.close(io);
    defer pack.deinit();

    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const last_offset = built.offsets[built.offsets.len - 1];
    try std.testing.expectError(
        error.DeltaChainTooDeep,
        pack.readAt(gpa, last_offset, &out, null),
    );
}

test "a ref delta naming its own id fails with DeltaCycle rather than looping" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The only object in this pack is a ref-delta. Its base id can only
    // ever be produced by resolving this very entry, which can only ever
    // happen once its base id is known: nothing in the pack can complete
    // it, so this is a cycle of exactly one link, not a merely missing base.
    const self_id = Oid.fromBytes(.sha1, &([_]u8{0xab} ** 20));
    const patch = [_]u8{ 0, 1, 1, 'x' };
    var built = try buildTestPack(gpa, .sha1, &.{
        .{ .ref_delta = .{ .base_id = self_id, .patch = &patch } },
    });
    defer built.deinit(gpa);

    var file: std.Io.File = undefined;
    var pack = try openTestPack(gpa, tmp.dir, io, built.bytes, .sha1, &file);
    defer file.close(io);
    defer pack.deinit();

    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try std.testing.expectError(
        error.DeltaCycle,
        pack.readAt(gpa, built.offsets[0], &out, null),
    );
}

// A pack truncated mid deflate stream, on a real file-backed reader, used
// to trip an `unreachable`-adjacent trap inside `std.compress.flate.Decompress`
// rather than returning `error.CorruptPack`: its own end-of-input handling
// (`peekBitsEnding`) computes `buffered_bytes * 8 - consumed_bits` with no
// guard against the wrapped reader running out of bytes entirely, and that
// subtraction underflows once truncation lands inside the bitstream itself.
// Every truncation test below opens through `openTestPack`, so it exercises
// the same real, file-backed `std.Io.File.Reader` the earlier report used to
// reproduce the trap; `resolveChain`'s `PaddedInput` wrapper is what now
// keeps `Decompress` from ever seeing that wrapped reader's true end.

test "readAt rejects a pack that ends before an entry's header byte arrives" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var built = try buildTestPack(gpa, .sha1, &.{
        .{ .object = .{ .kind = .blob, .payload = "hello\n" } },
    });
    defer built.deinit(gpa);

    // The 12 byte "PACK" header parses fine; nothing of the one entry that
    // follows does.
    const pack_header_len = 12;
    try std.testing.expectEqual(@as(u64, pack_header_len), built.offsets[0]);

    var file: std.Io.File = undefined;
    var pack = try openTestPack(gpa, tmp.dir, io, built.bytes[0..pack_header_len], .sha1, &file);
    defer file.close(io);
    defer pack.deinit();

    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try std.testing.expectError(error.CorruptPack, pack.readAt(gpa, built.offsets[0], &out, null));
}

test "readAt rejects a pack that ends mid entry size varint" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A 200 byte payload needs a two byte size varint: 200 & 0x0f = 8 fits
    // the header's first byte alongside the type tag, but 200 >> 4 = 12 is
    // nonzero, so that first byte sets the continuation bit and a second
    // varint byte follows. Truncating right after that first byte leaves
    // the continuation promised but never delivered.
    const payload = [_]u8{'x'} ** 200;
    var built = try buildTestPack(gpa, .sha1, &.{
        .{ .object = .{ .kind = .blob, .payload = &payload } },
    });
    defer built.deinit(gpa);

    const cut = built.offsets[0] + 1;
    var file: std.Io.File = undefined;
    var pack = try openTestPack(gpa, tmp.dir, io, built.bytes[0..cut], .sha1, &file);
    defer file.close(io);
    defer pack.deinit();

    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try std.testing.expectError(error.CorruptPack, pack.readAt(gpa, built.offsets[0], &out, null));
}

test "readAt rejects a pack that ends right after the entry header, before any deflate byte" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Same 200 byte payload as above: a two byte header (verified below by
    // checking the very next byte is the zlib stream's own CMF byte), then
    // nothing -- the entry header parses in full, but decompression starts
    // with zero bytes available rather than merely running out partway in.
    const payload = [_]u8{'x'} ** 200;
    var built = try buildTestPack(gpa, .sha1, &.{
        .{ .object = .{ .kind = .blob, .payload = &payload } },
    });
    defer built.deinit(gpa);

    const header_len = 2;
    try std.testing.expectEqual(@as(u8, 0x78), built.bytes[built.offsets[0] + header_len]);
    const cut = built.offsets[0] + header_len;

    var file: std.Io.File = undefined;
    var pack = try openTestPack(gpa, tmp.dir, io, built.bytes[0..cut], .sha1, &file);
    defer file.close(io);
    defer pack.deinit();

    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try std.testing.expectError(error.CorruptPack, pack.readAt(gpa, built.offsets[0], &out, null));
}

test "readAt rejects a pack truncated at every position inside a real deflate bitstream, never panicking" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // Compressible, multi-block payload: exactly 4096 bytes, so its size
    // varint header is exactly 3 bytes (4096 & 0x0f = 0 with two more
    // continuation bytes needed for 4096 >> 4 = 256), verified below the
    // same way as the header-boundary test above, before the compressed
    // bitstream itself begins.
    const line = "the quick brown fox jumps over the lazy dog while ziggit reads a pack\n";
    var payload_buf: [4096]u8 = undefined;
    var filled: usize = 0;
    while (filled + line.len <= payload_buf.len) : (filled += line.len) {
        @memcpy(payload_buf[filled..][0..line.len], line);
    }
    @memset(payload_buf[filled..], 'x');

    var built = try buildTestPack(gpa, .sha1, &.{
        .{ .object = .{ .kind = .blob, .payload = &payload_buf } },
    });
    defer built.deinit(gpa);

    const header_len = 3;
    try std.testing.expectEqual(@as(u8, 0x78), built.bytes[built.offsets[0] + header_len]);

    const trailer_len = Format.sha1.byteLength();
    const deflate_start = built.offsets[0] + header_len;
    const deflate_end = built.bytes.len - trailer_len;
    try std.testing.expect(deflate_end - deflate_start > 20);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cut = deflate_start + 1;
    while (cut < deflate_end) : (cut += 1) {
        var file: std.Io.File = undefined;
        var pack = try openTestPack(gpa, tmp.dir, io, built.bytes[0..cut], .sha1, &file);
        defer file.close(io);
        defer pack.deinit();

        var out_buf: [8192]u8 = undefined;
        var out: std.Io.Writer = .fixed(&out_buf);
        try std.testing.expectError(error.CorruptPack, pack.readAt(gpa, built.offsets[0], &out, null));
    }
}
