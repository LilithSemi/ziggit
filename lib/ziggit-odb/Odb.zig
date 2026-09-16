//! The object database policy layer: which backend, loose or packed,
//! answers a read; where a write lands; and which alternate object
//! directories a read may also try.
//!
//! `Odb` never writes anywhere but its own write directory. That is what
//! makes `Options.object_directory` and `Options.alternate_directories`
//! load-bearing for a sandboxed consumer: point writes at a scratch
//! directory, mount the real repository's objects read only as an
//! alternate, and nothing this module does can touch the real repository.

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

const object_mod = @import("ziggit-object");

const loose_backend = @import("loose_backend.zig");
const pack_backend = @import("pack_backend.zig");
const alternates_mod = @import("alternates.zig");
const ObjectStat = @import("object_stat.zig").ObjectStat;

pub const Odb = struct {
    gpa: Allocator,
    io: std.Io,
    format: Format,

    /// Where every write lands, and the first place every read is tried.
    /// This is `options.object_directory`, opened by `init` itself, when
    /// set; otherwise it is `objects_dir` as given to `init`, borrowed, not
    /// owned.
    write_dir: std.Io.Dir,
    /// Whether `deinit` must close `write_dir`: true only when `init`
    /// opened it itself, for `options.object_directory`.
    write_dir_owned: bool,
    write_packs: pack_backend.PackSet,

    /// Every read-only location beyond `write_dir`, in the order a lookup
    /// tries them: `options.alternate_directories`, then whatever their own
    /// and `write_dir`'s `objects/info/alternates` chains name. Owned by
    /// this `Odb`, closed and freed by `deinit`. Nothing in this module
    /// ever writes through one of these.
    alternates: []Alternate,

    const Alternate = struct {
        dir: std.Io.Dir,
        packs: pack_backend.PackSet,
    };

    pub const Error = error{
        ObjectNotFound,
        AmbiguousPrefix,
        AlternatesCycle,
        AlternatesTooDeep,
        CorruptObject,
        /// `readAlloc` only: the object is well formed, but its real size
        /// is over the caller's `max_size` budget. Distinct from
        /// `error.OutOfMemory` so a caller can tell a deliberate policy
        /// refusal apart from real allocator exhaustion; the fix for this
        /// one is to call the streaming `read` instead.
        ObjectTooLarge,
        IoFailed,
    } || Pack.Error || Allocator.Error;

    /// How deep a chain of `objects/info/alternates` files this follows.
    pub const max_alternates_depth: usize = 5;

    pub const Options = struct {
        /// GIT_OBJECT_DIRECTORY. When set, every write lands here instead of
        /// in the repository's own objects dir, and this replaces that
        /// directory as the first place every read is tried too. This is
        /// load-bearing for a sandbox that must keep an agent's writes out
        /// of the real repository.
        object_directory: ?[]const u8 = null,
        /// GIT_ALTERNATE_OBJECT_DIRECTORIES. Each entry names one directory,
        /// already split on the environment variable's ':' separator by the
        /// caller. Read only, always, with no exception: `Odb` never writes
        /// through one of these.
        alternate_directories: []const []const u8 = &.{},
    };

    /// Opens the object database rooted at `objects_dir`. `objects_dir` and
    /// every path named in `options` must already exist and be opened (or
    /// openable) with iteration enabled: `resolvePrefix` and `refreshPacks`
    /// both need to list directory contents. `objects_dir` stays
    /// caller-owned; `deinit` never closes it unless
    /// `options.object_directory` replaces it.
    pub fn init(gpa: Allocator, io: std.Io, objects_dir: std.Io.Dir, f: Format, options: Options) Error!Odb {
        var write_dir = objects_dir;
        var write_dir_owned = false;
        if (options.object_directory) |path| {
            write_dir = openDirPath(io, path) catch return error.IoFailed;
            write_dir_owned = true;
        }
        errdefer if (write_dir_owned) write_dir.close(io);

        var write_packs = pack_backend.PackSet.init(gpa, io, f);
        errdefer write_packs.deinit();
        try write_packs.refresh(write_dir);

        const resolved = alternates_mod.resolve(gpa, io, write_dir, options.alternate_directories, max_alternates_depth) catch |err| switch (err) {
            error.AlternatesCycle => return error.AlternatesCycle,
            error.AlternatesTooDeep => return error.AlternatesTooDeep,
            error.IoFailed => return error.IoFailed,
            error.OutOfMemory => return error.OutOfMemory,
        };
        errdefer alternates_mod.freeAll(gpa, io, resolved);

        var alts: std.ArrayList(Alternate) = .empty;
        errdefer {
            for (alts.items) |*a| a.packs.deinit();
            alts.deinit(gpa);
        }
        for (resolved) |rd| {
            var ps = pack_backend.PackSet.init(gpa, io, f);
            errdefer ps.deinit();
            try ps.refresh(rd);
            try alts.append(gpa, .{ .dir = rd, .packs = ps });
        }
        gpa.free(resolved);

        return .{
            .gpa = gpa,
            .io = io,
            .format = f,
            .write_dir = write_dir,
            .write_dir_owned = write_dir_owned,
            .write_packs = write_packs,
            .alternates = try alts.toOwnedSlice(gpa),
        };
    }

    pub fn deinit(o: *Odb) void {
        for (o.alternates) |*a| {
            a.packs.deinit();
            a.dir.close(o.io);
        }
        o.gpa.free(o.alternates);
        o.write_packs.deinit();
        if (o.write_dir_owned) o.write_dir.close(o.io);
        o.* = undefined;
    }

    /// Whether `oid` is stored anywhere this database looks: `write_dir`,
    /// its packs, or an alternate. A real fault checking a loose object
    /// (a permission error, for example) is `error.IoFailed`, never
    /// folded into `false`: this is what `write` calls to decide whether
    /// to skip a duplicate write, and a fault silently read as "absent"
    /// there would risk writing over something this call could not
    /// actually confirm was safe to.
    pub fn exists(o: *Odb, oid: Oid) Error!bool {
        if (try loose_backend.exists(o.write_dir, o.io, oid)) return true;
        if (o.write_packs.exists(oid)) return true;
        for (o.alternates) |*a| {
            if (try loose_backend.exists(a.dir, o.io, oid)) return true;
            if (a.packs.exists(oid)) return true;
        }
        return false;
    }

    /// The kind and size of `oid`. Cheap, header only, for a loose object.
    /// For a packed object there is no header that carries the final size
    /// of a delta chain: this resolves the whole chain and decompresses
    /// every byte to learn it, the same cost `read` itself pays, only
    /// discarding the bytes instead of returning them.
    pub fn stat(o: *Odb, oid: Oid) Error!struct { kind: ObjectKind, size: u64 } {
        // The public signature above keeps its own anonymous literal, on
        // purpose: it is what the brief mandates. `statDiag` returns the
        // named, internal `ObjectStat` instead, so the two are distinct
        // types and this re-expresses one as the other rather than
        // forwarding the value directly.
        const info = try o.statDiag(oid, null);
        return .{ .kind = info.kind, .size = info.size };
    }

    fn statDiag(o: *Odb, oid: Oid, diag: ?*?Diagnostic) Error!ObjectStat {
        if (try loose_backend.stat(o.gpa, o.io, o.write_dir, oid, diag)) |s| return s;
        if (try o.write_packs.stat(o.gpa, oid, diag)) |s| return s;
        for (o.alternates) |*a| {
            if (try loose_backend.stat(o.gpa, o.io, a.dir, oid, diag)) |s| return s;
            if (try a.packs.stat(o.gpa, oid, diag)) |s| return s;
        }
        return error.ObjectNotFound;
    }

    /// Streams the payload of `oid` into `w`. A blob can be gigabytes, so
    /// this never materializes a whole object.
    ///
    /// The two backends give different integrity guarantees on this read,
    /// on purpose. The loose backend hashes every byte it streams and
    /// reports `error.CorruptObject` when the result does not match `oid`,
    /// the same check git itself makes on a loose object. The pack backend
    /// makes no such check here: git trusts a pack's own trailer checksum
    /// and the per-entry crc32 already verified when its `.idx` was built,
    /// rather than re-hashing a decompressed object on every read. Hashing
    /// every packed read would turn a cheap lookup into a full
    /// decompression each time, for a guarantee the pack format already
    /// gives another way.
    pub fn read(o: *Odb, oid: Oid, w: *std.Io.Writer, diag: ?*?Diagnostic) Error!ObjectKind {
        if (try loose_backend.read(o.gpa, o.io, o.write_dir, o.format, oid, w, diag)) |k| return k;
        if (try o.write_packs.read(o.gpa, oid, w, diag)) |k| return k;
        for (o.alternates) |*a| {
            if (try loose_backend.read(o.gpa, o.io, a.dir, o.format, oid, w, diag)) |k| return k;
            if (try a.packs.read(o.gpa, oid, w, diag)) |k| return k;
        }
        return error.ObjectNotFound;
    }

    /// Reads `oid` into a fresh allocation. Only for objects you know are
    /// small, such as a commit or a tree. Caller frees.
    ///
    /// `max_size` is an allocation budget, not a data limit: this
    /// allocates it up front and reads straight into it, refusing with
    /// `error.ObjectTooLarge` when `oid` does not fit rather than growing
    /// past it. That is a deliberate policy refusal, not allocator
    /// exhaustion: a caller that hits it should call the streaming `read`
    /// instead of retrying this.
    ///
    /// A packed object has no header carrying its final size (see `stat`),
    /// so finding that out costs a full decompression of its own. Reading
    /// straight into a `max_size` buffer, rather than calling `stat` first
    /// to size an exact allocation, is what keeps the common case, an
    /// object that fits, down to one decompression instead of two; `stat`
    /// is still called, but only once more, when the read above did not
    /// succeed, to tell "too large" apart from every other fault.
    pub fn readAlloc(o: *Odb, gpa: Allocator, oid: Oid, max_size: usize, diag: ?*?Diagnostic) Error![]u8 {
        const buf = try gpa.alloc(u8, max_size);
        var w: std.Io.Writer = .fixed(buf);

        if (o.read(oid, &w, diag)) |_| {
            // Trust what the writer actually reports it received, not the
            // buffer's own length: `read` never promises to fill every
            // byte of whatever it is handed.
            const written = w.buffered().len;
            return gpa.realloc(buf, written);
        } else |err| {
            gpa.free(buf);
            const info = o.statDiag(oid, diag) catch |stat_err| return stat_err;
            if (info.size > max_size) {
                if (core_mod.wants(diag)) {
                    const detail = std.fmt.allocPrint(gpa, "object is {d} bytes, over the {d} byte limit", .{ info.size, max_size }) catch null;
                    core_mod.report(diag, gpa, .{ .kind = .object_too_large, .path = null, .detail = detail });
                }
                return error.ObjectTooLarge;
            }
            return err;
        }
    }

    /// Writes a loose object through a temp file and an atomic rename.
    /// Writing an object that already exists anywhere in this database,
    /// loose, packed, or in an alternate, succeeds and changes nothing.
    /// Always lands in `write_dir`; never in an alternate.
    pub fn write(o: *Odb, kind: ObjectKind, payload: []const u8, diag: ?*?Diagnostic) Error!Oid {
        const oid = object_mod.loose.hash(o.format, kind, payload);
        if (try o.exists(oid)) return oid;
        return loose_backend.write(o.gpa, o.io, o.write_dir, o.format, kind, payload, diag);
    }

    // A real repository routinely holds the same object both loose and
    // packed (for example after `git repack` without `-d`) or in two packs
    // at once (an incremental repack). Counting every match would call that
    // one object ambiguous, so this tracks only whether a match differs
    // from the first one seen: two matches that are the same id are one
    // object; a match that differs from `first` is a second, genuinely
    // distinct, object.
    const PrefixAcc = struct {
        first: ?Oid = null,
        ambiguous: bool = false,

        pub fn add(self: *PrefixAcc, oid: Oid) void {
            if (self.first) |f| {
                if (!f.eql(oid)) self.ambiguous = true;
            } else {
                self.first = oid;
            }
        }

        /// `found` holds up to the first few of `matched` ids a single pack
        /// index reported for this prefix; every id in one index is
        /// distinct by construction (an index maps each id to one offset),
        /// so `matched > 1` already proves at least two distinct objects
        /// regardless of how many `found` could hold.
        pub fn addMany(self: *PrefixAcc, matched: usize, found: []const Oid) void {
            if (matched == 0) return;
            if (matched > 1) {
                self.ambiguous = true;
                if (self.first == null and found.len > 0) self.first = found[0];
                return;
            }
            self.add(found[0]);
        }
    };

    /// Resolves an abbreviated hex id. `error.AmbiguousPrefix` when more
    /// than one distinct object matches, across every backend and every
    /// alternate. The same object found more than once, loose and packed,
    /// or in two packs, counts once; only a genuinely different object
    /// sharing the prefix counts as a second match.
    pub fn resolvePrefix(o: *Odb, hex_prefix: []const u8) Error!Oid {
        var acc: PrefixAcc = .{};
        loose_backend.findPrefix(o.io, o.write_dir, o.format, hex_prefix, &acc) catch return error.IoFailed;
        o.write_packs.findPrefix(hex_prefix, &acc);
        for (o.alternates) |*a| {
            loose_backend.findPrefix(o.io, a.dir, o.format, hex_prefix, &acc) catch return error.IoFailed;
            a.packs.findPrefix(hex_prefix, &acc);
        }
        if (acc.first == null) return error.ObjectNotFound;
        if (acc.ambiguous) return error.AmbiguousPrefix;
        return acc.first.?;
    }

    /// Re-scans `objects/pack` for packs added since `init`, in `write_dir`
    /// and in every alternate.
    pub fn refreshPacks(o: *Odb) Error!void {
        try o.write_packs.refresh(o.write_dir);
        for (o.alternates) |*a| try a.packs.refresh(a.dir);
    }
};

fn openDirPath(io: std.Io, path: []const u8) std.Io.Dir.OpenError!std.Io.Dir {
    return core_mod.openDirRelative(io, null, path);
}

// Test helpers shared by every test below: a small, real repository-shaped
// object directory, built fresh per test so nothing here depends on
// another test's leftovers.

fn realPathOf(gpa: Allocator, io: std.Io, dir: std.Io.Dir) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try dir.realPath(io, &buf);
    return gpa.dupe(u8, buf[0..len]);
}

// expected

test "write then read round trips a blob through the loose backend" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var odb = try Odb.init(gpa, io, tmp.dir, .sha1, .{});
    defer odb.deinit();

    const oid = try odb.write(.blob, "hello\n", null);
    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const kind = try odb.read(oid, &out, null);
    try std.testing.expectEqual(ObjectKind.blob, kind);
    try std.testing.expectEqualStrings("hello\n", out.buffered());
}

test "read finds an object that lives in a pack" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try pack_backend_test_helpers.buildPackAndIndex(gpa, io, tmp.dir, &.{"hello\n"});

    var odb = try Odb.init(gpa, io, tmp.dir, .sha1, .{});
    defer odb.deinit();

    const oid = object_mod.loose.hash(.sha1, .blob, "hello\n");
    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const kind = try odb.read(oid, &out, null);
    try std.testing.expectEqual(ObjectKind.blob, kind);
    try std.testing.expectEqualStrings("hello\n", out.buffered());
}

test "exists is true for a loose object and true for a packed one" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try pack_backend_test_helpers.buildPackAndIndex(gpa, io, tmp.dir, &.{"packed\n"});

    var odb = try Odb.init(gpa, io, tmp.dir, .sha1, .{});
    defer odb.deinit();

    const loose_oid = try odb.write(.blob, "loose\n", null);
    const packed_oid = object_mod.loose.hash(.sha1, .blob, "packed\n");
    try std.testing.expect(try odb.exists(loose_oid));
    try std.testing.expect(try odb.exists(packed_oid));
}

test "stat returns the kind and size without reading the payload" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var odb = try Odb.init(gpa, io, tmp.dir, .sha1, .{});
    defer odb.deinit();

    const oid = try odb.write(.tree, "", null);
    const info = try odb.stat(oid);
    try std.testing.expectEqual(ObjectKind.tree, info.kind);
    try std.testing.expectEqual(@as(u64, 0), info.size);
}

test "read finds an object that lives only in an alternate" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var main_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer main_tmp.cleanup();
    var alt_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer alt_tmp.cleanup();

    var alt_odb = try Odb.init(gpa, io, alt_tmp.dir, .sha1, .{});
    const alt_oid = try alt_odb.write(.blob, "only in the alternate\n", null);
    alt_odb.deinit();

    const alt_path = try realPathOf(gpa, io, alt_tmp.dir);
    defer gpa.free(alt_path);

    var odb = try Odb.init(gpa, io, main_tmp.dir, .sha1, .{ .alternate_directories = &.{alt_path} });
    defer odb.deinit();

    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const kind = try odb.read(alt_oid, &out, null);
    try std.testing.expectEqual(ObjectKind.blob, kind);
    try std.testing.expectEqualStrings("only in the alternate\n", out.buffered());
}

test "resolvePrefix returns the one object matching a unique prefix" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var odb = try Odb.init(gpa, io, tmp.dir, .sha1, .{});
    defer odb.deinit();

    const oid = try odb.write(.blob, "unique content for a prefix test\n", null);
    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const hex = oid.toHex(&hex_buf);

    const found = try odb.resolvePrefix(hex[0..10]);
    try std.testing.expect(found.eql(oid));
}

test "resolvePrefix counts an object stored both loose and packed as one match" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Arrange the same object in both backends directly, bypassing
    // `Odb.write`'s own existence check (which would otherwise skip the
    // loose write once the packed copy exists): `git repack` without `-d`
    // leaves a repository in exactly this state, one object reachable both
    // loose and packed at once.
    const payload = "stored both loose and packed\n";
    const oid = try loose_backend.write(gpa, io, tmp.dir, .sha1, .blob, payload, null);
    try pack_backend_test_helpers.buildPackAndIndex(gpa, io, tmp.dir, &.{payload});

    var odb = try Odb.init(gpa, io, tmp.dir, .sha1, .{});
    defer odb.deinit();

    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const hex = oid.toHex(&hex_buf);
    const found = try odb.resolvePrefix(hex[0..10]);
    try std.testing.expect(found.eql(oid));
}

test "refreshPacks picks up a pack added after init" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var odb = try Odb.init(gpa, io, tmp.dir, .sha1, .{});
    defer odb.deinit();

    const oid = object_mod.loose.hash(.sha1, .blob, "added later\n");
    try std.testing.expect(!(try odb.exists(oid)));

    try pack_backend_test_helpers.buildPackAndIndex(gpa, io, tmp.dir, &.{"added later\n"});
    try odb.refreshPacks();
    try std.testing.expect(try odb.exists(oid));
}

// suspicious

test "write respects object_directory and leaves the repository objects dir untouched" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var repo_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer repo_tmp.cleanup();
    var scratch_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer scratch_tmp.cleanup();

    const scratch_path = try realPathOf(gpa, io, scratch_tmp.dir);
    defer gpa.free(scratch_path);

    var odb = try Odb.init(gpa, io, repo_tmp.dir, .sha1, .{ .object_directory = scratch_path });
    defer odb.deinit();

    const oid = try odb.write(.blob, "sandboxed write\n", null);
    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const hex = oid.toHex(&hex_buf);
    var path_buf: [80]u8 = undefined;
    const rel_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ hex[0..2], hex[2..] });

    try std.testing.expect(try loose_backend.exists(scratch_tmp.dir, io, oid));
    try std.testing.expectError(error.FileNotFound, repo_tmp.dir.statFile(io, rel_path, .{}));
}

test "an alternate is never written to" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var main_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer main_tmp.cleanup();
    var alt_tmp = std.testing.tmpDir(.{ .iterate = true });
    defer alt_tmp.cleanup();

    const alt_path = try realPathOf(gpa, io, alt_tmp.dir);
    defer gpa.free(alt_path);

    var odb = try Odb.init(gpa, io, main_tmp.dir, .sha1, .{ .alternate_directories = &.{alt_path} });
    defer odb.deinit();

    const oid = try odb.write(.blob, "must land only in the write dir\n", null);
    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const hex = oid.toHex(&hex_buf);
    var path_buf: [80]u8 = undefined;
    const rel_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ hex[0..2], hex[2..] });

    try std.testing.expect(try loose_backend.exists(main_tmp.dir, io, oid));
    try std.testing.expectError(error.FileNotFound, alt_tmp.dir.statFile(io, rel_path, .{}));
}

test "an alternates file naming its own directory fails with AlternatesCycle" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "info");
    try tmp.dir.writeFile(io, .{ .sub_path = "info/alternates", .data = ".\n" });

    try std.testing.expectError(error.AlternatesCycle, Odb.init(gpa, io, tmp.dir, .sha1, .{}));
}

test "an alternates chain deeper than max_alternates_depth fails rather than recursing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var root = std.testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();

    var link: usize = 0;
    while (link <= 6) : (link += 1) {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "d{d}", .{link});
        try root.dir.createDirPath(io, name);
    }
    link = 0;
    while (link < 6) : (link += 1) {
        var alt_buf: [32]u8 = undefined;
        const alt_dir = try std.fmt.bufPrint(&alt_buf, "d{d}/info", .{link});
        try root.dir.createDirPath(io, alt_dir);
        var data_buf: [16]u8 = undefined;
        const data = try std.fmt.bufPrint(&data_buf, "../d{d}\n", .{link + 1});
        var path_buf: [32]u8 = undefined;
        const info_path = try std.fmt.bufPrint(&path_buf, "d{d}/info/alternates", .{link});
        try root.dir.writeFile(io, .{ .sub_path = info_path, .data = data });
    }

    var d0 = try root.dir.openDir(io, "d0", .{ .iterate = true });
    defer d0.close(io);

    try std.testing.expectError(error.AlternatesTooDeep, Odb.init(gpa, io, d0, .sha1, .{}));
}

test "a relative path in an alternates file resolves against the objects dir" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var root = std.testing.tmpDir(.{ .iterate = true });
    defer root.cleanup();

    try root.dir.createDirPath(io, "primary/info");
    try root.dir.createDirPath(io, "sibling");
    try root.dir.writeFile(io, .{ .sub_path = "primary/info/alternates", .data = "../sibling\n" });

    var primary_dir = try root.dir.openDir(io, "primary", .{ .iterate = true });
    defer primary_dir.close(io);

    var sibling_dir = try root.dir.openDir(io, "sibling", .{ .iterate = true });
    defer sibling_dir.close(io);
    var sibling_odb = try Odb.init(gpa, io, sibling_dir, .sha1, .{});
    const sibling_oid = try sibling_odb.write(.blob, "lives in the sibling\n", null);
    sibling_odb.deinit();

    var odb = try Odb.init(gpa, io, primary_dir, .sha1, .{});
    defer odb.deinit();

    try std.testing.expect(try odb.exists(sibling_oid));
}

test "resolvePrefix fails with AmbiguousPrefix when two objects match" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var odb = try Odb.init(gpa, io, tmp.dir, .sha1, .{});
    defer odb.deinit();

    // Two payloads chosen so their sha1 ids share a leading byte, found by
    // search rather than guessed: both start with 0x00.
    const a = try odb.write(.blob, "payload-850", null);
    const b = try odb.write(.blob, "payload-892", null);
    try std.testing.expectEqual(a.slice()[0], b.slice()[0]);

    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const hex = a.toHex(&hex_buf);
    try std.testing.expectError(error.AmbiguousPrefix, odb.resolvePrefix(hex[0..2]));
}

test "resolvePrefix counts matches across a pack and a loose object as ambiguous" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // Same pair as above: one written loose, the other placed directly in a
    // pack, so the ambiguity spans two different backends.
    try pack_backend_test_helpers.buildPackAndIndex(gpa, io, tmp.dir, &.{"payload-892"});

    var odb = try Odb.init(gpa, io, tmp.dir, .sha1, .{});
    defer odb.deinit();
    const loose_oid = try odb.write(.blob, "payload-850", null);

    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const hex = loose_oid.toHex(&hex_buf);
    try std.testing.expectError(error.AmbiguousPrefix, odb.resolvePrefix(hex[0..2]));
}

test "read of an absent id is ObjectNotFound, not a crash" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var odb = try Odb.init(gpa, io, tmp.dir, .sha1, .{});
    defer odb.deinit();

    var out_buf: [16]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try std.testing.expectError(error.ObjectNotFound, odb.read(Oid.zero(.sha1), &out, null));
}

test "writing an object that already exists changes nothing and still returns its id" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var odb = try Odb.init(gpa, io, tmp.dir, .sha1, .{});
    defer odb.deinit();

    const first = try odb.write(.blob, "idempotent\n", null);
    const second = try odb.write(.blob, "idempotent\n", null);
    try std.testing.expect(first.eql(second));

    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    const kind = try odb.read(first, &out, null);
    try std.testing.expectEqual(ObjectKind.blob, kind);
    try std.testing.expectEqualStrings("idempotent\n", out.buffered());
}

test "readAlloc refuses an object larger than max_size" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var odb = try Odb.init(gpa, io, tmp.dir, .sha1, .{});
    defer odb.deinit();

    const oid = try odb.write(.blob, "this payload is definitely more than four bytes long", null);
    var diag: ?Diagnostic = null;
    try std.testing.expectError(error.ObjectTooLarge, odb.readAlloc(gpa, oid, 4, &diag));
    defer if (diag) |*d| d.deinit(gpa);
    try std.testing.expect(diag != null);
}

test "readAlloc reads an object within max_size into a fresh allocation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var odb = try Odb.init(gpa, io, tmp.dir, .sha1, .{});
    defer odb.deinit();

    const oid = try odb.write(.blob, "small\n", null);
    const buf = try odb.readAlloc(gpa, oid, 64, null);
    defer gpa.free(buf);
    try std.testing.expectEqualStrings("small\n", buf);
}

test "a loose object file whose contents do not hash to its path name is CorruptObject" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var odb = try Odb.init(gpa, io, tmp.dir, .sha1, .{});
    defer odb.deinit();

    const oid = try odb.write(.blob, "hello\n", null);

    var aw = try std.Io.Writer.Allocating.initCapacity(gpa, 256);
    defer aw.deinit();
    _ = try object_mod.loose.write(.sha1, .blob, "goodbye\n", &aw.writer);
    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const hex = oid.toHex(&hex_buf);
    var path_buf: [80]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ hex[0..2], hex[2..] });
    try tmp.dir.writeFile(io, .{ .sub_path = path, .data = aw.writer.buffered() });

    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    try std.testing.expectError(error.CorruptObject, odb.read(oid, &out, null));
}

test "read of a packed object whose declared size dwarfs the pack is rejected before decompressing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "pack");
    var pack_dir = try tmp.dir.openDir(io, "pack", .{ .iterate = true });
    defer pack_dir.close(io);

    // A hostile pack: one entry, header only, claiming a decompressed size
    // no pack this small could ever back. `resolveChain`'s non-delta branch
    // used to hand every decompressed byte to the caller's writer before
    // ever comparing the declared size against the pack's own length. This
    // hand-builds both the `.pack` and its `.idx` (rather than going
    // through `writeIndex`, which now rejects this same pack while
    // building the index) so the bound is proven at `Odb.read`, the
    // boundary a caller actually crosses, not only through
    // `ziggit-pack`'s internal `decompressAlloc`.
    const oid = Oid.fromBytes(.sha1, &([_]u8{0x42} ** 20));

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("PACK");
    try w.writeInt(u32, 2, .big);
    try w.writeInt(u32, 1, .big);
    const entry_start: u64 = aw.writer.buffered().len;
    try pack_backend_test_helpers.writeVarintHeader(w, 3, 50_000_000_000); // 3 == blob
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compress = try std.compress.flate.Compress.init(w, &window, .zlib, .default);
    try compress.writer.writeAll("small");
    try compress.finish();
    try w.writeAll(&([_]u8{0} ** 20)); // trailer, never checked by read
    const pack_bytes = try aw.toOwnedSlice();
    defer gpa.free(pack_bytes);

    try pack_dir.writeFile(io, .{ .sub_path = "pack-1.pack", .data = pack_bytes });

    var iw: std.Io.Writer.Allocating = .init(gpa);
    defer iw.deinit();
    const iwr = &iw.writer;
    try iwr.writeAll("\xfftOc");
    try iwr.writeInt(u32, 2, .big);
    var fanout: [256]u32 = undefined;
    for (0..0x42) |b| fanout[b] = 0;
    for (0x42..256) |b| fanout[b] = 1;
    for (fanout) |v| try iwr.writeInt(u32, v, .big);
    try iwr.writeAll(oid.slice());
    try iwr.writeInt(u32, 0, .big); // crc32, never checked by read
    try iwr.writeInt(u32, @intCast(entry_start), .big);
    try iwr.writeAll(&([_]u8{0xaa} ** 20)); // pack checksum, unchecked by Index.open
    try iwr.writeAll(&([_]u8{0xbb} ** 20)); // index checksum, unchecked by Index.open
    const idx_bytes = try iw.toOwnedSlice();
    defer gpa.free(idx_bytes);

    try pack_dir.writeFile(io, .{ .sub_path = "pack-1.idx", .data = idx_bytes });

    var odb = try Odb.init(gpa, io, tmp.dir, .sha1, .{});
    defer odb.deinit();

    var out_buf: [64]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var diag: ?Diagnostic = null;
    try std.testing.expectError(error.CorruptPack, odb.read(oid, &out, &diag));
    defer if (diag) |*d| d.deinit(gpa);
    try std.testing.expect(diag != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.?.detail.?, "cannot fit in the bytes left") != null);
}

// Shared with `pack_backend.zig`'s own tests: builds a minimal, real pack
// plus a matching `.idx` under `objects/pack`. Duplicated rather than
// imported, since `pack_backend`'s copy is private to that file's own test
// block and `Odb` only consumes `ziggit-pack`'s public surface.
const pack_backend_test_helpers = struct {
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
            try writeVarintHeader(w, 3, p.len); // 3 == blob
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
};
