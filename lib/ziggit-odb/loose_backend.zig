//! The loose object half of `Odb`: one object per file, at
//! `objects/<first two hex digits>/<remaining hex digits>`. This file
//! knows nothing about packs or alternates; `Odb` decides which
//! directories to ask and in which order.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;

const core_mod = @import("ziggit-core");
const ObjectKind = core_mod.ObjectKind;
const Diagnostic = core_mod.Diagnostic;

const object_mod = @import("ziggit-object");
const Header = object_mod.Header;
const loose = object_mod.loose;

const ObjectStat = @import("object_stat.zig").ObjectStat;

pub const Error = error{
    CorruptObject,
    IoFailed,
} || Allocator.Error;

/// Builds the loose object path "xx/yyyy..." for `oid` into `buf`, which
/// must be at least `Oid.max_formatted_length + 1` bytes long (every call
/// site in this file provides exactly that). Returns the written slice.
fn objectPath(buf: *[Oid.max_formatted_length + 1]u8, oid: Oid) []const u8 {
    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const hex = oid.toHex(&hex_buf);
    @memcpy(buf[0..2], hex[0..2]);
    buf[2] = '/';
    @memcpy(buf[3..][0 .. hex.len - 2], hex[2..]);
    return buf[0 .. hex.len + 1];
}

/// Whether the loose object `oid` exists. A real fault checking it (a
/// permission error, for example) is `error.IoFailed`, distinct from
/// `false`: only `error.FileNotFound` genuinely means "not here", and
/// folding every other fault into that same answer would let a caller
/// like `Odb.write` decide a duplicate write is safe to skip when it
/// never actually confirmed the object was there.
pub fn exists(dir: std.Io.Dir, io: std.Io, oid: Oid) Error!bool {
    var buf: [Oid.max_formatted_length + 1]u8 = undefined;
    const path = objectPath(&buf, oid);
    _ = dir.statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return error.IoFailed,
    };
    return true;
}

fn reportCorrupt(diag: ?*?Diagnostic, gpa: Allocator, detail: []const u8) void {
    if (!core_mod.wants(diag)) return;
    const dup = gpa.dupe(u8, detail) catch null;
    core_mod.report(diag, gpa, .{ .kind = .corrupt_object, .path = null, .detail = dup });
}

/// The kind and size of the loose object `oid`, read off its header alone.
/// Returns null when there is no such loose object. Never decompresses the
/// payload, so this is cheap even for a gigabyte blob.
pub fn stat(gpa: Allocator, io: std.Io, dir: std.Io.Dir, oid: Oid, diag: ?*?Diagnostic) Error!?ObjectStat {
    var buf: [Oid.max_formatted_length + 1]u8 = undefined;
    const path = objectPath(&buf, oid);
    var file = dir.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            reportCorrupt(diag, gpa, "cannot open loose object file");
            return error.IoFailed;
        },
    };
    defer file.close(io);

    var read_buf: [512]u8 = undefined;
    var freader = file.reader(io, &read_buf);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = undefined;
    const opened = loose.open(&freader.interface, &window, &decompress) catch {
        reportCorrupt(diag, gpa, "loose object header is corrupt");
        return error.CorruptObject;
    };
    return .{ .kind = opened.header.kind, .size = opened.header.size };
}

/// Streams the verified payload of the loose object `oid` into `w`.
/// Returns null when there is no such loose object.
///
/// The bytes read are hashed as they stream, under `oid`'s own kind and
/// size header, and the result is compared against `oid` itself once the
/// stream ends: a loose object whose contents do not hash back to its own
/// path name is `CorruptObject`, never passed upward silently.
pub fn read(gpa: Allocator, io: std.Io, dir: std.Io.Dir, format: Format, oid: Oid, w: *std.Io.Writer, diag: ?*?Diagnostic) Error!?ObjectKind {
    var buf: [Oid.max_formatted_length + 1]u8 = undefined;
    const path = objectPath(&buf, oid);
    var file = dir.openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            reportCorrupt(diag, gpa, "cannot open loose object file");
            return error.IoFailed;
        },
    };
    defer file.close(io);

    var read_buf: [8192]u8 = undefined;
    var freader = file.reader(io, &read_buf);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = undefined;
    const opened = loose.open(&freader.interface, &window, &decompress) catch {
        reportCorrupt(diag, gpa, "loose object header is corrupt");
        return error.CorruptObject;
    };

    var hasher = oid_mod.Hasher.init(format);
    // The longest header this ever writes is "commit " (the longest kind
    // name, 6 bytes, plus a space) followed by a 20 digit decimal u64 and a
    // nul: 28 bytes, well under this buffer, so `Header.write` cannot fail
    // here. `opened.header` was already parsed off a real file, not built
    // from this buffer, so re-serializing it is just re-expressing bytes
    // already known to be valid.
    var header_buf: [64]u8 = undefined;
    var header_w: std.Io.Writer = .fixed(&header_buf);
    Header.write(opened.header, &header_w) catch unreachable;
    hasher.update(header_w.buffered());

    var chunk: [8192]u8 = undefined;
    var remaining = opened.header.size;
    while (remaining != 0) {
        const want: usize = @intCast(@min(@as(u64, chunk.len), remaining));
        const n = opened.payload.readSliceShort(chunk[0..want]) catch {
            reportCorrupt(diag, gpa, "loose object payload is shorter than its declared size");
            return error.CorruptObject;
        };
        if (n == 0) {
            reportCorrupt(diag, gpa, "loose object payload is shorter than its declared size");
            return error.CorruptObject;
        }
        hasher.update(chunk[0..n]);
        w.writeAll(chunk[0..n]) catch return error.IoFailed;
        // `n` is `readSliceShort`'s own return value from a buffer sized to
        // `want`, and `want` is capped at `remaining` two lines up, so
        // `n <= remaining` always and this cannot underflow.
        remaining -= n;
    }

    var extra: [1]u8 = undefined;
    const extra_n = opened.payload.readSliceShort(&extra) catch {
        reportCorrupt(diag, gpa, "loose object payload is longer than its declared size");
        return error.CorruptObject;
    };
    if (extra_n != 0) {
        reportCorrupt(diag, gpa, "loose object payload is longer than its declared size");
        return error.CorruptObject;
    }

    const computed = hasher.final();
    if (!computed.eql(oid)) {
        reportCorrupt(diag, gpa, "loose object bytes do not hash to its path name");
        return error.CorruptObject;
    }
    return opened.header.kind;
}

/// Writes `payload` as a loose object of `kind`, through a temp file and an
/// atomic rename, and returns its id. An object that already exists at the
/// computed path is left untouched; this still returns its id.
pub fn write(gpa: Allocator, io: std.Io, dir: std.Io.Dir, format: Format, kind: ObjectKind, payload: []const u8, diag: ?*?Diagnostic) Error!Oid {
    const oid = loose.hash(format, kind, payload);
    if (try exists(dir, io, oid)) return oid;

    // `flate.Compress.init` asserts its output buffer holds more than 8
    // bytes; `Allocating.init` alone starts with a zero length buffer, so
    // this reserves a small amount up front instead.
    var aw = std.Io.Writer.Allocating.initCapacity(gpa, 256) catch return error.OutOfMemory;
    defer aw.deinit();
    // `std.Io.Writer.Error` here is only ever `WriteFailed`; an allocation
    // failure inside `Allocating` surfaces through that same generic
    // member, not as `error.OutOfMemory`, so there is nothing to
    // distinguish and everything folds into `IoFailed`.
    _ = loose.write(format, kind, payload, &aw.writer) catch return error.IoFailed;

    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const hex = oid.toHex(&hex_buf);
    dir.createDirPath(io, hex[0..2]) catch {
        reportCorrupt(diag, gpa, "cannot create the loose object's fanout directory");
        return error.IoFailed;
    };

    // A fixed name is safe here: `Odb` never issues two writes concurrently
    // against the same directory, and this file is renamed away (or
    // overwritten by the next write) before anything else could observe
    // it.
    const tmp_name = "tmp-loose-object-incoming";
    dir.writeFile(io, .{ .sub_path = tmp_name, .data = aw.writer.buffered() }) catch {
        reportCorrupt(diag, gpa, "cannot write the loose object's temp file");
        return error.IoFailed;
    };

    var final_buf: [Oid.max_formatted_length + 1]u8 = undefined;
    const final_path = objectPath(&final_buf, oid);
    dir.rename(tmp_name, dir, final_path, io) catch {
        // The temp file is left behind on this path rather than swept up
        // here: the next `write` reuses (and truncates) the same name, and
        // a second fault while already unwinding this one has nothing new
        // to report.
        reportCorrupt(diag, gpa, "cannot rename the loose object's temp file into place");
        return error.IoFailed;
    };
    return oid;
}

/// Counts every loose object whose hex id starts with `hex_prefix`, adding
/// each to `acc`. `acc` is the caller's running total across every backend
/// and every alternate, so ambiguity is judged over the whole database, not
/// this one directory.
pub fn findPrefix(io: std.Io, dir: std.Io.Dir, format: Format, hex_prefix: []const u8, acc: anytype) Error!void {
    var it = dir.iterate();
    while (it.next(io) catch return error.IoFailed) |entry| {
        if (entry.kind != .directory) continue;
        if (entry.name.len != 2) continue;
        if (!isHexPair(entry.name)) continue;
        const cmp_len = @min(entry.name.len, hex_prefix.len);
        if (!std.mem.eql(u8, entry.name[0..cmp_len], hex_prefix[0..cmp_len])) continue;

        var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
        defer sub.close(io);
        var sub_it = sub.iterate();
        while (sub_it.next(io) catch return error.IoFailed) |file_entry| {
            if (file_entry.kind != .file) continue;
            // A directory entry's name is bounded by the filesystem's own
            // name-length limit, far below `usize`'s range, so this cannot
            // overflow; the very next check rejects any `full_len` other
            // than the one exact value `hex_buf` was sized to hold.
            const full_len = 2 + file_entry.name.len;
            if (full_len != format.formattedLength()) continue;
            var hex_buf: [Oid.max_formatted_length]u8 = undefined;
            @memcpy(hex_buf[0..2], entry.name);
            @memcpy(hex_buf[2..full_len], file_entry.name);
            const hex = hex_buf[0..full_len];
            if (!std.mem.startsWith(u8, hex, hex_prefix)) continue;
            const oid = Oid.parse(format, hex) catch continue;
            acc.add(oid);
        }
    }
}

fn isHexPair(s: []const u8) bool {
    for (s) |c| {
        switch (c) {
            '0'...'9', 'a'...'f' => {},
            else => return false,
        }
    }
    return true;
}

// expected

test "write then read round trips a blob through the loose backend" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const oid = try write(gpa, io, tmp.dir, .sha1, .blob, "hello\n", null);

    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const kind = (try read(gpa, io, tmp.dir, .sha1, oid, &out, null)).?;
    try std.testing.expectEqual(ObjectKind.blob, kind);
    try std.testing.expectEqualStrings("hello\n", out.buffered());
}

test "stat reports kind and size without a payload reader ever being touched" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const oid = try write(gpa, io, tmp.dir, .sha1, .blob, "hello\n", null);
    const info = (try stat(gpa, io, tmp.dir, oid, null)).?;
    try std.testing.expectEqual(ObjectKind.blob, info.kind);
    try std.testing.expectEqual(@as(u64, 6), info.size);
}

// suspicious

test "exists reports a real fault as IoFailed, never folded into false" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const oid = Oid.zero(.sha1);
    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const hex = oid.toHex(&hex_buf);
    // A plain file sits where the object's own fanout directory needs to
    // be, so the stat this needs fails with a real fault, not
    // `error.FileNotFound`: exactly the case a caller like `Odb.write`
    // must not read as "the object is absent, writing is safe".
    try tmp.dir.writeFile(io, .{ .sub_path = hex[0..2], .data = "not a directory" });

    try std.testing.expectError(error.IoFailed, exists(tmp.dir, io, oid));
}

test "read of an absent loose object returns null, not an error" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const oid = Oid.zero(.sha1);
    var out_buf: [16]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try std.testing.expect((try read(gpa, io, tmp.dir, .sha1, oid, &out, null)) == null);
}

test "writing an object that already exists changes nothing and still returns its id" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const first = try write(gpa, io, tmp.dir, .sha1, .blob, "hello\n", null);
    const second = try write(gpa, io, tmp.dir, .sha1, .blob, "hello\n", null);
    try std.testing.expect(first.eql(second));

    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const kind = (try read(gpa, io, tmp.dir, .sha1, first, &out, null)).?;
    try std.testing.expectEqual(ObjectKind.blob, kind);
    try std.testing.expectEqualStrings("hello\n", out.buffered());
}

test "a loose object file whose contents do not hash to its path name is CorruptObject" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Write a genuine object, then overwrite its bytes with a different
    // object's compressed form: the path still names the first object's
    // id, but the bytes underneath now hash to something else entirely.
    const oid = try write(gpa, io, tmp.dir, .sha1, .blob, "hello\n", null);
    var aw = try std.Io.Writer.Allocating.initCapacity(gpa, 256);
    defer aw.deinit();
    _ = try loose.write(.sha1, .blob, "goodbye\n", &aw.writer);

    var path_buf: [Oid.max_formatted_length + 1]u8 = undefined;
    const path = objectPath(&path_buf, oid);
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = aw.writer.buffered() });

    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var diag: ?Diagnostic = null;
    try std.testing.expectError(error.CorruptObject, read(gpa, io, tmp.dir, .sha1, oid, &out, &diag));
    defer if (diag) |*d| d.deinit(gpa);
    try std.testing.expect(diag != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.?.detail.?, "hash") != null);
}

test "findPrefix finds the one loose object matching a unique prefix" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const oid = try write(gpa, io, tmp.dir, .sha1, .blob, "hello\n", null);
    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const hex = oid.toHex(&hex_buf);

    const Acc = struct {
        total: usize = 0,
        first: ?Oid = null,
        fn add(self: *@This(), found: Oid) void {
            self.total += 1;
            if (self.first == null) self.first = found;
        }
    };
    var acc: Acc = .{};
    try findPrefix(io, tmp.dir, .sha1, hex[0..8], &acc);
    try std.testing.expectEqual(@as(usize, 1), acc.total);
    try std.testing.expect(acc.first.?.eql(oid));
}
