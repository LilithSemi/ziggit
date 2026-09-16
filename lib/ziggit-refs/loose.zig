//! The on-disk shape of one loose ref, and the lock-file-then-rename dance
//! every write in `ziggit-refs` goes through.
//!
//! A ref name doubles as its path under `git_dir`: "refs/heads/main" names
//! the file `<git_dir>/refs/heads/main`. A loose ref file holds either a
//! full object id or a "ref: <name>" line naming another ref; git writes
//! one trailing newline but reads either trailing whitespace or none.

const std = @import("std");
const Allocator = std.mem.Allocator;
const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;

/// What a loose ref file's single line names.
pub const Target = union(enum) {
    oid: Oid,
    /// Owned, freed by the caller. `read` dupes this out of the file
    /// content it frees before returning, so it never outlives the read.
    symbolic: []const u8,
};

pub const ReadError = error{ CorruptRefFile, IoFailed } || Allocator.Error;

/// Longest loose ref file this reads. A well formed file is a few dozen
/// bytes; this is a defensive ceiling against a corrupt or hostile one, not
/// a spec limit.
const max_loose_ref_file_len: std.Io.Limit = .limited(4096);

/// Reads the loose ref file `<dir>/<name>`, if it exists. Returns null when
/// there is no such file, so a caller can fall back to `packed-refs`: a
/// missing loose file is not corruption, only a name this module has
/// nothing loose to say about. `name` naming a directory, such as
/// "refs/remotes/origin" when that remote has any branches, returns null
/// the same way: a directory is not a loose ref file either, and a caller
/// trying `name` as one candidate among several must be free to move on to
/// the next.
pub fn read(gpa: Allocator, dir: std.Io.Dir, io: std.Io, name: []const u8, format: Format) ReadError!?Target {
    const content = dir.readFileAlloc(io, name, gpa, max_loose_ref_file_len) catch |err| {
        if (err == error.FileNotFound or err == error.IsDir) return null;
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.IoFailed;
    };
    defer gpa.free(content);

    const trimmed = std.mem.trimEnd(u8, content, " \t\r\n");
    if (std.mem.startsWith(u8, trimmed, "ref: ")) {
        const target_name = std.mem.trim(u8, trimmed["ref: ".len..], " \t");
        if (target_name.len == 0) return error.CorruptRefFile;
        return .{ .symbolic = try gpa.dupe(u8, target_name) };
    }

    const oid = Oid.parse(format, trimmed) catch return error.CorruptRefFile;
    return .{ .oid = oid };
}

pub const LockError = error{ LockContended, IoFailed } || Allocator.Error;
pub const CommitError = error{IoFailed} || Allocator.Error;
pub const WriteError = LockError || CommitError;

/// The lock file path for ref `name`: "<name>.lock". Caller-owned, freed by
/// the caller.
pub fn lockPath(gpa: Allocator, name: []const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{s}.lock", .{name});
}

/// Creates `lock_path` in `dir`, exclusively, creating its parent
/// directories first if needed. A lock file that already exists is
/// `error.LockContended`; this never breaks, removes, or waits on someone
/// else's lock, since guessing wrong destroys their work.
pub fn acquireLock(dir: std.Io.Dir, io: std.Io, lock_path: []const u8) LockError!void {
    if (parentOf(lock_path)) |parent| {
        dir.createDirPath(io, parent) catch return error.IoFailed;
    }
    dir.writeFile(io, .{
        .sub_path = lock_path,
        .data = "",
        .flags = .{ .exclusive = true },
    }) catch |err| {
        if (err == error.PathAlreadyExists) return error.LockContended;
        return error.IoFailed;
    };
}

/// Removes a lock file this call created. Never call this on a lock file
/// found already held; that one belongs to someone else.
///
/// Returns `true` when the lock file could not be removed and is still on
/// disk, `false` once it is gone. `releaseLock` cannot retry and has no
/// diagnostic channel of its own, so the caller decides what a stuck
/// release means, for example counting it on a `Store` and reporting it
/// through a `Diagnostic`.
pub fn releaseLock(dir: std.Io.Dir, io: std.Io, lock_path: []const u8) bool {
    dir.deleteFile(io, lock_path) catch |err| switch (err) {
        // The file is already gone. Whether this is a second release of
        // the same lock or another actor already cleaned up, the outcome
        // this function exists for, no lock file left behind, already
        // holds. Not a fault.
        error.FileNotFound => return false,

        // Every other error leaves the lock file in place. The next
        // `acquireLock` on this name reports `LockContended` instead of
        // silently overwriting anyone, so nothing is corrupted, but a
        // human has to clear the stuck file by hand.
        error.AccessDenied,
        error.PermissionDenied,
        error.FileBusy,
        error.FileSystem,
        error.IsDir,
        error.SymLinkLoop,
        error.NotDir,
        error.SystemResources,
        error.ReadOnlyFileSystem,
        error.NetworkNotFound,
        error.NameTooLong,
        error.BadPathName,
        error.Canceled,
        error.Unexpected,
        => return true,
    };
    return false;
}

/// Writes `content` into the already-created `lock_path`, then renames it
/// onto `name`, replacing whatever was there. The caller must have created
/// `lock_path` with `acquireLock` first; this does not check.
pub fn commitLock(dir: std.Io.Dir, io: std.Io, lock_path: []const u8, name: []const u8, content: []const u8) CommitError!void {
    dir.writeFile(io, .{ .sub_path = lock_path, .data = content, .flags = .{} }) catch return error.IoFailed;
    dir.rename(lock_path, dir, name, io) catch return error.IoFailed;
}

/// `acquireLock`, `commitLock`, then `releaseLock` on failure: the whole
/// dance for a caller with no compare-and-swap check to run in between.
/// `Store.update` does not use this; it needs to check the old value after
/// taking the lock and before writing, which this collapses away.
///
/// `stuck_lock_releases` is incremented when the cleanup `releaseLock` on
/// a `commitLock` failure could not remove the lock file. Owned by the
/// caller, typically a field on the `Store` doing the call, so two callers
/// never share one count.
pub fn writeAtomic(gpa: Allocator, dir: std.Io.Dir, io: std.Io, name: []const u8, content: []const u8, stuck_lock_releases: *usize) WriteError!void {
    const lock_path = try lockPath(gpa, name);
    defer gpa.free(lock_path);
    try acquireLock(dir, io, lock_path);
    errdefer if (releaseLock(dir, io, lock_path)) {
        stuck_lock_releases.* += 1;
    };
    try commitLock(dir, io, lock_path, name, content);
}

/// The parent directory component of a "/"-separated path, or null when
/// `path_str` has none. Shared by every module in `ziggit-refs` that must
/// create a ref or reflog file's parent directories before writing it.
pub fn parentOf(path_str: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path_str, '/') orelse return null;
    return path_str[0..slash];
}

// expected

test "read parses a loose ref file holding a bare object id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "HEAD", .data = "333333333333333333333333333333333333333c\n" });

    const target = (try read(std.testing.allocator, tmp.dir, std.testing.io, "HEAD", .sha1)).?;
    try std.testing.expectEqual(Format.sha1, @as(Format, target.oid));
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("333333333333333333333333333333333333333c", target.oid.toHex(&buf));
}

test "read parses a loose ref file holding a symref" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "HEAD", .data = "ref: refs/heads/main\n" });

    const target = (try read(std.testing.allocator, tmp.dir, std.testing.io, "HEAD", .sha1)).?;
    try std.testing.expectEqualStrings("refs/heads/main", target.symbolic);
    std.testing.allocator.free(target.symbolic);
}

test "read returns null for a name with no loose file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expect((try read(std.testing.allocator, tmp.dir, std.testing.io, "refs/heads/missing", .sha1)) == null);
}

test "writeAtomic then read round trips" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stuck_lock_releases: usize = 0;
    try writeAtomic(std.testing.allocator, tmp.dir, std.testing.io, "refs/heads/main", "333333333333333333333333333333333333333c\n", &stuck_lock_releases);

    const target = (try read(std.testing.allocator, tmp.dir, std.testing.io, "refs/heads/main", .sha1)).?;
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("333333333333333333333333333333333333333c", target.oid.toHex(&buf));
}

// suspicious

test "a loose ref file with trailing whitespace still parses" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "HEAD", .data = "333333333333333333333333333333333333333c \n\n" });

    const target = (try read(std.testing.allocator, tmp.dir, std.testing.io, "HEAD", .sha1)).?;
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("333333333333333333333333333333333333333c", target.oid.toHex(&buf));
}

test "a loose ref file with no trailing newline still parses" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "HEAD", .data = "333333333333333333333333333333333333333c" });

    const target = (try read(std.testing.allocator, tmp.dir, std.testing.io, "HEAD", .sha1)).?;
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("333333333333333333333333333333333333333c", target.oid.toHex(&buf));
}

test "read returns null for a name that is a directory, not a file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "refs/remotes/origin");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "refs/remotes/origin/main", .data = "333333333333333333333333333333333333333c\n" });

    try std.testing.expect((try read(std.testing.allocator, tmp.dir, std.testing.io, "refs/remotes/origin", .sha1)) == null);
}

test "read reports a malformed loose ref file as CorruptRefFile" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "HEAD", .data = "not an oid\n" });
    try std.testing.expectError(error.CorruptRefFile, read(std.testing.allocator, tmp.dir, std.testing.io, "HEAD", .sha1));
}

test "acquireLock reports LockContended for a lock file that already exists, and does not remove it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "refs/heads");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "refs/heads/main.lock", .data = "leftover from a crashed process" });

    try std.testing.expectError(error.LockContended, acquireLock(tmp.dir, std.testing.io, "refs/heads/main.lock"));

    const content = try tmp.dir.readFileAlloc(std.testing.io, "refs/heads/main.lock", std.testing.allocator, .limited(256));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("leftover from a crashed process", content);
}

test "releaseLock on an already-gone lock file does not report a stuck release" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expect(!releaseLock(tmp.dir, std.testing.io, "refs/heads/main.lock"));
}

test "releaseLock reports a stuck release when the delete fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A directory at the lock path makes `deleteFile` report `error.IsDir`
    // rather than removing anything, which exercises an arm of the
    // exhaustive switch other than the FileNotFound one.
    try tmp.dir.createDirPath(std.testing.io, "refs/heads/main.lock");

    try std.testing.expect(releaseLock(tmp.dir, std.testing.io, "refs/heads/main.lock"));
}
