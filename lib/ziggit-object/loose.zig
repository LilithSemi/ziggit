//! Loose object framing: the uncompressed header every loose object carries,
//! and the zlib envelope git stores it under on disk.
//!
//! This file draws the line between "bytes a hash covers" and "bytes on
//! disk". The header and the payload together are what `loose.hash` and
//! `loose.write` feed to the hasher; the zlib wrapper is disk dress that
//! never reaches the hash.

const std = @import("std");
const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;
const Hasher = oid_mod.Hasher;
const core_mod = @import("ziggit-core");
const ObjectKind = core_mod.ObjectKind;

/// The uncompressed header a loose object carries: "<kind> <size>\0". `size`
/// is the payload length in bytes, written as a minimal decimal: git treats
/// a leading zero as corrupt, since it never writes one itself.
pub const Header = struct {
    kind: ObjectKind,
    size: u64,

    pub const ParseError = error{CorruptObjectHeader};

    /// Reads the header off `r`, leaving `r` positioned at the first payload
    /// byte. Any failure reading `r` itself, not only a malformed header
    /// line, is reported as `CorruptObjectHeader`: a header this function
    /// cannot finish reading is not usable either way.
    pub fn read(r: *std.Io.Reader) ParseError!Header {
        const line = r.takeSentinel(0) catch return error.CorruptObjectHeader;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return error.CorruptObjectHeader;
        const kind = ObjectKind.fromName(line[0..sp]) orelse return error.CorruptObjectHeader;
        const size = parseSize(line[sp + 1 ..]) orelse return error.CorruptObjectHeader;
        return .{ .kind = kind, .size = size };
    }

    pub fn write(h: Header, w: *std.Io.Writer) std.Io.Writer.Error!void {
        var buf: [max_header_len]u8 = undefined;
        try w.writeAll(headerBytes(&buf, h.kind, h.size));
    }
};

/// Longest header this module ever builds: the longest kind name ("commit"),
/// one space, the longest decimal spelling of a u64, and the nul.
const max_header_len = "commit".len + 1 + 20 + 1;

/// Builds "<kind> <size>\0" into `buf` and returns the written slice. `buf`
/// must be at least `max_header_len` bytes long, which every caller in this
/// file guarantees, so this never fails.
fn headerBytes(buf: *[max_header_len]u8, kind: ObjectKind, size: u64) []const u8 {
    const name = kind.name();
    @memcpy(buf[0..name.len], name);
    buf[name.len] = ' ';
    var digit_buf: [20]u8 = undefined;
    const digits = writeDecimal(&digit_buf, size);
    @memcpy(buf[name.len + 1 ..][0..digits.len], digits);
    buf[name.len + 1 + digits.len] = 0;
    return buf[0 .. name.len + 1 + digits.len + 1];
}

/// Formats `v` as a minimal decimal ("0" for zero, no leading zero
/// otherwise) into `buf`, which must hold at least 20 bytes: the longest
/// decimal spelling of a u64. Returns the written part of `buf`.
fn writeDecimal(buf: *[20]u8, v: u64) []const u8 {
    if (v == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var i: usize = buf.len;
    var n = v;
    while (n != 0) {
        i -= 1;
        buf[i] = @as(u8, @intCast('0' + n % 10));
        n /= 10;
    }
    return buf[i..];
}

/// Parses a minimal decimal size: only ASCII digits, "0" for zero, and no
/// leading zero on any other value. Returns null for anything else,
/// including a value too large for a u64.
fn parseSize(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    if (s.len > 1 and s[0] == '0') return null;
    var value: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        value = std.math.mul(u64, value, 10) catch return null;
        value = std.math.add(u64, value, c - '0') catch return null;
    }
    return value;
}

pub const loose = struct {
    pub const ReadError = error{
        CorruptObjectHeader,
        WindowTooSmall,
    } || std.mem.Allocator.Error;

    /// Decompresses a loose object's zlib envelope and returns its header
    /// plus a reader positioned at the first payload byte. `payload` reads
    /// straight out of `decompress`; `open` never buffers the payload
    /// itself, so a caller can read an object of any size, a blob can be a
    /// gigabyte, one chunk at a time instead of pre-sizing a buffer to the
    /// biggest object it will ever see.
    ///
    /// `decompress` is caller-owned storage for the flate decompressor, and
    /// `window` backs its sliding window and output buffer. Both must
    /// outlive every read through `payload`, since `payload` points into
    /// `decompress`. This shape exists because a `std.compress.flate.Decompress`
    /// returned by value does not keep the address it held while being
    /// built: a self pointer computed before `return` (as `&decompress.reader`
    /// would be, if `decompress` lived inside `open`) silently dangles in
    /// Zig 0.16. Keeping `decompress` in the caller's frame instead of
    /// building it inside `open` sidesteps that hazard rather than working
    /// around it. See the task report for the experiment that found the
    /// original problem.
    ///
    /// `window` must be at least `std.compress.flate.max_window_len` bytes.
    /// A short `window` is a caller sizing mistake, not a corrupt object, so
    /// `open` reports it as `WindowTooSmall` and never as `CorruptObjectHeader`.
    ///
    /// `open` reads only as far as the header. It does not confirm that
    /// `payload` holds exactly `header.size` bytes: doing that here would
    /// mean reading the whole object before returning, the very buffering
    /// this function exists to avoid. A caller that must know calls
    /// `verifySize` on `payload`, or reaches the same guarantee for free by
    /// counting the bytes it copies or hashes out of `payload` itself.
    pub fn open(
        r: *std.Io.Reader,
        window: []u8,
        decompress: *std.compress.flate.Decompress,
    ) ReadError!struct {
        header: Header,
        payload: *std.Io.Reader,
    } {
        if (window.len < std.compress.flate.max_window_len) return error.WindowTooSmall;
        decompress.* = std.compress.flate.Decompress.init(r, .zlib, window);
        const header = try Header.read(&decompress.reader);
        return .{ .header = header, .payload = &decompress.reader };
    }

    pub const VerifySizeError = error{CorruptObject} || std.Io.Reader.ShortError;

    /// Confirms that exactly `size` bytes remain in `payload`: neither
    /// fewer, the header overstated the size, nor more, the header
    /// understated it. Reads through a small fixed-size scratch buffer no
    /// matter how large `size` is, so checking a gigabyte object costs no
    /// more memory than checking a one byte object.
    ///
    /// `open` does not run this check itself; call it once a caller has
    /// decided it needs the guarantee, after `open` and before doing
    /// anything else with `payload`.
    pub fn verifySize(payload: *std.Io.Reader, size: u64) VerifySizeError!void {
        var scratch: [4096]u8 = undefined;
        var remaining = size;
        while (remaining != 0) {
            const chunk_len = @min(scratch.len, remaining);
            const n = try payload.readSliceShort(scratch[0..chunk_len]);
            if (n == 0) return error.CorruptObject;
            remaining -= n;
        }

        // A well formed object ends exactly here. One more readable byte
        // means the header under-reported the size.
        var extra: [1]u8 = undefined;
        const extra_n = try payload.readSliceShort(&extra);
        if (extra_n != 0) return error.CorruptObject;
    }

    /// Compresses `payload` with its header into `w` and returns the object
    /// id. `w` must have a buffer of more than 8 bytes; that is a
    /// requirement of `std.compress.flate.Compress`, which this builds on.
    pub fn write(
        f: Format,
        kind: ObjectKind,
        payload: []const u8,
        w: *std.Io.Writer,
    ) std.Io.Writer.Error!Oid {
        const id = hash(f, kind, payload);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var compress = try std.compress.flate.Compress.init(w, &window, .zlib, .default);
        var buf: [max_header_len]u8 = undefined;
        try compress.writer.writeAll(headerBytes(&buf, kind, payload.len));
        try compress.writer.writeAll(payload);
        try compress.finish();
        return id;
    }

    /// The id `payload` would have, without writing anything.
    pub fn hash(f: Format, kind: ObjectKind, payload: []const u8) Oid {
        var hasher = Hasher.init(f);
        var buf: [max_header_len]u8 = undefined;
        hasher.update(headerBytes(&buf, kind, payload.len));
        hasher.update(payload);
        return hasher.final();
    }
};

// Byte-exact vectors, hand verified against `git hash-object` and
// `sha1sum` before any of the code above existed. These are what stop a bug
// in the writer from hiding the same bug in the reader: both directions are
// checked against a value neither of them produced.

/// An empty tree: no entries, zero byte payload.
const empty_tree_payload = "";
const empty_tree_sha1 = "4b825dc642cb6eb9a060e54bf8d69288fbee4904";

/// A blob holding the six bytes "hello\n".
const hello_blob_payload = "hello\n";
const hello_blob_sha1 = "ce013625030ba8dba906f756967f9e9ca394464a";

// expected

test "hash of an empty tree is 4b825dc642cb6eb9a060e54bf8d69288fbee4904" {
    const id = loose.hash(.sha1, .tree, empty_tree_payload);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings(empty_tree_sha1, id.toHex(&buf));
}

test "hash of the blob hello is ce013625030ba8dba906f756967f9e9ca394464a" {
    const id = loose.hash(.sha1, .blob, hello_blob_payload);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings(hello_blob_sha1, id.toHex(&buf));
}

test "loose write then open round trips a blob" {
    var out_buf: [256]u8 = undefined;
    var out_w: std.Io.Writer = .fixed(&out_buf);
    const written_id = try loose.write(.sha1, .blob, hello_blob_payload, &out_w);

    var in_r: std.Io.Reader = .fixed(out_w.buffered());
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = undefined;
    var opened = try loose.open(&in_r, &window, &decompress);

    try std.testing.expect(written_id.eql(loose.hash(.sha1, .blob, hello_blob_payload)));
    try std.testing.expectEqual(ObjectKind.blob, opened.header.kind);
    try std.testing.expectEqual(@as(u64, hello_blob_payload.len), opened.header.size);
    const read_back = try opened.payload.take(hello_blob_payload.len);
    try std.testing.expectEqualStrings(hello_blob_payload, read_back);
}

test "Header write then read round trips" {
    var buf: [max_header_len]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const h: Header = .{ .kind = .commit, .size = 12345 };
    try h.write(&w);

    var r: std.Io.Reader = .fixed(w.buffered());
    const read_back = try Header.read(&r);
    try std.testing.expectEqual(h.kind, read_back.kind);
    try std.testing.expectEqual(h.size, read_back.size);
}

// suspicious

test "Header read rejects a size with a leading zero" {
    var r: std.Io.Reader = .fixed("blob 06\x00");
    try std.testing.expectError(error.CorruptObjectHeader, Header.read(&r));
}

test "Header read rejects a missing nul terminator" {
    var r: std.Io.Reader = .fixed("blob 6");
    try std.testing.expectError(error.CorruptObjectHeader, Header.read(&r));
}

test "Header read rejects an unknown kind" {
    var r: std.Io.Reader = .fixed("widget 6\x00");
    try std.testing.expectError(error.CorruptObjectHeader, Header.read(&r));
}

test "loose open reports a short window buffer as WindowTooSmall, not corruption" {
    var out_buf: [256]u8 = undefined;
    var out_w: std.Io.Writer = .fixed(&out_buf);
    _ = try loose.write(.sha1, .blob, hello_blob_payload, &out_w);

    var in_r: std.Io.Reader = .fixed(out_w.buffered());
    var short_window: [16]u8 = undefined;
    var decompress: std.compress.flate.Decompress = undefined;
    try std.testing.expectError(error.WindowTooSmall, loose.open(&in_r, &short_window, &decompress));
}

test "loose open rejects a payload shorter than the header claims" {
    // A validly zlib-framed object whose header claims one more byte than
    // the payload actually holds. `open` itself does not notice, since it
    // reads only the header; `verifySize` is what a caller reaches for to
    // catch this, once it has decided it needs the guarantee.
    var lie_buf: [256]u8 = undefined;
    var lie_w: std.Io.Writer = .fixed(&lie_buf);
    var lie_window: [std.compress.flate.max_window_len]u8 = undefined;
    var lie_compress = try std.compress.flate.Compress.init(&lie_w, &lie_window, .zlib, .default);
    var hbuf: [max_header_len]u8 = undefined;
    try lie_compress.writer.writeAll(headerBytes(&hbuf, .blob, 3));
    try lie_compress.writer.writeAll("hi");
    try lie_compress.finish();

    var lie_r: std.Io.Reader = .fixed(lie_w.buffered());
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = undefined;
    const opened = try loose.open(&lie_r, &window, &decompress);
    try std.testing.expectError(error.CorruptObject, loose.verifySize(opened.payload, opened.header.size));
}

test "loose open rejects a payload longer than the header claims" {
    var lie_buf: [256]u8 = undefined;
    var lie_w: std.Io.Writer = .fixed(&lie_buf);
    var lie_window: [std.compress.flate.max_window_len]u8 = undefined;
    var lie_compress = try std.compress.flate.Compress.init(&lie_w, &lie_window, .zlib, .default);
    var hbuf: [max_header_len]u8 = undefined;
    try lie_compress.writer.writeAll(headerBytes(&hbuf, .blob, 1));
    try lie_compress.writer.writeAll("hi");
    try lie_compress.finish();

    var lie_r: std.Io.Reader = .fixed(lie_w.buffered());
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = undefined;
    const opened = try loose.open(&lie_r, &window, &decompress);
    try std.testing.expectError(error.CorruptObject, loose.verifySize(opened.payload, opened.header.size));
}

// regression

test "loose open's payload reader keeps streaming a payload larger than the flate window after open returns" {
    // A payload spanning several times the flate window forces `payload` to
    // refill its internal buffer more than once. This is the streaming
    // guarantee `open` exists to provide: a caller reads it in chunks
    // instead of sizing a buffer to the whole object up front.
    const gpa = std.testing.allocator;
    const payload_len = 3 * std.compress.flate.max_window_len + 4096;
    const payload = try gpa.alloc(u8, payload_len);
    defer gpa.free(payload);
    for (payload, 0..) |*b, i| b.* = @intCast(i % 251);

    const out_buf = try gpa.alloc(u8, payload_len * 2);
    defer gpa.free(out_buf);
    var out_w: std.Io.Writer = .fixed(out_buf);
    _ = try loose.write(.sha1, .blob, payload, &out_w);

    // `window` and `decompress` live for the rest of this test, as `open`'s
    // contract requires: `payload` points into `decompress`.
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = undefined;
    var opened = blk: {
        var in_r: std.Io.Reader = .fixed(out_w.buffered());
        break :blk try loose.open(&in_r, &window, &decompress);
    };
    try std.testing.expectEqual(@as(u64, payload_len), opened.header.size);

    var read_total: usize = 0;
    var chunk: [4096]u8 = undefined;
    while (read_total < payload_len) {
        const n = try opened.payload.readSliceShort(&chunk);
        try std.testing.expect(n > 0);
        try std.testing.expectEqualSlices(u8, payload[read_total..][0..n], chunk[0..n]);
        read_total += n;
    }
    try std.testing.expectEqual(payload_len, read_total);
}

test "loose open's payload reader does not depend on locals that go out of scope in the caller" {
    var out_buf: [256]u8 = undefined;
    var out_w: std.Io.Writer = .fixed(&out_buf);
    _ = try loose.write(.sha1, .blob, hello_blob_payload, &out_w);

    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = undefined;
    var opened = blk: {
        // Only `in_r` is scoped to this block. `window` and `decompress`
        // live in the enclosing function, exactly as `open`'s doc comment
        // requires, so `payload` (which points into `decompress`) stays
        // valid past the block's end.
        var in_r: std.Io.Reader = .fixed(out_w.buffered());
        break :blk try loose.open(&in_r, &window, &decompress);
    };

    // Overwrite the stack where `in_r` used to live before reading
    // `payload`, so a reference to it that escaped would show up as
    // corrupted bytes instead of passing by accident.
    var clobber: [4096]u8 = @splat(0xaa);
    std.mem.doNotOptimizeAway(&clobber);

    const read_back = try opened.payload.take(hello_blob_payload.len);
    try std.testing.expectEqualStrings(hello_blob_payload, read_back);
}
