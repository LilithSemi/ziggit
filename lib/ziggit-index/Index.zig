//! Reads and writes `.git/index`: the staged snapshot git compares a working
//! tree against. Versions 2 and 3 only; version 4's prefix-compressed path
//! names are a different parser and are refused rather than guessed at.
//!
//! Read and write operations both exist. Read alone is what a consumer needs
//! to see what a dirty working tree looks like; write operations include
//! writing an index built by staging a worktree.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;
const Hasher = oid_mod.Hasher;

const core_mod = @import("ziggit-core");
const FileMode = core_mod.FileMode;

const odb_mod = @import("ziggit-odb");
const Odb = odb_mod.Odb;

/// Which side of a conflict an entry belongs to. `merged` is the normal,
/// non-conflicted state; the other three are the base, ours, and theirs
/// copies git keeps while a conflict is unresolved.
pub const Stage = enum(u2) { merged = 0, base = 1, ours = 2, theirs = 3 };

pub const Stat = struct {
    ctime_seconds: u32,
    ctime_nanoseconds: u32,
    mtime_seconds: u32,
    mtime_nanoseconds: u32,
    dev: u32,
    ino: u32,
    uid: u32,
    gid: u32,
};

/// Builds an index stat block from what `std.Io` reports about a file.
///
/// **`dev`, `uid` and `gid` are zero, and that is a limit of `std.Io`, not
/// an oversight.** `std.Io.File.Stat` carries `inode`, `mtime`, `ctime` and
/// `size` and exposes no device id, owner or group at all. Git compares all
/// six by default (`core.checkStat`), so a zeroed trio makes its stat check
/// miss and git falls back to comparing the file's content. The answer it
/// reports stays correct; only the work is wasted, and git rewrites the
/// index with its own values the first time it writes one.
///
/// Do not "fix" this by inventing values. A wrong device id is worse than a
/// zero: zero reliably means "compare the content", while a plausible wrong
/// one can match by accident and skip a file that really did change.
pub fn statFromFile(s: std.Io.File.Stat) Stat {
    const ns_per_s = std.time.ns_per_s;
    const ctime_ns = s.ctime.nanoseconds;
    const mtime_ns = s.mtime.nanoseconds;
    const ctime_s = @divFloor(ctime_ns, ns_per_s);
    const mtime_s = @divFloor(mtime_ns, ns_per_s);
    // Git stores each of these as a 32 bit field, so a timestamp past 2106
    // wraps here exactly as it does in git's own index.
    return .{
        .ctime_seconds = @truncate(@as(u96, @bitCast(ctime_s))),
        .ctime_nanoseconds = @intCast(ctime_ns - ctime_s * ns_per_s),
        .mtime_seconds = @truncate(@as(u96, @bitCast(mtime_s))),
        .mtime_nanoseconds = @intCast(mtime_ns - mtime_s * ns_per_s),
        .dev = 0,
        .ino = @truncate(s.inode),
        .uid = 0,
        .gid = 0,
    };
}

pub const Entry = struct {
    path: []const u8, // owned
    oid: Oid,
    mode: FileMode,
    stage: Stage,
    size: u32,
    stat: Stat,

    pub fn deinit(e: *Entry, gpa: Allocator) void {
        gpa.free(e.path);
        e.* = undefined;
    }
};

pub const Error = error{ IndexNotFound, IoFailed, CorruptIndex, UnsupportedIndexVersion } || Allocator.Error || Odb.Error;

/// A reader fails when trying to read bytes. Running out of bytes means the
/// file is short, which for a format carrying its own lengths is corruption.
/// A stream exceeding its expected bounds is also corruption. A failed read
/// means the storage underneath gave way, and says nothing about the bytes.
/// This handles read, take, and discard operations.
fn mapRead(err: error{ EndOfStream, ReadFailed, Canceled, AccessDenied, Unexpected, StreamTooLong }) Error {
    return switch (err) {
        error.EndOfStream => error.CorruptIndex,
        error.ReadFailed => error.IoFailed,
        error.Canceled => error.IoFailed,
        error.AccessDenied => error.IoFailed,
        error.Unexpected => error.IoFailed,
        error.StreamTooLong => error.CorruptIndex,
    };
}

/// A seek operation failed. Running out of bytes while seeking means the
/// file is shorter than expected, which is corruption. A failed seek means
/// storage fault.
fn mapSeek(err: error{ AccessDenied, Canceled, EndOfStream, ReadFailed, Unexpected, Unseekable }) Error {
    return switch (err) {
        error.EndOfStream => error.CorruptIndex,
        error.ReadFailed => error.IoFailed,
        error.AccessDenied => error.IoFailed,
        error.Canceled => error.IoFailed,
        error.Unexpected => error.IoFailed,
        error.Unseekable => error.IoFailed,
    };
}

/// A size query failed. These cannot produce EndOfStream, so any error means
/// storage fault.
fn mapSize(err: error{ AccessDenied, Canceled, PermissionDenied, Streaming, SystemResources, Unexpected }) Error {
    return switch (err) {
        error.AccessDenied => error.IoFailed,
        error.Canceled => error.IoFailed,
        error.PermissionDenied => error.IoFailed,
        error.Streaming => error.IoFailed,
        error.SystemResources => error.IoFailed,
        error.Unexpected => error.IoFailed,
    };
}

pub const Index = struct {
    gpa: Allocator,
    entries: []const Entry, // owned

    const signature = "DIRC";
    const min_version = 2;
    const max_version = 3;

    // Flags field layout (git's `ce_flags`): bit 14 says an extended flags
    // field follows (version 3 only), bits 12-13 hold the stage, and the
    // low 12 bits hold the name length, with 0xfff meaning "longer than
    // this field can hold, read to the NUL instead".
    const extended_flag_bit: u16 = 0x4000;
    const stage_mask: u16 = 0x3000;
    const stage_shift: u4 = 12;
    const name_len_mask: u16 = 0x0fff;
    const name_len_overflow: u16 = 0x0fff;

    /// Reads `.git/index`. Versions 2 and 3 only; 4's path compression is not
    /// implemented and is refused rather than guessed at.
    ///
    /// Returns IndexNotFound if the index file does not exist. This is normal
    /// for a brand new repository where nothing has been staged yet, not a
    /// fault. Returns IoFailed for permission denied or other I/O faults.
    /// Returns CorruptIndex only if the file exists and its bytes are malformed.
    pub fn open(gpa: Allocator, io: std.Io, git_dir: std.Io.Dir, f: Format) Error!Index {
        var file = git_dir.openFile(io, "index", .{}) catch |err| {
            return switch (err) {
                error.FileNotFound => error.IndexNotFound,
                error.AccessDenied,
                error.AntivirusInterference,
                error.BadPathName,
                error.Canceled,
                error.DeviceBusy,
                error.FileBusy,
                error.FileLocksUnsupported,
                error.FileTooBig,
                error.IsDir,
                error.NameTooLong,
                error.NetworkNotFound,
                error.NoDevice,
                error.NoSpaceLeft,
                error.NotDir,
                error.PathAlreadyExists,
                error.PermissionDenied,
                error.PipeBusy,
                error.ProcessFdQuotaExceeded,
                error.ReadOnlyFileSystem,
                error.SymLinkLoop,
                error.SystemFdQuotaExceeded,
                error.SystemResources,
                error.Unexpected,
                error.WouldBlock,
                => error.IoFailed,
            };
        };
        defer file.close(io);

        var read_buffer: [8192]u8 = undefined;
        var reader = file.reader(io, &read_buffer);
        reader.seekTo(0) catch |e| return mapSeek(e);
        const r = &reader.interface;

        const got_sig = r.take(4) catch |e| return mapRead(e);
        if (!std.mem.eql(u8, got_sig, signature)) return error.CorruptIndex;
        const version = r.takeInt(u32, .big) catch |e| return mapRead(e);
        if (version != min_version and version != max_version) return error.UnsupportedIndexVersion;
        const raw_count = r.takeInt(u32, .big) catch |e| return mapRead(e);

        // `raw_count` is whatever the file claims; nothing above this point
        // checks it against how many bytes the file actually has left. A
        // tiny hostile file can claim a count in the billions and drive an
        // allocation loop the real file could never back. The smallest a
        // genuine entry can ever be is its fixed 40-byte stat block, one
        // object id, a 2-byte flags field, and at least one byte of name
        // (the terminating NUL alone does not make a valid empty path);
        // reject before allocating anything sized by `raw_count` when the
        // file is too short to hold even that many minimal entries.
        const oid_len = f.byteLength();
        const size = reader.getSize() catch |e| return mapSize(e);
        const pos = reader.logicalPos();
        const remaining = std.math.sub(u64, size, pos) catch return error.CorruptIndex;

        const min_entry_len: u64 = 40 + oid_len + 2 + 1;
        const count64: u64 = raw_count;
        const min_needed = std.math.mul(u64, count64, min_entry_len) catch return error.CorruptIndex;
        if (remaining < min_needed) return error.CorruptIndex;

        const count = std.math.cast(usize, raw_count) orelse return error.CorruptIndex;

        var list: std.ArrayList(Entry) = .empty;
        errdefer {
            for (list.items) |*e| e.deinit(gpa);
            list.deinit(gpa);
        }

        var i: usize = 0;
        while (i < count) : (i += 1) {
            var entry = try readEntry(gpa, r, f, version);
            errdefer entry.deinit(gpa);
            try list.append(gpa, entry);
        }

        try skipExtensionsAndChecksum(r, &reader, oid_len);

        return .{ .gpa = gpa, .entries = try list.toOwnedSlice(gpa) };
    }

    pub fn deinit(i: *Index) void {
        for (i.entries) |e| i.gpa.free(e.path);
        i.gpa.free(i.entries);
        i.* = undefined;
    }

    pub fn find(i: Index, path: []const u8) ?Entry {
        for (i.entries) |e| {
            if (std.mem.eql(u8, e.path, path)) return e;
        }
        return null;
    }
};

/// Reads one entry: the fixed stat block, the object id, the flags (and,
/// for a version 3 index with the extended bit set, the extra flags field),
/// then the NUL-terminated path and its padding out to the next multiple of
/// eight bytes.
fn readEntry(gpa: Allocator, r: *std.Io.Reader, f: Format, version: u32) Error!Entry {
    // `consumed` tracks bytes read since the start of this entry, so the
    // trailing padding can be computed exactly regardless of which name
    // path (direct length or NUL-scan) was taken.
    var consumed: u64 = 0;

    // ctime (seconds, nanoseconds), mtime (seconds, nanoseconds).
    const ctime_seconds = r.takeInt(u32, .big) catch |e| return mapRead(e);
    consumed += 4;
    const ctime_nanoseconds = r.takeInt(u32, .big) catch |e| return mapRead(e);
    consumed += 4;
    const mtime_seconds = r.takeInt(u32, .big) catch |e| return mapRead(e);
    consumed += 4;
    const mtime_nanoseconds = r.takeInt(u32, .big) catch |e| return mapRead(e);
    consumed += 4;

    // dev, ino.
    const dev = r.takeInt(u32, .big) catch |e| return mapRead(e);
    consumed += 4;
    const ino = r.takeInt(u32, .big) catch |e| return mapRead(e);
    consumed += 4;

    const mode_raw = r.takeInt(u32, .big) catch |e| return mapRead(e);
    consumed += 4;

    // uid, gid.
    const uid = r.takeInt(u32, .big) catch |e| return mapRead(e);
    consumed += 4;
    const gid = r.takeInt(u32, .big) catch |e| return mapRead(e);
    consumed += 4;

    const size = r.takeInt(u32, .big) catch |e| return mapRead(e);
    consumed += 4;

    const mode = FileMode.fromOctal(mode_raw) orelse return error.CorruptIndex;

    const oid_len = f.byteLength();
    const oid_bytes = r.take(oid_len) catch |e| return mapRead(e);
    const oid = Oid.fromBytes(f, oid_bytes);
    consumed += oid_len;

    const flags = r.takeInt(u16, .big) catch |e| return mapRead(e);
    consumed += 2;

    const extended = flags & Index.extended_flag_bit != 0;
    // The extended flags field is a version 3 feature. A version 2 index
    // setting this bit is not a shape this format defines; reading it
    // anyway would silently misalign the rest of the entry.
    if (extended and version != Index.max_version) return error.CorruptIndex;
    if (extended) {
        _ = r.takeInt(u16, .big) catch |e| return mapRead(e); // extended flags, not used
        consumed += 2;
    }

    const stage_bits: u2 = @intCast((flags & Index.stage_mask) >> Index.stage_shift);
    const stage: Stage = @enumFromInt(stage_bits);

    const declared_len = flags & Index.name_len_mask;
    var path: []u8 = undefined;
    if (declared_len == Index.name_len_overflow) {
        // The 12-bit field cannot hold a path this long; the real length is
        // found by scanning for the terminating NUL instead.
        const name = r.takeSentinel(0) catch |e| return mapRead(e);
        path = try gpa.dupe(u8, name);
        consumed += @as(u64, name.len) + 1;
    } else {
        // `take` borrows the reader's own buffer; copy it out before any
        // further read can invalidate it.
        const name = r.take(declared_len) catch |e| return mapRead(e);
        path = try gpa.dupe(u8, name);
        consumed += @as(u64, declared_len) + 1;
    }
    errdefer gpa.free(path);

    if (declared_len != Index.name_len_overflow) {
        _ = r.takeByte() catch |e| return mapRead(e); // terminating NUL
    }

    const padded = std.mem.alignForward(u64, consumed, 8);
    const pad = padded - consumed;
    if (pad > 0) {
        const pad_len = std.math.cast(usize, pad) orelse return error.CorruptIndex;
        r.discardAll(pad_len) catch |e| return mapRead(e);
    }

    return .{
        .path = path,
        .oid = oid,
        .mode = mode,
        .stage = stage,
        .size = size,
        .stat = .{
            .ctime_seconds = ctime_seconds,
            .ctime_nanoseconds = ctime_nanoseconds,
            .mtime_seconds = mtime_seconds,
            .mtime_nanoseconds = mtime_nanoseconds,
            .dev = dev,
            .ino = ino,
            .uid = uid,
            .gid = gid,
        },
    };
}

/// Consumes whatever comes after the entry table: zero or more extensions,
/// each a 4 byte signature and a 4 byte length this module does not need to
/// understand, followed by the trailing checksum. An extension whose
/// declared length would run past where the checksum has to start is
/// truncated, not merely unfamiliar, and is reported as corrupt rather than
/// silently accepted.
fn skipExtensionsAndChecksum(r: *std.Io.Reader, reader: *std.Io.File.Reader, checksum_len: usize) Error!void {
    const checksum_len64: u64 = checksum_len;
    while (true) {
        const size = reader.getSize() catch |e| return mapSize(e);
        const pos = reader.logicalPos();
        const remaining = std.math.sub(u64, size, pos) catch return error.CorruptIndex;
        if (remaining == checksum_len64) break;
        if (remaining < 8 + checksum_len64) return error.CorruptIndex;

        _ = r.take(4) catch |e| return mapRead(e); // extension signature, not used
        const ext_len: u64 = r.takeInt(u32, .big) catch |e| return mapRead(e);
        const remaining_after_header = remaining - 8;
        if (ext_len > remaining_after_header - checksum_len64) return error.CorruptIndex;
        r.discardAll64(ext_len) catch |e| return mapRead(e);
    }

    _ = r.take(checksum_len) catch |e| return mapRead(e);
    if (r.takeByte()) |_| {
        return error.CorruptIndex; // bytes remain past the trailing checksum
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.ReadFailed => return error.IoFailed,
    }
}

// Byte-exact vectors captured from real git 2.55.0, in a scratch repository,
// with `od -An -tx1 -v .git/index`:
//
//   git init, then `git add` three files (a regular file "alpha.txt", an
//   executable "run.sh", and a symlink "link.txt") produces `vector_v2`.
//   `git update-index --index-version 3 && git update-index --skip-worktree
//   alpha.txt` on the same repository turns the first entry's flags
//   extended and produces `vector_v3`.
//   A merge left unresolved (`git merge` with a real conflict in "f.txt")
//   produces `vector_conflict`: three stage entries for the one path,
//   followed by a real "TREE" extension git itself writes.
//
// Decoded by hand once, then pinned in the assertions below so a future
// regression shows up as a specific wrong field, not just "test failed".

const vector_v2 = [_]u8{
    0x44, 0x49, 0x52, 0x43, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x03, 0x6a, 0xab, 0x2c, 0x96,
    0x3b, 0x7f, 0xa4, 0x35, 0x6a, 0xab, 0x2c, 0x96, 0x3b, 0x7f, 0xa4, 0x35, 0x00, 0x00, 0x00, 0x22,
    0x00, 0x27, 0x1c, 0x0b, 0x00, 0x00, 0x81, 0xa4, 0x00, 0x00, 0x03, 0xe8, 0x00, 0x00, 0x00, 0x64,
    0x00, 0x00, 0x00, 0x06, 0xce, 0x01, 0x36, 0x25, 0x03, 0x0b, 0xa8, 0xdb, 0xa9, 0x06, 0xf7, 0x56,
    0x96, 0x7f, 0x9e, 0x9c, 0xa3, 0x94, 0x46, 0x4a, 0x00, 0x09, 0x61, 0x6c, 0x70, 0x68, 0x61, 0x2e,
    0x74, 0x78, 0x74, 0x00, 0x6a, 0xab, 0x2c, 0x97, 0x01, 0x16, 0x08, 0x7e, 0x6a, 0xab, 0x2c, 0x97,
    0x01, 0x16, 0x08, 0x7e, 0x00, 0x00, 0x00, 0x22, 0x00, 0x27, 0x0a, 0x63, 0x00, 0x00, 0xa0, 0x00,
    0x00, 0x00, 0x03, 0xe8, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x09, 0x93, 0xae, 0x52, 0x11,
    0x8a, 0xb9, 0x36, 0x50, 0x10, 0x72, 0x21, 0xaf, 0x96, 0x0c, 0x68, 0xa6, 0x13, 0x96, 0x61, 0x1c,
    0x00, 0x08, 0x6c, 0x69, 0x6e, 0x6b, 0x2e, 0x74, 0x78, 0x74, 0x00, 0x00, 0x6a, 0xab, 0x2c, 0x96,
    0x3b, 0x7f, 0xa4, 0x35, 0x6a, 0xab, 0x2c, 0x96, 0x3b, 0x7f, 0xa4, 0x35, 0x00, 0x00, 0x00, 0x22,
    0x00, 0x27, 0x1c, 0x0c, 0x00, 0x00, 0x81, 0xed, 0x00, 0x00, 0x03, 0xe8, 0x00, 0x00, 0x00, 0x64,
    0x00, 0x00, 0x00, 0x12, 0x41, 0x63, 0x03, 0x6e, 0xfa, 0x65, 0xbd, 0x4a, 0x46, 0x9e, 0x75, 0x22,
    0x67, 0x49, 0x8f, 0x01, 0xea, 0x36, 0xa5, 0x5c, 0x00, 0x06, 0x72, 0x75, 0x6e, 0x2e, 0x73, 0x68,
    0x00, 0x00, 0x00, 0x00, 0x6a, 0x38, 0xd2, 0x12, 0xc9, 0xff, 0x92, 0xd4, 0x4f, 0xa1, 0xb3, 0x61,
    0x45, 0x44, 0x02, 0x81, 0x60, 0x7b, 0x46, 0x10,
};

const vector_v3 = [_]u8{
    0x44, 0x49, 0x52, 0x43, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x03, 0x6a, 0xab, 0x2c, 0x96,
    0x3b, 0x7f, 0xa4, 0x35, 0x6a, 0xab, 0x2c, 0x96, 0x3b, 0x7f, 0xa4, 0x35, 0x00, 0x00, 0x00, 0x22,
    0x00, 0x27, 0x1c, 0x0b, 0x00, 0x00, 0x81, 0xa4, 0x00, 0x00, 0x03, 0xe8, 0x00, 0x00, 0x00, 0x64,
    0x00, 0x00, 0x00, 0x06, 0xce, 0x01, 0x36, 0x25, 0x03, 0x0b, 0xa8, 0xdb, 0xa9, 0x06, 0xf7, 0x56,
    0x96, 0x7f, 0x9e, 0x9c, 0xa3, 0x94, 0x46, 0x4a, 0x40, 0x09, 0x40, 0x00, 0x61, 0x6c, 0x70, 0x68,
    0x61, 0x2e, 0x74, 0x78, 0x74, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x6a, 0xab, 0x2c, 0x97,
    0x01, 0x16, 0x08, 0x7e, 0x6a, 0xab, 0x2c, 0x97, 0x01, 0x16, 0x08, 0x7e, 0x00, 0x00, 0x00, 0x22,
    0x00, 0x27, 0x0a, 0x63, 0x00, 0x00, 0xa0, 0x00, 0x00, 0x00, 0x03, 0xe8, 0x00, 0x00, 0x00, 0x64,
    0x00, 0x00, 0x00, 0x09, 0x93, 0xae, 0x52, 0x11, 0x8a, 0xb9, 0x36, 0x50, 0x10, 0x72, 0x21, 0xaf,
    0x96, 0x0c, 0x68, 0xa6, 0x13, 0x96, 0x61, 0x1c, 0x00, 0x08, 0x6c, 0x69, 0x6e, 0x6b, 0x2e, 0x74,
    0x78, 0x74, 0x00, 0x00, 0x6a, 0xab, 0x2c, 0x96, 0x3b, 0x7f, 0xa4, 0x35, 0x6a, 0xab, 0x2c, 0x96,
    0x3b, 0x7f, 0xa4, 0x35, 0x00, 0x00, 0x00, 0x22, 0x00, 0x27, 0x1c, 0x0c, 0x00, 0x00, 0x81, 0xed,
    0x00, 0x00, 0x03, 0xe8, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x12, 0x41, 0x63, 0x03, 0x6e,
    0xfa, 0x65, 0xbd, 0x4a, 0x46, 0x9e, 0x75, 0x22, 0x67, 0x49, 0x8f, 0x01, 0xea, 0x36, 0xa5, 0x5c,
    0x00, 0x06, 0x72, 0x75, 0x6e, 0x2e, 0x73, 0x68, 0x00, 0x00, 0x00, 0x00, 0x3f, 0xa5, 0x0f, 0xaf,
    0x7d, 0x83, 0x81, 0x01, 0xaf, 0x45, 0xc8, 0x68, 0xc6, 0x50, 0x41, 0x27, 0xb0, 0x7a, 0x43, 0x7d,
};

const vector_conflict = [_]u8{
    0x44, 0x49, 0x52, 0x43, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x81, 0xa4, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0xdf, 0x96, 0x7b, 0x96, 0xa5, 0x79, 0xe4, 0x5a, 0x18, 0xb8, 0x25, 0x17,
    0x32, 0xd1, 0x68, 0x04, 0xb2, 0xe5, 0x6a, 0x55, 0x10, 0x05, 0x66, 0x2e, 0x74, 0x78, 0x74, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x81, 0xa4,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x06, 0x5e, 0x9d, 0x1c,
    0x71, 0xaa, 0x49, 0x2e, 0x95, 0x88, 0xac, 0x90, 0x6f, 0xf8, 0x4e, 0x1b, 0x55, 0x2a, 0xa3, 0x88,
    0x20, 0x05, 0x66, 0x2e, 0x74, 0x78, 0x74, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x81, 0xa4, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x86, 0x47, 0xc5, 0xd0, 0x26, 0x8e, 0xab, 0xfb, 0xfb, 0x6b, 0xc6, 0x5b,
    0x30, 0x67, 0x85, 0x70, 0xc2, 0xdf, 0x45, 0x83, 0x30, 0x05, 0x66, 0x2e, 0x74, 0x78, 0x74, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x54, 0x52, 0x45, 0x45, 0x00, 0x00, 0x00, 0x06, 0x00, 0x2d, 0x31, 0x20,
    0x30, 0x0a, 0x4b, 0x80, 0x63, 0xba, 0x99, 0xb9, 0xb8, 0xd8, 0xf9, 0x07, 0xdb, 0xd6, 0x0a, 0xda,
    0x9c, 0x6b, 0x65, 0x98, 0x7c, 0x80,
};

fn openFromBytes(gpa: Allocator, tmp_dir: std.Io.Dir, io: std.Io, bytes: []const u8) Error!Index {
    tmp_dir.writeFile(io, .{ .sub_path = "index", .data = bytes }) catch return error.IoFailed;
    return Index.open(gpa, io, tmp_dir, .sha1);
}

// expected

test "open reads the entry count from the header" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var idx = try openFromBytes(gpa, tmp.dir, io, &vector_v2);
    defer idx.deinit();

    try std.testing.expectEqual(@as(usize, 3), idx.entries.len);
}

test "open reads a path, oid, mode and size for each entry" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var idx = try openFromBytes(gpa, tmp.dir, io, &vector_v2);
    defer idx.deinit();

    const alpha = idx.entries[0];
    try std.testing.expectEqualStrings("alpha.txt", alpha.path);
    try std.testing.expectEqual(FileMode.blob, alpha.mode);
    try std.testing.expectEqual(@as(u32, 6), alpha.size);
    try std.testing.expect(alpha.oid.eql(Oid.fromBytes(.sha1, &[_]u8{
        0xce, 0x01, 0x36, 0x25, 0x03, 0x0b, 0xa8, 0xdb, 0xa9, 0x06,
        0xf7, 0x56, 0x96, 0x7f, 0x9e, 0x9c, 0xa3, 0x94, 0x46, 0x4a,
    })));

    const link = idx.entries[1];
    try std.testing.expectEqualStrings("link.txt", link.path);
    try std.testing.expectEqual(FileMode.symlink, link.mode);
    try std.testing.expectEqual(@as(u32, 9), link.size);

    const run = idx.entries[2];
    try std.testing.expectEqualStrings("run.sh", run.path);
    try std.testing.expectEqual(FileMode.blob_executable, run.mode);
    try std.testing.expectEqual(@as(u32, 18), run.size);
    try std.testing.expect(run.oid.eql(Oid.fromBytes(.sha1, &[_]u8{
        0x41, 0x63, 0x03, 0x6e, 0xfa, 0x65, 0xbd, 0x4a, 0x46, 0x9e,
        0x75, 0x22, 0x67, 0x49, 0x8f, 0x01, 0xea, 0x36, 0xa5, 0x5c,
    })));
}

test "find returns the entry for a path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var idx = try openFromBytes(gpa, tmp.dir, io, &vector_v2);
    defer idx.deinit();

    const found = idx.find("run.sh") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FileMode.blob_executable, found.mode);
    try std.testing.expectEqual(@as(u32, 18), found.size);
}

test "open reads a version 3 index" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `alpha.txt`, the first entry, carries the extended flag (its
    // skip-worktree bit is set); `link.txt` and `run.sh` follow it without
    // one. A parser that mishandles the extended field on the first entry
    // misaligns every entry after it, so this pins all three.
    var idx = try openFromBytes(gpa, tmp.dir, io, &vector_v3);
    defer idx.deinit();

    try std.testing.expectEqual(@as(usize, 3), idx.entries.len);

    const alpha = idx.entries[0];
    try std.testing.expectEqualStrings("alpha.txt", alpha.path);
    try std.testing.expectEqual(FileMode.blob, alpha.mode);
    try std.testing.expectEqual(@as(u32, 6), alpha.size);
    try std.testing.expectEqual(Stage.merged, alpha.stage);

    const link = idx.entries[1];
    try std.testing.expectEqualStrings("link.txt", link.path);
    try std.testing.expectEqual(FileMode.symlink, link.mode);
    try std.testing.expectEqual(@as(u32, 9), link.size);

    const run = idx.entries[2];
    try std.testing.expectEqualStrings("run.sh", run.path);
    try std.testing.expectEqual(FileMode.blob_executable, run.mode);
    try std.testing.expectEqual(@as(u32, 18), run.size);
    try std.testing.expect(run.oid.eql(Oid.fromBytes(.sha1, &[_]u8{
        0x41, 0x63, 0x03, 0x6e, 0xfa, 0x65, 0xbd, 0x4a, 0x46, 0x9e,
        0x75, 0x22, 0x67, 0x49, 0x8f, 0x01, 0xea, 0x36, 0xa5, 0x5c,
    })));
}

// suspicious

test "open refuses a version 4 index rather than misreading it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [8]u8 = undefined;
    @memcpy(buf[0..4], Index.signature);
    std.mem.writeInt(u32, buf[4..8], 4, .big);
    try tmp.dir.writeFile(io, .{ .sub_path = "index", .data = &buf });

    try std.testing.expectError(error.UnsupportedIndexVersion, Index.open(gpa, io, tmp.dir, .sha1));
}

test "open rejects a signature that is not DIRC" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [8]u8 = undefined;
    @memcpy(buf[0..4], "XXXX");
    std.mem.writeInt(u32, buf[4..8], 2, .big);
    try tmp.dir.writeFile(io, .{ .sub_path = "index", .data = &buf });

    try std.testing.expectError(error.CorruptIndex, Index.open(gpa, io, tmp.dir, .sha1));
}

test "open rejects an entry count larger than the file can hold" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Billions of entries, claimed by a header with nothing behind it: the
    // stat blocks, ids, and flags this many entries would need cannot
    // possibly fit in a file this short.
    var buf: [12]u8 = undefined;
    @memcpy(buf[0..4], Index.signature);
    std.mem.writeInt(u32, buf[4..8], 2, .big);
    std.mem.writeInt(u32, buf[8..12], 0xffff_fff0, .big);
    try tmp.dir.writeFile(io, .{ .sub_path = "index", .data = &buf });

    // This must fail on the bounds check, not attempt an allocation sized
    // by the claimed count: a leak-detecting allocator failing here would
    // also mean the huge allocation was attempted.
    try std.testing.expectError(error.CorruptIndex, Index.open(gpa, io, tmp.dir, .sha1));
}

test "open rejects a path length that runs past the end of the file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // One entry, correctly formed up through its flags field, declaring a
    // 100 byte name. Only 10 bytes of anything follow, and none of them is
    // the NUL this name would need: the file ends inside the path.
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(Index.signature);
    try w.writeInt(u32, 2, .big); // version
    try w.writeInt(u32, 1, .big); // entry count

    try w.writeInt(u32, 0, .big); // ctime sec
    try w.writeInt(u32, 0, .big); // ctime nsec
    try w.writeInt(u32, 0, .big); // mtime sec
    try w.writeInt(u32, 0, .big); // mtime nsec
    try w.writeInt(u32, 0, .big); // dev
    try w.writeInt(u32, 0, .big); // ino
    try w.writeInt(u32, 0o100644, .big); // mode
    try w.writeInt(u32, 0, .big); // uid
    try w.writeInt(u32, 0, .big); // gid
    try w.writeInt(u32, 0, .big); // size
    try w.writeAll(&([_]u8{0x11} ** 20)); // oid
    try w.writeInt(u16, 100, .big); // flags: name length 100, stage 0
    try w.writeAll("abcdefghij"); // 10 bytes, nowhere near 100, no NUL

    const bytes = try aw.toOwnedSlice();
    defer gpa.free(bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "index", .data = bytes });

    try std.testing.expectError(error.CorruptIndex, Index.open(gpa, io, tmp.dir, .sha1));
}

test "entries at a stage other than merged are readable and keep their stage" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A real unresolved merge conflict: three stage entries for "f.txt",
    // followed by a genuine "TREE" extension git itself wrote. Reading
    // this all the way to the trailing checksum, without erroring on the
    // extension, is part of what this test pins.
    var idx = try openFromBytes(gpa, tmp.dir, io, &vector_conflict);
    defer idx.deinit();

    try std.testing.expectEqual(@as(usize, 3), idx.entries.len);

    try std.testing.expectEqualStrings("f.txt", idx.entries[0].path);
    try std.testing.expectEqual(Stage.base, idx.entries[0].stage);
    try std.testing.expectEqualStrings("f.txt", idx.entries[1].path);
    try std.testing.expectEqual(Stage.ours, idx.entries[1].stage);
    try std.testing.expectEqualStrings("f.txt", idx.entries[2].path);
    try std.testing.expectEqual(Stage.theirs, idx.entries[2].stage);

    try std.testing.expect(idx.entries[0].oid.eql(Oid.fromBytes(.sha1, &[_]u8{
        0xdf, 0x96, 0x7b, 0x96, 0xa5, 0x79, 0xe4, 0x5a, 0x18, 0xb8,
        0x25, 0x17, 0x32, 0xd1, 0x68, 0x04, 0xb2, 0xe5, 0x6a, 0x55,
    })));
    try std.testing.expect(idx.entries[1].oid.eql(Oid.fromBytes(.sha1, &[_]u8{
        0x06, 0x5e, 0x9d, 0x1c, 0x71, 0xaa, 0x49, 0x2e, 0x95, 0x88,
        0xac, 0x90, 0x6f, 0xf8, 0x4e, 0x1b, 0x55, 0x2a, 0xa3, 0x88,
    })));
    try std.testing.expect(idx.entries[2].oid.eql(Oid.fromBytes(.sha1, &[_]u8{
        0x86, 0x47, 0xc5, 0xd0, 0x26, 0x8e, 0xab, 0xfb, 0xfb, 0x6b,
        0xc6, 0x5b, 0x30, 0x67, 0x85, 0x70, 0xc2, 0xdf, 0x45, 0x83,
    })));
}

test "find returns null for a path not in the index" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var idx = try openFromBytes(gpa, tmp.dir, io, &vector_v2);
    defer idx.deinit();

    try std.testing.expectEqual(@as(?Entry, null), idx.find("nowhere.txt"));
}

test "open reports a missing index file as IndexNotFound, not corruption" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(error.IndexNotFound, Index.open(gpa, io, tmp.dir, .sha1));
}

test "open reports genuinely malformed bytes as CorruptIndex" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var buf: [8]u8 = undefined;
    @memcpy(buf[0..4], "XXXX");
    std.mem.writeInt(u32, buf[4..8], 2, .big);
    try tmp.dir.writeFile(io, .{ .sub_path = "index", .data = &buf });

    try std.testing.expectError(error.CorruptIndex, Index.open(gpa, io, tmp.dir, .sha1));
}

test "a truncated index is CorruptIndex" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write a truncated index: valid header but missing entries and checksum.
    // When the parser tries to read the first entry's 16-byte stat block,
    // it hits EOF, producing error.EndOfStream from the reader, which
    // mapRead reports as CorruptIndex.
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(Index.signature);
    try w.writeInt(u32, 2, .big); // version
    try w.writeInt(u32, 1, .big); // entry count: claims 1, provides 0

    const bytes = try aw.toOwnedSlice();
    defer gpa.free(bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "index", .data = bytes });

    const result = Index.open(gpa, io, tmp.dir, .sha1);
    try std.testing.expectError(error.CorruptIndex, result);
}

/// Always fails a positional read with `error.InputOutput`, standing in for
/// a storage fault. Every other operation is left pointing at the real
/// `std.testing.io` implementation, so opening the file and stat-ing it
/// still work; only the read itself gives way.
fn readPositionalAlwaysFails(
    userdata: ?*anyopaque,
    file: std.Io.File,
    data: []const []u8,
    offset: u64,
) std.Io.File.ReadPositionalError!usize {
    _ = userdata;
    _ = file;
    _ = data;
    _ = offset;
    return error.InputOutput;
}

test "a genuine read fault is IoFailed, not CorruptIndex" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // `vector_v2` is a byte-exact, well-formed index; nothing about its
    // contents is wrong. It is written with the real `io` so the write
    // itself cannot be the thing that fails.
    try tmp.dir.writeFile(io, .{ .sub_path = "index", .data = &vector_v2 });

    // A second `std.Io`, identical to the real one except that every
    // positional read fails. Opening and stat-ing the file still go
    // through the real implementation; only the read the parser depends on
    // gives way, so a failure here can only be the injected storage fault.
    var table: std.Io.VTable = io.vtable.*;
    table.fileReadPositional = readPositionalAlwaysFails;
    const failing_io: std.Io = .{ .userdata = io.userdata, .vtable = &table };

    const result = Index.open(gpa, failing_io, tmp.dir, .sha1);
    try std.testing.expectError(error.IoFailed, result);
}

test "an index entry keeps the stat block the file holds" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const hex_str = "4449524300000002000000036aad5ec90d7d910b6aad5ec90d7d910b00000022000c6585000081a4000003e80000006400000006ce013625030ba8dba906f756967f9e9ca394464a0005612e74787400000000006aad5ec90d7d910b6aad5ec90d7d910b00000022000c678c000081a4000003e8000000640000000779c53955ef856f16f2107446bc721c8879a1bd2e0007642f622e7478740000006aad5ec90e1628156aad5ec90d7d910b00000022000c678f000081ed000003e8000000640000000a1a2485251c33a70432394c93fb89330ef214bfc9000672756e2e7368000000005452454500000033003320310adc388fc74b7ae653cebc33b4d91de4fc84b1339464003120300abd6bc799012984c0083beb6c9448d3ea68c214cf0a49b6e8159a806c61df2a7bd4bdddabf6e61c8f";
    var bytes: [307]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex_str);

    var idx = try openFromBytes(gpa, tmp.dir, io, &bytes);
    defer idx.deinit();

    const atxt = idx.entries[0];
    try std.testing.expectEqual(@as(u32, 0x6aad5ec9), atxt.stat.ctime_seconds);
    try std.testing.expectEqual(@as(u32, 0x0d7d910b), atxt.stat.ctime_nanoseconds);
    try std.testing.expectEqual(@as(u32, 0x6aad5ec9), atxt.stat.mtime_seconds);
    try std.testing.expectEqual(@as(u32, 0x0d7d910b), atxt.stat.mtime_nanoseconds);
    try std.testing.expectEqual(@as(u32, 34), atxt.stat.dev);
    try std.testing.expectEqual(@as(u32, 812421), atxt.stat.ino);
    try std.testing.expectEqual(@as(u32, 1000), atxt.stat.uid);
    try std.testing.expectEqual(@as(u32, 100), atxt.stat.gid);

    const runsh = idx.entries[2];
    try std.testing.expectEqual(@as(u32, 0x6aad5ec9), runsh.stat.ctime_seconds);
    try std.testing.expectEqual(@as(u32, 0x0e162815), runsh.stat.ctime_nanoseconds);
    try std.testing.expectEqual(@as(u32, 0x6aad5ec9), runsh.stat.mtime_seconds);
    try std.testing.expectEqual(@as(u32, 0x0d7d910b), runsh.stat.mtime_nanoseconds);
    try std.testing.expectEqual(@as(u32, 34), runsh.stat.dev);
    try std.testing.expectEqual(@as(u32, 812943), runsh.stat.ino);
    try std.testing.expectEqual(@as(u32, 1000), runsh.stat.uid);
    try std.testing.expectEqual(@as(u32, 100), runsh.stat.gid);
}

test "reading an index still reports the right path, mode, size and oid" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var idx = try openFromBytes(gpa, tmp.dir, io, &vector_v2);
    defer idx.deinit();

    const atxt = idx.entries[0];
    try std.testing.expectEqualStrings("alpha.txt", atxt.path);
    try std.testing.expectEqual(FileMode.blob, atxt.mode);
    try std.testing.expectEqual(@as(u32, 6), atxt.size);

    const runsh = idx.entries[2];
    try std.testing.expectEqualStrings("run.sh", runsh.path);
    try std.testing.expectEqual(FileMode.blob_executable, runsh.mode);
    try std.testing.expectEqual(@as(u32, 18), runsh.size);
}

// Index writer

/// Writes an index to `.git/index` via a lock file. Version 2 only. Entries
/// are sorted by path bytes with stage as tiebreaker. Extended flag bits
/// are never set on v2 entries. No extensions are written. A Format decides
/// the object id length and the trailing checksum.
pub fn write(i: Index, io: std.Io, git_dir: std.Io.Dir, f: Format) Error!void {
    var aw: std.Io.Writer.Allocating = .init(i.gpa);
    defer aw.deinit();
    const w = &aw.writer;

    w.writeAll(Index.signature) catch return error.IoFailed;
    w.writeInt(u32, 2, .big) catch return error.IoFailed; // version 2 only
    w.writeInt(u32, @intCast(i.entries.len), .big) catch return error.IoFailed;

    // Sort entries by path, then by stage.
    const sorted = try i.gpa.dupe(Entry, i.entries);
    defer i.gpa.free(sorted);
    std.mem.sort(Entry, sorted, {}, struct {
        fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
            const cmp = std.mem.order(u8, lhs.path, rhs.path);
            if (cmp == .eq) {
                return @intFromEnum(lhs.stage) < @intFromEnum(rhs.stage);
            }
            return cmp == .lt;
        }
    }.lessThan);

    // Write each entry.
    for (sorted) |entry| {
        w.writeInt(u32, entry.stat.ctime_seconds, .big) catch return error.IoFailed;
        w.writeInt(u32, entry.stat.ctime_nanoseconds, .big) catch return error.IoFailed;
        w.writeInt(u32, entry.stat.mtime_seconds, .big) catch return error.IoFailed;
        w.writeInt(u32, entry.stat.mtime_nanoseconds, .big) catch return error.IoFailed;
        w.writeInt(u32, entry.stat.dev, .big) catch return error.IoFailed;
        w.writeInt(u32, entry.stat.ino, .big) catch return error.IoFailed;
        w.writeInt(u32, @intFromEnum(entry.mode), .big) catch return error.IoFailed;
        w.writeInt(u32, entry.stat.uid, .big) catch return error.IoFailed;
        w.writeInt(u32, entry.stat.gid, .big) catch return error.IoFailed;
        w.writeInt(u32, entry.size, .big) catch return error.IoFailed;

        const oid_len = f.byteLength();
        const oid_bytes_ptr = switch (f) {
            .sha1 => &entry.oid.sha1,
            .sha256 => &entry.oid.sha256,
        };
        w.writeAll(oid_bytes_ptr[0..oid_len]) catch return error.IoFailed;

        // Flags: stage bits (12-13), name length bits (0-11).
        const stage_bits: u16 = @intCast(@intFromEnum(entry.stage));
        const name_len = entry.path.len;
        const name_len_field: u16 = if (name_len >= Index.name_len_overflow)
            Index.name_len_overflow
        else
            @intCast(name_len);
        const flags = (stage_bits << Index.stage_shift) | name_len_field;
        w.writeInt(u16, flags, .big) catch return error.IoFailed;

        // Write path NUL-terminated.
        w.writeAll(entry.path) catch return error.IoFailed;
        w.writeByte(0) catch return error.IoFailed;

        // Padding to 8-byte boundary.
        const consumed: u64 = 40 + oid_len + 2 + entry.path.len + 1;
        const padded = std.mem.alignForward(u64, consumed, 8);
        const pad = padded - consumed;
        if (pad > 0) {
            const pad_bytes: [7]u8 = [_]u8{0} ** 7;
            w.writeAll(pad_bytes[0..pad]) catch return error.IoFailed;
        }
    }

    const content = try aw.toOwnedSlice();
    defer i.gpa.free(content);

    // Compute checksum.
    var hasher = Hasher.init(f);
    hasher.update(content);
    const checksum = hasher.final();
    const checksum_bytes_ptr = switch (f) {
        .sha1 => &checksum.sha1,
        .sha256 => &checksum.sha256,
    };
    const checksum_len = f.byteLength();

    // Write through lock file and rename.
    var lock_file = git_dir.createFile(io, "index.lock", .{ .truncate = true }) catch return error.IoFailed;
    defer lock_file.close(io);

    var write_buffer: [8192]u8 = undefined;
    var file_writer = lock_file.writer(io, &write_buffer);
    const fw = &file_writer.interface;
    fw.writeAll(content) catch return error.IoFailed;
    fw.writeAll(checksum_bytes_ptr[0..checksum_len]) catch return error.IoFailed;
    file_writer.flush() catch return error.IoFailed;

    // Atomically rename lock to index.
    git_dir.rename("index.lock", git_dir, "index", io) catch {
        // Clean up the lock file if rename fails.
        git_dir.deleteFile(io, "index.lock") catch {};
        return error.IoFailed;
    };
}

/// Walks a worktree, hashing each file into the odb, and returns an Index
/// the caller can hand to `write` or to `writeTreeFromIndex`.
///
/// Skips the repository directory, using isDotGitName. Not an option, not a
/// gitignore rule: it is a hard rule in git itself, and a consumer running
/// Repository.init at the very path they stage will have .git inside the
/// walked tree. Without the skip the index and tree are garbage and nothing
/// errors.
///
/// Regular files, executables and symlinks get .blob, .blob_executable and
/// .symlink. The permission check mirrors lib/ziggit-checkout/Checkout.zig
/// in reverse.
///
/// Stat block fields: this function fills ctime, mtime, ino and size from
/// std.Io.File.Stat. It writes zero for dev, uid and gid: std.Io.File.Stat
/// does not expose them. Git compares all six by default, so a zeroed trio
/// makes the stat check miss and git falls back to comparing content. The
/// answer stays correct and only the work is wasted, and git rewrites the
/// index with its own values the first time it writes one. Say this in doc
/// comments so nobody later "fixes" it by inventing values.
///
/// Honour NO ignore rules. Ziggit has no gitignore support. A caller staging
/// a directory with build output gets the build output. Say so plainly in doc
/// comments; it must not be mistaken for `git add -A`.
///
/// Paths in the index use `/` separators and are relative to the worktree
/// root.
pub fn stageWorktree(gpa: Allocator, io: std.Io, work_tree: std.Io.Dir, odb: *Odb, f: Format) Error!Index {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |*e| e.deinit(gpa);
        entries.deinit(gpa);
    }

    var path_buf: [1024]u8 = undefined;
    try walkDirectory(gpa, io, work_tree, work_tree, odb, f, &entries, &path_buf, 0);

    // Sort entries by path.
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, lhs: Entry, rhs: Entry) bool {
            return std.mem.order(u8, lhs.path, rhs.path) == .lt;
        }
    }.lessThan);

    return .{ .gpa = gpa, .entries = try entries.toOwnedSlice(gpa) };
}

fn walkDirectory(
    gpa: Allocator,
    io: std.Io,
    root: std.Io.Dir,
    current: std.Io.Dir,
    odb: *Odb,
    f: Format,
    entries: *std.ArrayList(Entry),
    path_buf: *[1024]u8,
    path_len: usize,
) Error!void {
    var iterator = current.iterate();

    while (iterator.next(io) catch return error.IoFailed) |entry| {
        // Skip the repository directory
        if (core_mod.isDotGitName(entry.name)) continue;

        // Build the full path for this entry
        if (path_len + entry.name.len + 1 >= path_buf.len) return error.IoFailed;

        const entry_start = path_len;
        @memcpy(path_buf[entry_start .. entry_start + entry.name.len], entry.name);
        var current_path_len = entry_start + entry.name.len;

        switch (entry.kind) {
            .directory => {
                // Recurse into subdirectory
                path_buf[current_path_len] = '/';
                current_path_len += 1;

                var subdir = current.openDir(io, entry.name, .{ .iterate = true }) catch return error.IoFailed;
                defer subdir.close(io);
                try walkDirectory(gpa, io, root, subdir, odb, f, entries, path_buf, current_path_len);
            },
            .file => {
                // Get file stat for mtime, ctime, ino, size
                const stat = current.statFile(io, entry.name, .{ .follow_symlinks = true }) catch return error.IoFailed;

                // Read file content for hashing
                var file = current.openFile(io, entry.name, .{}) catch return error.IoFailed;
                defer file.close(io);

                var read_buf: [8192]u8 = undefined;
                var freader = file.reader(io, &read_buf);
                const content = freader.interface.allocRemaining(gpa, .unlimited) catch |err| return switch (err) {
                    error.ReadFailed => error.IoFailed,
                    error.StreamTooLong => error.IoFailed,
                    error.OutOfMemory => error.OutOfMemory,
                };
                defer gpa.free(content);

                const oid = try odb.write(.blob, content, null);

                // Determine file mode based on permissions
                const mode: FileMode = if (@intFromEnum(stat.permissions) & 0o111 != 0)
                    .blob_executable
                else
                    .blob;

                // Create path string (owned by the entry)
                const path_str = try gpa.dupe(u8, path_buf[0..current_path_len]);

                // Create Entry
                const idx_entry: Entry = .{
                    .path = path_str,
                    .oid = oid,
                    .mode = mode,
                    .stage = .merged,
                    .size = @intCast(stat.size),
                    .stat = statFromFile(stat),
                };

                try entries.append(gpa, idx_entry);
            },
            .sym_link => {
                // For symlinks, read the target
                const stat = current.statFile(io, entry.name, .{ .follow_symlinks = false }) catch return error.IoFailed;
                var target_buf: [1024]u8 = undefined;
                const target_len = current.readLink(io, entry.name, &target_buf) catch return error.IoFailed;
                const target = target_buf[0..target_len];

                const oid = try odb.write(.blob, target, null);

                // Create path string (owned by the entry)
                const path_str = try gpa.dupe(u8, path_buf[0..current_path_len]);

                // Create Entry
                const idx_entry: Entry = .{
                    .path = path_str,
                    .oid = oid,
                    .mode = .symlink,
                    .stage = .merged,
                    .size = @intCast(stat.size),
                    .stat = statFromFile(stat),
                };

                try entries.append(gpa, idx_entry);
            },
            else => {},
        }
    }
}

// Tests for write

test "the index writer produces the bytes real git produces" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Decode INDEX_NOEXT_HEX: 248 bytes, no extensions.
    const hex_str = "4449524300000002000000036aad61ac0704332f6aad61ac0704332f00000022000c2b5f000081a4000003e80000006400000006ce013625030ba8dba906f756967f9e9ca394464a0005612e74787400000000006aad61ac079cca546aad61ac079cca5400000022000c4a4e000081a4000003e8000000640000000779c53955ef856f16f2107446bc721c8879a1bd2e0007642f622e7478740000006aad61ac079cca546aad61ac079cca5400000022000c4a50000081ed000003e8000000640000000a1a2485251c33a70432394c93fb89330ef214bfc9000672756e2e73680000000080b071ddea14076c1c019c8e72fe82e8e1701f26";
    var expected: [248]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, hex_str);

    var idx = try openFromBytes(gpa, tmp.dir, io, &expected);
    defer idx.deinit();

    try write(idx, io, tmp.dir, .sha1);

    var file = tmp.dir.openFile(io, "index", .{}) catch return error.TestUnexpectedError;
    defer file.close(io);
    var read_buffer: [256]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    reader.seekTo(0) catch return error.TestUnexpectedError;
    const r = &reader.interface;

    const written = r.take(248) catch return error.TestUnexpectedError;

    try std.testing.expectEqualSlices(u8, &expected, written);
}

test "a read and a write round trip preserves an entry's stat block" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const hex_str = "4449524300000002000000036aad61ac0704332f6aad61ac0704332f00000022000c2b5f000081a4000003e80000006400000006ce013625030ba8dba906f756967f9e9ca394464a0005612e74787400000000006aad61ac079cca546aad61ac079cca5400000022000c4a4e000081a4000003e8000000640000000779c53955ef856f16f2107446bc721c8879a1bd2e0007642f622e7478740000006aad61ac079cca546aad61ac079cca5400000022000c4a50000081ed000003e8000000640000000a1a2485251c33a70432394c93fb89330ef214bfc9000672756e2e73680000000080b071ddea14076c1c019c8e72fe82e8e1701f26";
    var bytes: [248]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex_str);

    var idx1 = try openFromBytes(gpa, tmp.dir, io, &bytes);
    defer idx1.deinit();

    const stat1 = idx1.entries[0].stat;

    try write(idx1, io, tmp.dir, .sha1);

    var idx2 = try Index.open(gpa, io, tmp.dir, .sha1);
    defer idx2.deinit();

    const stat2 = idx2.entries[0].stat;

    try std.testing.expectEqual(stat1.ctime_seconds, stat2.ctime_seconds);
    try std.testing.expectEqual(stat1.ctime_nanoseconds, stat2.ctime_nanoseconds);
    try std.testing.expectEqual(stat1.mtime_seconds, stat2.mtime_seconds);
    try std.testing.expectEqual(stat1.mtime_nanoseconds, stat2.mtime_nanoseconds);
    try std.testing.expectEqual(stat1.dev, stat2.dev);
    try std.testing.expectEqual(stat1.ino, stat2.ino);
    try std.testing.expectEqual(stat1.uid, stat2.uid);
    try std.testing.expectEqual(stat1.gid, stat2.gid);
}

test "entries handed out of order are sorted on write" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build an index with entries in the wrong order.
    var entries: [3]Entry = undefined;

    entries[0] = .{
        .path = try gpa.dupe(u8, "run.sh"),
        .oid = Oid.fromBytes(.sha1, &[_]u8{
            0x1a, 0x24, 0x85, 0x25, 0x1c, 0x33, 0xa7, 0x04, 0x32, 0x39,
            0x4c, 0x93, 0xfb, 0x89, 0x33, 0x0e, 0xf2, 0x14, 0xbf, 0xc9,
        }),
        .mode = FileMode.blob_executable,
        .stage = Stage.merged,
        .size = 10,
        .stat = .{
            .ctime_seconds = 0x6aad61ac,
            .ctime_nanoseconds = 0x079cca54,
            .mtime_seconds = 0x6aad61ac,
            .mtime_nanoseconds = 0x079cca54,
            .dev = 34,
            .ino = 805456,
            .uid = 1000,
            .gid = 100,
        },
    };

    entries[1] = .{
        .path = try gpa.dupe(u8, "a.txt"),
        .oid = Oid.fromBytes(.sha1, &[_]u8{
            0xce, 0x01, 0x36, 0x25, 0x03, 0x0b, 0xa8, 0xdb, 0xa9, 0x06,
            0xf7, 0x56, 0x96, 0x7f, 0x9e, 0x9c, 0xa3, 0x94, 0x46, 0x4a,
        }),
        .mode = FileMode.blob,
        .stage = Stage.merged,
        .size = 6,
        .stat = .{
            .ctime_seconds = 0x6aad61ac,
            .ctime_nanoseconds = 0x0704332f,
            .mtime_seconds = 0x6aad61ac,
            .mtime_nanoseconds = 0x0704332f,
            .dev = 34,
            .ino = 797535,
            .uid = 1000,
            .gid = 100,
        },
    };

    entries[2] = .{
        .path = try gpa.dupe(u8, "d/b.txt"),
        .oid = Oid.fromBytes(.sha1, &[_]u8{
            0x79, 0xc5, 0x39, 0x55, 0xef, 0x85, 0x6f, 0x16, 0xf2, 0x10,
            0x74, 0x46, 0xbc, 0x72, 0x1c, 0x88, 0x79, 0xa1, 0xbd, 0x2e,
        }),
        .mode = FileMode.blob,
        .stage = Stage.merged,
        .size = 7,
        .stat = .{
            .ctime_seconds = 0x6aad61ac,
            .ctime_nanoseconds = 0x079cca54,
            .mtime_seconds = 0x6aad61ac,
            .mtime_nanoseconds = 0x079cca54,
            .dev = 34,
            .ino = 805454,
            .uid = 1000,
            .gid = 100,
        },
    };

    const idx: Index = .{
        .gpa = gpa,
        .entries = &entries,
    };

    try write(idx, io, tmp.dir, .sha1);

    var read_idx = try Index.open(gpa, io, tmp.dir, .sha1);
    defer read_idx.deinit();

    try std.testing.expectEqualStrings("a.txt", read_idx.entries[0].path);
    try std.testing.expectEqualStrings("d/b.txt", read_idx.entries[1].path);
    try std.testing.expectEqualStrings("run.sh", read_idx.entries[2].path);

    for (&entries) |entry| {
        gpa.free(entry.path);
    }
}

test "the index is written through a lock file and none is left behind" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Plant a stale lock file with recognisable bytes.
    const lock_bytes = "STALE_LOCK_MARKER_1234567890"[0..28];
    try tmp.dir.writeFile(io, .{ .sub_path = "index.lock", .data = lock_bytes });

    const hex_str = "4449524300000002000000036aad61ac0704332f6aad61ac0704332f00000022000c2b5f000081a4000003e80000006400000006ce013625030ba8dba906f756967f9e9ca394464a0005612e74787400000000006aad61ac079cca546aad61ac079cca5400000022000c4a4e000081a4000003e8000000640000000779c53955ef856f16f2107446bc721c8879a1bd2e0007642f622e7478740000006aad61ac079cca546aad61ac079cca5400000022000c4a50000081ed000003e8000000640000000a1a2485251c33a70432394c93fb89330ef214bfc9000672756e2e73680000000080b071ddea14076c1c019c8e72fe82e8e1701f26";
    var bytes: [248]u8 = undefined;
    _ = try std.fmt.hexToBytes(&bytes, hex_str);

    var idx = try openFromBytes(gpa, tmp.dir, io, &bytes);
    defer idx.deinit();

    try write(idx, io, tmp.dir, .sha1);

    var file = tmp.dir.openFile(io, "index", .{}) catch return error.TestUnexpectedError;
    defer file.close(io);
    var read_buffer: [256]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    reader.seekTo(0) catch return error.TestUnexpectedError;
    const r = &reader.interface;

    const index_content = r.take(248) catch return error.TestUnexpectedError;

    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "index.lock", .{}));
    try std.testing.expect(!std.mem.containsAtLeast(u8, index_content, 1, lock_bytes));
}

// Staging tests. The first is the one that matters: it pins the walk, the
// modes, the paths and the hashing all at once against a tree id real git
// produced, rather than against anything ziggit computed.

const tree_builder = @import("ziggit-odb").writeTreeFromIndex;

fn stagingFixture(io: std.Io, dir: std.Io.Dir) !void {
    try dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello\n" });
    try dir.createDirPath(io, "d");
    try dir.writeFile(io, .{ .sub_path = "d/b.txt", .data = "nested\n" });
    try dir.writeFile(io, .{ .sub_path = "run.sh", .data = "#!/bin/sh\n" });
    var f = try dir.openFile(io, "run.sh", .{});
    defer f.close(io);
    try f.setPermissions(io, @enumFromInt(0o755));
}

/// The object database lives OUTSIDE the staged worktree, as a real
/// repository's does under `.git`. Putting it inside meant the walk
/// descended into the objects it was writing as it wrote them.
fn stagingOdb(gpa: Allocator, io: std.Io, dir: std.Io.Dir) !Odb {
    try dir.createDirPath(io, "objects");
    const objects = try dir.openDir(io, "objects", .{ .iterate = true });
    return Odb.init(gpa, io, objects, .sha1, .{});
}

test "staging a worktree and writing its tree matches real git" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try stagingFixture(io, tmp.dir);

    var odb_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer odb_tmp.cleanup();
    var odb = try stagingOdb(gpa, io, odb_tmp.dir);
    defer odb.deinit();

    var index = try stageWorktree(gpa, io, tmp.dir, &odb, .sha1);
    defer index.deinit();

    const root = try tree_builder(gpa, &odb, index, null);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("dc388fc74b7ae653cebc33b4d91de4fc84b13394", root.toHex(&buf));
}

test "a repository directory inside the worktree is not staged" {
    // The real consumer initialises its repository at the very path it
    // stages, so `.git` is inside the walked tree. Staging it produces a
    // garbage index and tree with no error at all.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try stagingFixture(io, tmp.dir);

    // The layout `Repository.init` creates, built by hand: `ziggit-index`
    // cannot import `ziggit-repo` without inverting the module layering,
    // and what this test needs is a real `.git` directory with real files
    // in it, which this is.
    try tmp.dir.createDirPath(io, ".git/objects/pack");
    try tmp.dir.createDirPath(io, ".git/refs/heads");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/master\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/config", .data = "[core]\n\tbare = false\n" });

    var odb_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer odb_tmp.cleanup();
    var odb = try stagingOdb(gpa, io, odb_tmp.dir);
    defer odb.deinit();

    var index = try stageWorktree(gpa, io, tmp.dir, &odb, .sha1);
    defer index.deinit();

    for (index.entries) |e| {
        try std.testing.expect(!std.mem.startsWith(u8, e.path, ".git"));
    }
    // And the tree is still exactly git's, which it cannot be if anything
    // from `.git` crept in.
    const root = try tree_builder(gpa, &odb, index, null);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("dc388fc74b7ae653cebc33b4d91de4fc84b13394", root.toHex(&buf));
}

test "a file named git~1 is staged" {
    // The other side of the bound. Checkout refuses `git~1` because a
    // hostile TREE can use it to reach `.git` on an NTFS filesystem. Staging
    // reads names a person already has on disk, and on Linux `git~1` is an
    // ordinary filename, so refusing it here would silently lose a real
    // file. Without this test nothing stops the narrow rule drifting into
    // the wide one.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "git~1", .data = "ordinary\n" });

    var odb_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer odb_tmp.cleanup();
    var odb = try stagingOdb(gpa, io, odb_tmp.dir);
    defer odb.deinit();

    var index = try stageWorktree(gpa, io, tmp.dir, &odb, .sha1);
    defer index.deinit();

    var found = false;
    for (index.entries) |e| {
        if (std.mem.eql(u8, e.path, "git~1")) found = true;
    }
    try std.testing.expect(found);
}

test "a staged entry records the stat fields std.Io exposes and zeroes the rest" {
    // Asserts the DOCUMENTED behaviour, not a hoped-for one. `std.Io.File.Stat`
    // carries no dev, uid or gid, so those are zero on purpose; see
    // `statFromFile`.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello\n" });

    var odb_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer odb_tmp.cleanup();
    var odb = try stagingOdb(gpa, io, odb_tmp.dir);
    defer odb.deinit();

    var index = try stageWorktree(gpa, io, tmp.dir, &odb, .sha1);
    defer index.deinit();

    const e = index.find("a.txt").?;
    try std.testing.expectEqual(@as(u32, 6), e.size);
    // Recorded, because std.Io reports them.
    try std.testing.expect(e.stat.mtime_seconds != 0);
    try std.testing.expect(e.stat.ctime_seconds != 0);
    try std.testing.expect(e.stat.ino != 0);
    // Zero, because std.Io does not report them.
    try std.testing.expectEqual(@as(u32, 0), e.stat.dev);
    try std.testing.expectEqual(@as(u32, 0), e.stat.uid);
    try std.testing.expectEqual(@as(u32, 0), e.stat.gid);
}
