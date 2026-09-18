//! Writing one tree into a working directory.
//!
//! Content filters -- line-ending translation, smudge filters,
//! `.gitattributes` -- are never applied, and there is no `Strategy` field
//! that turns them on. One consumer of this library hashes the raw
//! committed blob bytes to produce a content hash for a build input; a
//! filter that rewrote a byte on the way to disk would silently change
//! that hash into a wrong one. A blob's bytes land on disk exactly as
//! committed, always.
//!
//! A tree entry name is untrusted input: a tree can come from a remote
//! server, or from a repository someone else wrote. `checkoutTree` rejects,
//! before the name is ever joined to a path, any entry name that is empty,
//! is `.` or `..`, contains a `/` or a `\`, or is itself an absolute path.
//! Those are the shapes that let one entry name escape `worktree` instead
//! of naming a single path component inside it; letting one through is how
//! a checkout writes outside the repository. It also rejects an entry
//! named exactly `reserved_tmp_name`: git allows that name as an ordinary
//! path component, but this module reserves it for its own in-progress
//! write, and a tree that named it would otherwise let one entry's write
//! silently clobber a sibling's already-finished one.
//!
//! `Strategy` mirrors three independent permissions, each widening what an
//! otherwise conservative checkout is allowed to touch. A default
//! `Strategy{}` already populates a worktree that has nothing in it: only
//! `recreate_missing` starts `true`.
//!   - `force`: a destination that already exists as the same kind of
//!     thing the tree wants there (a file where a file is wanted, a
//!     symlink where a symlink is wanted) is left untouched unless this is
//!     set, so a local edit is never silently discarded.
//!   - `recreate_missing`: a destination that is not there at all, or that
//!     is occupied by the *wrong* kind of thing (a plain file where the
//!     tree wants a directory, say), is left alone unless this or `force`
//!     is set. `checkoutTree` has only the one tree it was asked to write,
//!     never a baseline to diff against, so it cannot tell "never checked
//!     out" apart from "was checked out, then deleted"; both look like a
//!     missing destination, and both need this flag. It defaults to
//!     `true`, so a plain checkout of a blob-bearing tree into a fresh
//!     worktree needs no flag set at all; a caller who wants checkout to
//!     write nothing at all sets both this and `force` to `false`.
//!   - `remove_untracked`: after every entry above is handled, delete
//!     anything found in a directory this walk visited that no entry of
//!     the tree at that level named, except an entry named `.git`. A tree
//!     never names its own repository, so a `.git` found at any depth is
//!     the checkout's own repository or a nested one, never untracked
//!     content this flag is for.
//! A directory a tree entry wants -- a subtree or a gitlink -- is
//! scaffolding, not content: an absent one is always created, with no flag
//! needed, the same as `mkdir -p` would, and an existing one of the right
//! kind is always descended into. Neither has anything of the caller's to
//! protect; only a file's or a symlink's own bytes do, and only a
//! directory occupied by the *wrong* kind of thing is a destructive
//! replacement `force` or `recreate_missing` must license.
//!
//! Two things this file does not solve, and should not be read as having
//! overlooked:
//!   - A tree naming two entries that differ only by case writes both, in
//!     whatever order the tree lists them; on a case-insensitive
//!     filesystem the second write silently wins over the first. Detecting
//!     that needs knowing the target filesystem's own case sensitivity,
//!     which nothing here asks it.
//!   - A symlink this module writes can point anywhere, including outside
//!     `worktree`. If a later entry's path walks through that symlink,
//!     this module follows it like any other directory component, the
//!     same as every filesystem call above it would. Refusing that needs
//!     resolving every path component against the live filesystem instead
//!     of trusting `worktree`'s own directory handles, which this module
//!     does not do.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Oid = oid_mod.Oid;
const Format = oid_mod.Format;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;
const ObjectKind = core_mod.ObjectKind;

const object_mod = @import("ziggit-object");
const Tree = object_mod.Tree;

const odb_mod = @import("ziggit-odb");
const Odb = odb_mod.Odb;

const index_mod = @import("ziggit-index");
const Index = index_mod.Index;

pub const Strategy = struct {
    force: bool = false,
    recreate_missing: bool = true,
    remove_untracked: bool = false,
    write_index: bool = false,
};

pub const Error = error{ PathEscapesWorktree, NameReservedForCheckout, NameReservedForRepository, NameTooLong, IoFailed } || Odb.Error || Allocator.Error || index_mod.Error;

/// Writes the tree at `tree_oid` into `worktree`.
///
/// When `strategy.write_index` is false (the default), this function writes
/// no index. After a checkout, running `git status` in the resulting worktree
/// shows every file as untracked.
///
/// When `strategy.write_index` is true, this function builds and writes an
/// index to `git_dir/index` after checkout completes, recording each file's
/// oid, mode and stat block. After a checkout with this option, the worktree
/// and index are in sync: `git status` shows nothing to commit.
///
/// Content filters are NOT applied and there is no option to enable them. A
/// caller hashes the raw committed blobs, so gitattributes or autocrlf
/// rewriting content on the way out would change that hash.
pub fn checkoutTree(
    gpa: Allocator,
    io: std.Io,
    odb: *Odb,
    worktree: std.Io.Dir,
    git_dir: std.Io.Dir,
    tree_oid: Oid,
    strategy: Strategy,
    diag: ?*?Diagnostic,
) Error!void {
    try checkoutInto(gpa, io, odb, worktree, git_dir, tree_oid, strategy, diag);
}

/// Allocation budget for reading one tree object whole. `Odb.readAlloc`
/// allocates this many bytes up front, before it knows the object's real
/// size, so this is also the fixed cost every `checkoutInto` call pays per
/// directory it visits, no matter how few entries that directory holds.
/// One megabyte, matching the ceiling `ziggit-revwalk` and `ziggit-fetch`
/// already use for a commit object, comfortably holds tens of thousands of
/// entries; a hostile or corrupt tree past it is refused, not read.
const max_tree_object_len: usize = 1 << 20;

/// Allocation budget for one symlink's target text. Far more than any real
/// filesystem path ever needs; a blob this large named by a symlink entry
/// is refused, not read.
const max_symlink_target_len: usize = 1 << 12;

/// The name a tree entry is never allowed to use: `checkoutInto` reserves
/// it for its own in-progress write, one entry at a time, inside whatever
/// directory it is currently visiting. `validateEntryName` refuses any
/// entry named exactly this, before any write happens, so a sibling entry
/// can never be mistaken for -- or clobber -- this module's own temp file.
///
/// This is not the name that actually lands on disk; see `tmp_name_prefix`
/// just below for why one more, per-call, piece is appended first.
const reserved_tmp_name = ".ziggit-checkout.tmp";

/// `checkoutBlob`'s real, on-disk temp file name is this prefix plus one
/// call's own nonce (see `checkoutInto`), so two calls -- nested, or
/// racing from separate `checkoutTree` invocations sharing one worktree --
/// never pick the same name even though `reserved_tmp_name` alone is
/// refused as an entry name for all of them alike.
const tmp_name_prefix = reserved_tmp_name ++ ".";

fn checkoutInto(
    gpa: Allocator,
    io: std.Io,
    odb: *Odb,
    worktree: std.Io.Dir,
    git_dir: std.Io.Dir,
    tree_oid: Oid,
    strategy: Strategy,
    diag: ?*?Diagnostic,
) Error!void {
    const bytes = try odb.readAlloc(gpa, tree_oid, max_tree_object_len, diag);
    defer gpa.free(bytes);

    var tree = Tree.parse(gpa, odb.format, bytes) catch |err| switch (err) {
        error.CorruptTree => {
            reportCorrupt(diag, gpa, "tree object is corrupt");
            return error.CorruptObject;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer tree.deinit(gpa);

    // `call_marker` exists only so its address can be taken: two live
    // calls, nested or concurrent, never share a stack address, so the
    // name below is unique to this one call without an environment
    // variable, a process id, or a global counter, none of which this
    // project allows. Same technique as `receivePack` in
    // `lib/ziggit-fetch/Fetcher.zig`.
    var call_marker: u8 = 0;
    const nonce = @intFromPtr(&call_marker);
    const tmp_name = std.fmt.allocPrint(gpa, "{s}{x}", .{ tmp_name_prefix, nonce }) catch return error.OutOfMemory;
    defer gpa.free(tmp_name);

    for (tree.entries) |entry| {
        try validateEntryName(entry.name);
        switch (entry.mode) {
            .tree => try checkoutSubtree(gpa, io, odb, git_dir, worktree, entry, strategy, diag),
            .gitlink => try checkoutGitlink(io, worktree, entry, strategy),
            .blob, .blob_executable => try checkoutBlob(gpa, io, odb, worktree, entry, strategy, diag, tmp_name),
            .symlink => try checkoutSymlink(gpa, io, odb, worktree, entry, strategy, diag),
        }
    }

    if (strategy.remove_untracked) try removeUntracked(gpa, io, worktree, tree);

    if (strategy.write_index) {
        var index = try index_mod.stageWorktree(gpa, io, worktree, odb, odb.format);
        defer index.deinit();
        try index_mod.write(index, io, git_dir, odb.format);
    }
}

/// A path is absolute if it starts with the POSIX root separator `/`, or
/// with a drive letter such as `C:` in the Windows style. This project
/// only ever checks out onto a POSIX filesystem today, but the second
/// check costs nothing and keeps the guard from growing a silent gap if
/// that ever changes.
fn isAbsolutePath(name: []const u8) bool {
    if (name.len > 0 and name[0] == '/') return true;
    if (name.len >= 2 and std.ascii.isAlphabetic(name[0]) and name[1] == ':') return true;
    return false;
}

/// Recognises zero-width and ignorable characters that filesystems treat as
/// invisible when comparing names. Prevents hiding `.git` behind invisible
/// characters.
///
/// Covers: U+200B, U+200C, U+200D, U+200E, U+200F, U+202A-U+202E, U+2060-U+2064,
/// U+034F, U+180E, U+FEFF, U+FE00-U+FE0F.
fn isZeroWidthChar(byte: u8, remaining: []const u8) usize {
    if (remaining.len < 3) return 0;

    // U+200B through U+200F and U+202A through U+202E (E2 80 8B-8F and AA-AE)
    if (byte == 0xE2 and remaining[1] == 0x80) {
        const third = remaining[2];
        if ((third >= 0x8B and third <= 0x8F) or (third >= 0xAA and third <= 0xAE)) {
            return 3;
        }
    }

    // U+2060-U+2064 (E2 81 A0-A4)
    if (byte == 0xE2 and remaining[1] == 0x81) {
        const third = remaining[2];
        if (third >= 0xA0 and third <= 0xA4) {
            return 3;
        }
    }

    // U+034F (CD 8F)
    if (byte == 0xCD and remaining[1] == 0x8F) {
        return 2;
    }

    // U+180E (E1 A0 8E)
    if (byte == 0xE1 and remaining[1] == 0xA0 and remaining[2] == 0x8E) {
        return 3;
    }

    // U+FEFF (EF BB BF)
    if (byte == 0xEF and remaining[1] == 0xBB and remaining[2] == 0xBF) {
        return 3;
    }

    // U+FE00-U+FE0F (EF B8 80-8F)
    if (byte == 0xEF and remaining[1] == 0xB8) {
        const third = remaining[2];
        if (third >= 0x80 and third <= 0x8F) {
            return 3;
        }
    }

    return 0;
}

/// Normalises an entry name for comparison against reserved names. Returns
/// the number of bytes in the normalised form, or an error if the name is
/// too long to normalise.
///
/// Normalisation steps, in order:
/// 1. Strips every ignorable code point (zero-width characters and similar)
/// 2. Strips NTFS alternate data stream suffix (everything from first `:`)
/// 3. Strips trailing dots and spaces, repeatedly
/// 4. Lowercases ASCII
///
/// The result is written to a fixed-size output buffer. If the input name
/// is longer than the buffer, an error is returned rather than truncating,
/// since truncation is a bypass (a very long name ending in `.git` must not
/// become `.git` by being cut short).
fn normaliseEntryName(name: []const u8, out: []u8) Error!usize {
    if (name.len == 0) return 0;

    var out_idx: usize = 0;
    var in_idx: usize = 0;

    // Step 1 & 2: Strip ignorable code points and NTFS alternate data stream.
    while (in_idx < name.len) {
        const byte = name[in_idx];

        // Check for ignorable code point.
        const zw_len = isZeroWidthChar(byte, name[in_idx..]);
        if (zw_len > 0) {
            in_idx += zw_len;
            continue;
        }

        // Strip everything from `:` onward (NTFS alternate data stream).
        if (byte == ':') {
            break;
        }

        // Copy regular byte.
        if (out_idx >= out.len) return error.NameTooLong;
        out[out_idx] = byte;
        out_idx += 1;
        in_idx += 1;
    }

    // Step 3: Strip trailing dots and spaces, repeatedly, until none remain.
    while (out_idx > 0 and (out[out_idx - 1] == '.' or out[out_idx - 1] == ' ')) {
        out_idx -= 1;
    }

    // Step 4: Lowercase ASCII.
    for (out[0..out_idx]) |*byte| {
        byte.* = std.ascii.toLower(byte.*);
    }

    return out_idx;
}

/// A tree entry name is a single path component by definition. Anything
/// else -- empty, `.` or `..`, a name carrying its own separator, an
/// absolute path, or the name this module reserves for its own temp file
/// -- is corrupt or hostile data, and is rejected here, before it is ever
/// joined to a path. Names that refer to the repository directory (`.git`
/// in any case variant, or the NTFS short name) or attempts to hide it
/// using zero-width characters are also rejected.
fn validateEntryName(name: []const u8) Error!void {
    if (name.len == 0) return error.PathEscapesWorktree;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.PathEscapesWorktree;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return error.PathEscapesWorktree;
    if (isAbsolutePath(name)) return error.PathEscapesWorktree;
    if (std.mem.eql(u8, name, reserved_tmp_name)) return error.NameReservedForCheckout;

    // Normalise the name and check against reserved names.
    var norm_buf: [256]u8 = undefined;
    const norm_len = try normaliseEntryName(name, &norm_buf);
    const normalised = norm_buf[0..norm_len];

    // Reject if normalised form is `.git`.
    if (core_mod.isDotGitName(normalised)) return error.NameReservedForRepository;

    // Reject if normalised form is `git~` followed by one or more digits.
    if (normalised.len >= 5 and std.mem.startsWith(u8, normalised, "git~")) {
        const suffix = normalised[4..];
        var all_digits = true;
        for (suffix) |byte| {
            if (!std.ascii.isDigit(byte)) {
                all_digits = false;
                break;
            }
        }
        if (all_digits) return error.NameReservedForRepository;
    }
}

const ExistingKind = enum { absent, file, directory, symlink, other };

fn statExisting(dir: std.Io.Dir, io: std.Io, name: []const u8) Error!ExistingKind {
    const st = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .absent,
        else => return error.IoFailed,
    };
    return switch (st.kind) {
        .directory => .directory,
        .sym_link => .symlink,
        .file => .file,
        else => .other,
    };
}

/// Removes whatever currently occupies `name`, whole, so a fresh entry can
/// be written in its place.
fn clearExisting(dir: std.Io.Dir, io: std.Io, name: []const u8, kind: ExistingKind) Error!void {
    switch (kind) {
        .absent => {},
        .directory => dir.deleteTree(io, name) catch return error.IoFailed,
        .file, .symlink, .other => dir.deleteFile(io, name) catch return error.IoFailed,
    }
}

const WantedKind = enum { file, symlink, directory };

fn matchesKind(existing: ExistingKind, wanted: WantedKind) bool {
    return switch (wanted) {
        .file => existing == .file,
        .symlink => existing == .symlink,
        .directory => existing == .directory,
    };
}

const Disposition = enum { skip, proceed };

/// Decides whether an entry gets written, given what (if anything) already
/// occupies its path. See the module doc comment for what each `Strategy`
/// field means here.
fn decide(existing: ExistingKind, wanted: WantedKind, strategy: Strategy) Disposition {
    if (existing == .absent) {
        // A directory that is not there yet is scaffolding, not content:
        // there is nothing of the caller's to protect by refusing to
        // create it, so this needs no flag, the same as `mkdir -p` would.
        if (wanted == .directory) return .proceed;
        return if (strategy.recreate_missing or strategy.force) .proceed else .skip;
    }
    if (matchesKind(existing, wanted)) {
        // An existing directory holds no content of its own to protect;
        // only its children do, each against its own entry.
        if (wanted == .directory) return .proceed;
        return if (strategy.force) .proceed else .skip;
    }
    return if (strategy.force or strategy.recreate_missing) .proceed else .skip;
}

fn reportCorrupt(diag: ?*?Diagnostic, gpa: Allocator, detail: []const u8) void {
    if (!core_mod.wants(diag)) return;
    const dup = gpa.dupe(u8, detail) catch null;
    core_mod.report(diag, gpa, .{ .kind = .corrupt_object, .path = null, .detail = dup });
}

fn checkoutBlob(gpa: Allocator, io: std.Io, odb: *Odb, dir: std.Io.Dir, entry: Tree.Entry, strategy: Strategy, diag: ?*?Diagnostic, tmp_name: []const u8) Error!void {
    const existing = try statExisting(dir, io, entry.name);
    if (decide(existing, .file, strategy) == .skip) return;
    if (existing != .absent) try clearExisting(dir, io, entry.name, existing);

    {
        var file = dir.createFile(io, tmp_name, .{}) catch return error.IoFailed;
        errdefer dir.deleteFile(io, tmp_name) catch {};
        defer file.close(io);

        var write_buf: [8192]u8 = undefined;
        var fw = file.writer(io, &write_buf);
        const kind = try odb.read(entry.oid, &fw.interface, diag);
        if (kind != .blob) {
            reportCorrupt(diag, gpa, "tree entry names a blob but the object is not one");
            return error.CorruptObject;
        }
        fw.end() catch return error.IoFailed;

        if (entry.mode == .blob_executable) {
            file.setPermissions(io, @enumFromInt(0o755)) catch return error.IoFailed;
        }
    }

    // `errdefer` above only unwinds while control is still inside that
    // block; by the time `rename` runs, the block has already exited
    // normally, so a failed rename needs its own explicit cleanup to
    // avoid leaving `tmp_name` behind.
    dir.rename(tmp_name, dir, entry.name, io) catch {
        dir.deleteFile(io, tmp_name) catch {};
        return error.IoFailed;
    };
}

/// Mirrors `Odb.readAlloc`'s own bound-then-read shape, but keeps the
/// `ObjectKind` `readAlloc` itself discards: a symlink's target is stored
/// as an ordinary blob, and a tree entry claiming `.symlink` for something
/// that is not one is corrupt data, worth telling apart from a merely
/// oversized object.
fn readSmallObject(gpa: Allocator, odb: *Odb, oid: Oid, max_size: usize, diag: ?*?Diagnostic) Error!struct { kind: ObjectKind, bytes: []u8 } {
    const buf = try gpa.alloc(u8, max_size);
    var w: std.Io.Writer = .fixed(buf);
    if (odb.read(oid, &w, diag)) |kind| {
        const written = w.buffered().len;
        return .{ .kind = kind, .bytes = try gpa.realloc(buf, written) };
    } else |err| {
        gpa.free(buf);
        const info = odb.stat(oid) catch |stat_err| return stat_err;
        if (info.size > max_size) return error.ObjectTooLarge;
        return err;
    }
}

fn checkoutSymlink(gpa: Allocator, io: std.Io, odb: *Odb, dir: std.Io.Dir, entry: Tree.Entry, strategy: Strategy, diag: ?*?Diagnostic) Error!void {
    const existing = try statExisting(dir, io, entry.name);
    if (decide(existing, .symlink, strategy) == .skip) return;
    if (existing != .absent) try clearExisting(dir, io, entry.name, existing);

    const obj = try readSmallObject(gpa, odb, entry.oid, max_symlink_target_len, diag);
    defer gpa.free(obj.bytes);
    if (obj.kind != .blob) {
        reportCorrupt(diag, gpa, "tree entry names a symlink but the object is not a blob");
        return error.CorruptObject;
    }

    dir.symLink(io, obj.bytes, entry.name, .{}) catch return error.IoFailed;
}

fn checkoutSubtree(gpa: Allocator, io: std.Io, odb: *Odb, git_dir: std.Io.Dir, dir: std.Io.Dir, entry: Tree.Entry, strategy: Strategy, diag: ?*?Diagnostic) Error!void {
    const existing = try statExisting(dir, io, entry.name);
    if (decide(existing, .directory, strategy) == .skip) return;
    if (existing != .absent and existing != .directory) try clearExisting(dir, io, entry.name, existing);
    if (existing != .directory) {
        dir.createDir(io, entry.name, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return error.IoFailed,
        };
    }

    var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch return error.IoFailed;
    defer sub.close(io);

    try checkoutInto(gpa, io, odb, sub, git_dir, entry.oid, strategy, diag);
}

/// A gitlink names a commit in another repository, one this `Odb` has
/// never heard of and never reads: the empty directory left here is all
/// `checkoutTree` ever does with one. `ziggit-submodule`, in a later task,
/// decides whether to populate it.
fn checkoutGitlink(io: std.Io, dir: std.Io.Dir, entry: Tree.Entry, strategy: Strategy) Error!void {
    const existing = try statExisting(dir, io, entry.name);
    if (decide(existing, .directory, strategy) == .skip) return;
    if (existing != .absent and existing != .directory) try clearExisting(dir, io, entry.name, existing);
    if (existing != .directory) {
        dir.createDir(io, entry.name, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return error.IoFailed,
        };
    }
}

/// The name `removeUntracked` never deletes, at any depth it is called at.
///
/// A tree never names its own repository directory, so a literal reading of
/// "delete whatever the tree does not name" would delete it too. At the top
/// of a worktree that is the checkout's own `.git`; a linked worktree keeps
/// that as a file rather than a directory, so the check is on the name, not
/// the kind. Below the top, a directory named `.git` is a nested
/// repository's or a submodule's own, and is exactly as destructive to
/// remove; git itself refuses to descend into a nested repository during
/// `clean` for the same reason. `removeUntracked` runs once per directory
/// `checkoutInto` visits, at every depth, so excluding this name here
/// excludes it at every depth alike, with no separate top-level case to
/// maintain.
const protected_repo_name = ".git";

/// Deletes every entry of `dir` that no entry of `tree` names, except
/// `protected_repo_name`. Names are collected before anything is deleted, so
/// removing an entry never disturbs the directory iteration that found it.
fn removeUntracked(gpa: Allocator, io: std.Io, dir: std.Io.Dir, tree: Tree) Error!void {
    var doomed: std.ArrayList([]u8) = .empty;
    defer {
        for (doomed.items) |name| gpa.free(name);
        doomed.deinit(gpa);
    }

    var it = dir.iterate();
    while (it.next(io) catch return error.IoFailed) |item| {
        if (std.mem.eql(u8, item.name, protected_repo_name)) continue;
        if (tree.find(item.name) != null) continue;
        const owned = try gpa.dupe(u8, item.name);
        errdefer gpa.free(owned);
        try doomed.append(gpa, owned);
    }

    for (doomed.items) |name| {
        const kind = try statExisting(dir, io, name);
        switch (kind) {
            .absent => {},
            .directory => dir.deleteTree(io, name) catch return error.IoFailed,
            .file, .symlink, .other => dir.deleteFile(io, name) catch return error.IoFailed,
        }
    }
}

// Test helpers: a bare `Odb` over its own "objects" directory, and a
// separate "worktree" directory, both under one temp dir, matching how a
// real repository keeps its objects apart from what a checkout writes.
//
// `Odb.init` keeps and reuses the exact directory handle it is given for
// as long as the `Odb` lives; closing that handle out from under it while
// still in use, the way returning it from a helper and closing it there
// would, invalidates every read and write that comes after. `TestRepo`
// owns both handles for the whole test and closes them only once, in
// `deinit`.
const TestRepo = struct {
    objects_dir: std.Io.Dir,
    worktree: std.Io.Dir,
    odb: Odb,

    fn open(gpa: Allocator, io: std.Io, dir: std.Io.Dir) !TestRepo {
        try dir.createDirPath(io, "objects");
        var objects_dir = try dir.openDir(io, "objects", .{ .iterate = true });
        errdefer objects_dir.close(io);
        const odb = try Odb.init(gpa, io, objects_dir, .sha1, .{});

        try dir.createDirPath(io, "worktree");
        const worktree = try dir.openDir(io, "worktree", .{ .iterate = true });

        return .{ .objects_dir = objects_dir, .worktree = worktree, .odb = odb };
    }

    fn deinit(self: *TestRepo, io: std.Io) void {
        self.odb.deinit();
        self.objects_dir.close(io);
        self.worktree.close(io);
    }
};

/// Sorts `entries`, serializes them, and writes the result as a tree
/// object. `entries` is mutated in place by the sort.
fn writeTree(gpa: Allocator, odb: *Odb, entries: []Tree.Entry) !Oid {
    Tree.sortEntries(entries);
    var aw = try std.Io.Writer.Allocating.initCapacity(gpa, 256);
    defer aw.deinit();
    const t: Tree = .{ .entries = entries };
    try t.write(&aw.writer);
    return odb.write(.tree, aw.writer.buffered(), null);
}

const populate: Strategy = .{ .recreate_missing = true };

fn readAllAlloc(gpa: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8) ![]u8 {
    var file = try dir.openFile(io, sub_path, .{});
    defer file.close(io);
    var buf: [8192]u8 = undefined;
    var freader = file.reader(io, &buf);
    return freader.interface.allocRemaining(gpa, .unlimited) catch |err| switch (err) {
        error.ReadFailed => return freader.err.?,
        error.StreamTooLong => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn expectPathEscapes(gpa: Allocator, io: std.Io, odb: *Odb, worktree: std.Io.Dir, name: []const u8) !void {
    const bogus_oid = try Oid.parse(.sha1, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    var entries = [_]Tree.Entry{.{ .mode = .blob, .name = name, .oid = bogus_oid }};
    const tree_oid = try writeTree(gpa, odb, &entries);
    try std.testing.expectError(error.PathEscapesWorktree, checkoutTree(gpa, io, odb, worktree, worktree, tree_oid, populate, null));
}

// expected

test "checkoutTree writes a blob with its exact committed bytes" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try TestRepo.open(gpa, io, tmp.dir);
    defer repo.deinit(io);

    const blob_oid = try repo.odb.write(.blob, "hello\n", null);
    var entries = [_]Tree.Entry{.{ .mode = .blob, .name = "greeting.txt", .oid = blob_oid }};
    const tree_oid = try writeTree(gpa, &repo.odb, &entries);

    try checkoutTree(gpa, io, &repo.odb, repo.worktree, repo.worktree, tree_oid, populate, null);

    const bytes = try readAllAlloc(gpa, io, repo.worktree, "greeting.txt");
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("hello\n", bytes);
}

test "checkoutTree creates nested directories" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try TestRepo.open(gpa, io, tmp.dir);
    defer repo.deinit(io);

    const blob_oid = try repo.odb.write(.blob, "const x = 1;\n", null);
    var inner_entries = [_]Tree.Entry{.{ .mode = .blob, .name = "main.zig", .oid = blob_oid }};
    const inner_oid = try writeTree(gpa, &repo.odb, &inner_entries);
    var outer_entries = [_]Tree.Entry{.{ .mode = .tree, .name = "src", .oid = inner_oid }};
    const outer_oid = try writeTree(gpa, &repo.odb, &outer_entries);

    try checkoutTree(gpa, io, &repo.odb, repo.worktree, repo.worktree, outer_oid, populate, null);

    const bytes = try readAllAlloc(gpa, io, repo.worktree, "src/main.zig");
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("const x = 1;\n", bytes);
}

test "checkoutTree honours the executable bit" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try TestRepo.open(gpa, io, tmp.dir);
    defer repo.deinit(io);

    const blob_oid = try repo.odb.write(.blob, "#!/bin/sh\necho hi\n", null);
    var entries = [_]Tree.Entry{.{ .mode = .blob_executable, .name = "run.sh", .oid = blob_oid }};
    const tree_oid = try writeTree(gpa, &repo.odb, &entries);

    try checkoutTree(gpa, io, &repo.odb, repo.worktree, repo.worktree, tree_oid, populate, null);

    const st = try repo.worktree.statFile(io, "run.sh", .{});
    try std.testing.expect(@intFromEnum(st.permissions) & 0o111 != 0);
}

test "checkoutTree writes a symlink as a symlink" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try TestRepo.open(gpa, io, tmp.dir);
    defer repo.deinit(io);

    const blob_oid = try repo.odb.write(.blob, "target.txt", null);
    var entries = [_]Tree.Entry{.{ .mode = .symlink, .name = "link", .oid = blob_oid }};
    const tree_oid = try writeTree(gpa, &repo.odb, &entries);

    try checkoutTree(gpa, io, &repo.odb, repo.worktree, repo.worktree, tree_oid, populate, null);

    const st = try repo.worktree.statFile(io, "link", .{ .follow_symlinks = false });
    try std.testing.expectEqual(std.Io.File.Kind.sym_link, st.kind);
    var target_buf: [64]u8 = undefined;
    const n = try repo.worktree.readLink(io, "link", &target_buf);
    try std.testing.expectEqualStrings("target.txt", target_buf[0..n]);
}

test "checkoutTree creates an empty directory for a gitlink and does not recurse" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try TestRepo.open(gpa, io, tmp.dir);
    defer repo.deinit(io);

    // The gitlink's own id names a commit in another repository, one this
    // `Odb` has never heard of. If `checkoutTree` ever tried to read it as
    // a tree, this call would fail with `error.ObjectNotFound`; success
    // here is itself the proof that it never tried.
    const nonexistent_oid = try Oid.parse(.sha1, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    var entries = [_]Tree.Entry{.{ .mode = .gitlink, .name = "vendor", .oid = nonexistent_oid }};
    const tree_oid = try writeTree(gpa, &repo.odb, &entries);

    try checkoutTree(gpa, io, &repo.odb, repo.worktree, repo.worktree, tree_oid, .{}, null);

    var sub = try repo.worktree.openDir(io, "vendor", .{ .iterate = true });
    defer sub.close(io);
    var it = sub.iterate();
    try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try it.next(io));
}

test "recreate_missing restores a file that was deleted" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try TestRepo.open(gpa, io, tmp.dir);
    defer repo.deinit(io);

    const blob_oid = try repo.odb.write(.blob, "hello\n", null);
    var entries = [_]Tree.Entry{.{ .mode = .blob, .name = "config.txt", .oid = blob_oid }};
    const tree_oid = try writeTree(gpa, &repo.odb, &entries);

    try checkoutTree(gpa, io, &repo.odb, repo.worktree, repo.worktree, tree_oid, populate, null);
    try repo.worktree.deleteFile(io, "config.txt");

    try checkoutTree(gpa, io, &repo.odb, repo.worktree, repo.worktree, tree_oid, .{ .recreate_missing = true }, null);

    const bytes = try readAllAlloc(gpa, io, repo.worktree, "config.txt");
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("hello\n", bytes);
}

test "remove_untracked deletes a file the tree does not name" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try TestRepo.open(gpa, io, tmp.dir);
    defer repo.deinit(io);

    const blob_oid = try repo.odb.write(.blob, "hello\n", null);
    var entries = [_]Tree.Entry{.{ .mode = .blob, .name = "keep.txt", .oid = blob_oid }};
    const tree_oid = try writeTree(gpa, &repo.odb, &entries);

    try checkoutTree(gpa, io, &repo.odb, repo.worktree, repo.worktree, tree_oid, populate, null);
    try repo.worktree.writeFile(io, .{ .sub_path = "extra.txt", .data = "untracked\n" });

    try checkoutTree(gpa, io, &repo.odb, repo.worktree, repo.worktree, tree_oid, .{ .remove_untracked = true }, null);

    try std.testing.expectError(error.FileNotFound, repo.worktree.statFile(io, "extra.txt", .{}));
    const bytes = try readAllAlloc(gpa, io, repo.worktree, "keep.txt");
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("hello\n", bytes);
}

test "remove_untracked never deletes .git" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try TestRepo.open(gpa, io, tmp.dir);
    defer repo.deinit(io);

    const blob_oid = try repo.odb.write(.blob, "hello\n", null);
    var entries = [_]Tree.Entry{.{ .mode = .blob, .name = "keep.txt", .oid = blob_oid }};
    const tree_oid = try writeTree(gpa, &repo.odb, &entries);

    try checkoutTree(gpa, io, &repo.odb, repo.worktree, repo.worktree, tree_oid, populate, null);

    // A real repository's own `.git`, sitting right where a top-level
    // `remove_untracked` walk would otherwise find it unnamed by any tree.
    try repo.worktree.createDirPath(io, ".git");
    try repo.worktree.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });
    try repo.worktree.writeFile(io, .{ .sub_path = "extra.txt", .data = "untracked\n" });

    try checkoutTree(gpa, io, &repo.odb, repo.worktree, repo.worktree, tree_oid, .{ .remove_untracked = true }, null);

    try std.testing.expectError(error.FileNotFound, repo.worktree.statFile(io, "extra.txt", .{}));
    const head_bytes = try readAllAlloc(gpa, io, repo.worktree, ".git/HEAD");
    defer gpa.free(head_bytes);
    try std.testing.expectEqualStrings("ref: refs/heads/main\n", head_bytes);
}

// suspicious

test "a blob with CRLF in it is written byte for byte, with no filtering" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try TestRepo.open(gpa, io, tmp.dir);
    defer repo.deinit(io);

    const crlf_content = "line one\r\nline two\r\n";
    const blob_oid = try repo.odb.write(.blob, crlf_content, null);
    var entries = [_]Tree.Entry{.{ .mode = .blob, .name = "crlf.txt", .oid = blob_oid }};
    const tree_oid = try writeTree(gpa, &repo.odb, &entries);

    try checkoutTree(gpa, io, &repo.odb, repo.worktree, repo.worktree, tree_oid, populate, null);

    const bytes = try readAllAlloc(gpa, io, repo.worktree, "crlf.txt");
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings(crlf_content, bytes);
}

test "a tree entry named .. is PathEscapesWorktree" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try TestRepo.open(gpa, io, tmp.dir);
    defer repo.deinit(io);

    try expectPathEscapes(gpa, io, &repo.odb, repo.worktree, "..");
}

test "a tree entry with an absolute path is PathEscapesWorktree" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try TestRepo.open(gpa, io, tmp.dir);
    defer repo.deinit(io);

    // Built from the sandbox's own real path, not a literal like
    // "/etc/passwd": an absolute path ignores the base `Dir` on POSIX, so
    // if `validateEntryName`'s absolute-path check ever regressed,
    // `statExisting` would stat whatever this string names. Keeping it
    // inside the temp dir keeps that regression from touching a real host
    // file.
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const worktree_abs_len = try repo.worktree.realPath(io, &path_buf);
    const sandboxed_absolute = try std.fmt.allocPrint(gpa, "{s}/should-not-be-touched", .{path_buf[0..worktree_abs_len]});
    defer gpa.free(sandboxed_absolute);

    try expectPathEscapes(gpa, io, &repo.odb, repo.worktree, sandboxed_absolute);
}

test "a tree entry containing a slash is PathEscapesWorktree" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try TestRepo.open(gpa, io, tmp.dir);
    defer repo.deinit(io);

    try expectPathEscapes(gpa, io, &repo.odb, repo.worktree, "a/b");
}

test "checkoutTree without force refuses to overwrite a modified file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try TestRepo.open(gpa, io, tmp.dir);
    defer repo.deinit(io);

    const blob_oid = try repo.odb.write(.blob, "committed\n", null);
    var entries = [_]Tree.Entry{.{ .mode = .blob, .name = "greeting.txt", .oid = blob_oid }};
    const tree_oid = try writeTree(gpa, &repo.odb, &entries);

    try repo.worktree.writeFile(io, .{ .sub_path = "greeting.txt", .data = "locally modified\n" });

    try checkoutTree(gpa, io, &repo.odb, repo.worktree, repo.worktree, tree_oid, .{}, null);

    const bytes = try readAllAlloc(gpa, io, repo.worktree, "greeting.txt");
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("locally modified\n", bytes);
}

test "a checkout that fails partway leaves no partial file at the failing path" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try TestRepo.open(gpa, io, tmp.dir);
    defer repo.deinit(io);

    // Write a genuine blob, then overwrite its on-disk bytes with a
    // different blob's compressed form: the path still names the first
    // object's id, but the bytes underneath now hash to something else.
    // `Odb.read` streams every one of those bytes into our destination's
    // temp file before it notices the mismatch at the very end, so this
    // proves a stream that got most of the way through still leaves
    // nothing at the real destination path.
    const oid = try repo.odb.write(.blob, "a" ** 4096, null);
    var aw = try std.Io.Writer.Allocating.initCapacity(gpa, 256);
    defer aw.deinit();
    _ = try object_mod.loose.write(.sha1, .blob, "b" ** 10, &aw.writer);

    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const hex = oid.toHex(&hex_buf);
    var path_buf: [Oid.max_formatted_length + 1]u8 = undefined;
    @memcpy(path_buf[0..2], hex[0..2]);
    path_buf[2] = '/';
    @memcpy(path_buf[3..][0 .. hex.len - 2], hex[2..]);
    const rel_path = path_buf[0 .. hex.len + 1];
    try repo.objects_dir.writeFile(io, .{ .sub_path = rel_path, .data = aw.writer.buffered() });

    var entries = [_]Tree.Entry{.{ .mode = .blob, .name = "will-fail.txt", .oid = oid }};
    const tree_oid = try writeTree(gpa, &repo.odb, &entries);

    try std.testing.expectError(error.CorruptObject, checkoutTree(gpa, io, &repo.odb, repo.worktree, repo.worktree, tree_oid, populate, null));

    try std.testing.expectError(error.FileNotFound, repo.worktree.statFile(io, "will-fail.txt", .{}));
    var it = repo.worktree.iterate();
    try std.testing.expectEqual(@as(?std.Io.Dir.Entry, null), try it.next(io));
}

test "a large blob streams rather than being buffered whole" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try TestRepo.open(gpa, io, tmp.dir);
    defer repo.deinit(io);

    const big_len: usize = 4 * 1024 * 1024;
    const big = try gpa.alloc(u8, big_len);
    defer gpa.free(big);
    @memset(big, 'z');
    const blob_oid = try repo.odb.write(.blob, big, null);
    var entries = [_]Tree.Entry{.{ .mode = .blob, .name = "big.bin", .oid = blob_oid }};
    const tree_oid = try writeTree(gpa, &repo.odb, &entries);

    var failing = std.testing.FailingAllocator.init(gpa, .{});
    try checkoutTree(failing.allocator(), io, &repo.odb, repo.worktree, repo.worktree, tree_oid, populate, null);

    // A whole-blob buffer would show up here as one allocation at or past
    // `big_len` (4 MiB). `checkoutInto` does pay a fixed, small cost of its
    // own reading the tree object -- `Odb.readAlloc` allocates its whole
    // `max_tree_object_len` ceiling (1 MiB) up front before it knows the
    // real, tiny size of this one-entry tree -- so the bound below is set
    // comfortably above that fixed cost and comfortably below the blob
    // itself, rather than at a fraction of `big_len`.
    try std.testing.expect(failing.allocated_bytes < 2 * 1024 * 1024);

    var out_file = try repo.worktree.openFile(io, "big.bin", .{});
    defer out_file.close(io);
    const st = try out_file.stat(io);
    try std.testing.expectEqual(@as(u64, big_len), st.size);
}

// regression

test "a tree entry with an empty name never reaches path validation, or a file write" {
    // `Tree.parse` itself already refuses an empty entry name as
    // `error.CorruptTree` -- git never writes one -- so `checkoutTree`
    // maps that to `error.CorruptObject` before `validateEntryName` ever
    // runs. `validateEntryName` still checks for an empty name on its own
    // (see below), belt and suspenders against a future, looser `Tree`.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try TestRepo.open(gpa, io, tmp.dir);
    defer repo.deinit(io);

    const bogus_oid = try Oid.parse(.sha1, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    var entries = [_]Tree.Entry{.{ .mode = .blob, .name = "", .oid = bogus_oid }};
    const tree_oid = try writeTree(gpa, &repo.odb, &entries);
    try std.testing.expectError(error.CorruptObject, checkoutTree(gpa, io, &repo.odb, repo.worktree, repo.worktree, tree_oid, populate, null));

    try std.testing.expectError(error.PathEscapesWorktree, validateEntryName(""));
}

test "a tree entry containing a backslash is PathEscapesWorktree" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try TestRepo.open(gpa, io, tmp.dir);
    defer repo.deinit(io);

    try expectPathEscapes(gpa, io, &repo.odb, repo.worktree, "a\\b");
}

test "an entry named the checkout's reserved temp name is refused" {
    try std.testing.expectError(error.NameReservedForCheckout, validateEntryName(reserved_tmp_name));
}

test "a tree entry named .git is refused" {
    try std.testing.expectError(error.NameReservedForRepository, validateEntryName(".git"));
}

test "a tree entry named .GIT is refused" {
    try std.testing.expectError(error.NameReservedForRepository, validateEntryName(".GIT"));
}

test "a tree entry named .Git is refused" {
    try std.testing.expectError(error.NameReservedForRepository, validateEntryName(".Git"));
}

test "a tree entry named git~1 is refused" {
    try std.testing.expectError(error.NameReservedForRepository, validateEntryName("git~1"));
}

test "a tree entry hiding .git behind a zero width character is refused" {
    const gpa = std.testing.allocator;
    const hidden = try std.fmt.allocPrint(gpa, ".git\u{200B}", .{});
    defer gpa.free(hidden);
    try std.testing.expectError(error.NameReservedForRepository, validateEntryName(hidden));
}

test "a tree entry named .git. is refused" {
    try std.testing.expectError(error.NameReservedForRepository, validateEntryName(".git."));
}

test "a tree entry named .git followed by a space is refused" {
    try std.testing.expectError(error.NameReservedForRepository, validateEntryName(".git "));
}

test "a tree entry named .git with several trailing dots and spaces is refused" {
    try std.testing.expectError(error.NameReservedForRepository, validateEntryName(".git. ."));
}

test "a tree entry named .git::$INDEX_ALLOCATION is refused" {
    try std.testing.expectError(error.NameReservedForRepository, validateEntryName(".git::$INDEX_ALLOCATION"));
}

test "a tree entry named .git::$DATA is refused" {
    try std.testing.expectError(error.NameReservedForRepository, validateEntryName(".git::$DATA"));
}

test "a tree entry named git~2 is refused" {
    try std.testing.expectError(error.NameReservedForRepository, validateEntryName("git~2"));
}

test "a tree entry named GIT~1 is refused" {
    try std.testing.expectError(error.NameReservedForRepository, validateEntryName("GIT~1"));
}

test "a tree entry hiding .git behind a right to left mark is refused" {
    const gpa = std.testing.allocator;
    const hidden = try std.fmt.allocPrint(gpa, ".git\u{200F}", .{});
    defer gpa.free(hidden);
    try std.testing.expectError(error.NameReservedForRepository, validateEntryName(hidden));
}

test "a tree entry name too long to normalise is refused rather than truncated" {
    // Create a name that is longer than the normalisation buffer
    const gpa = std.testing.allocator;
    const long_name = try gpa.alloc(u8, 1024);
    defer gpa.free(long_name);
    @memset(long_name, 'a');
    try std.testing.expectError(error.NameTooLong, validateEntryName(long_name));
}

test "a tree entry named .gitmodules is still allowed" {
    try validateEntryName(".gitmodules");
}

test "a tree naming the reserved temp name is refused, and no sibling is lost either way" {
    // This is the crafted tree from the collision trace: one entry named
    // exactly `reserved_tmp_name`, plus siblings on both sides of it in
    // sort order (`.` sorts low, so the reserved name would normally sort
    // before an ordinary name and after one starting with a byte below
    // '.'). Before the fix, the sibling that sorted after the reserved
    // name would reuse its temp file and silently overwrite the reserved
    // name's already-renamed content while `checkoutTree` still reported
    // success. Now the whole tree is refused the moment the walk reaches
    // the reserved name, so neither the earlier sibling's write is undone
    // nor the later sibling's ever begins.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try TestRepo.open(gpa, io, tmp.dir);
    defer repo.deinit(io);

    const before_oid = try repo.odb.write(.blob, "checked out before the refusal\n", null);
    const reserved_oid = try repo.odb.write(.blob, "attacker content\n", null);
    const after_oid = try repo.odb.write(.blob, "never reached\n", null);
    var entries = [_]Tree.Entry{
        .{ .mode = .blob, .name = "!before.txt", .oid = before_oid },
        .{ .mode = .blob, .name = reserved_tmp_name, .oid = reserved_oid },
        .{ .mode = .blob, .name = "zzz-after.txt", .oid = after_oid },
    };
    const tree_oid = try writeTree(gpa, &repo.odb, &entries);

    try std.testing.expectError(
        error.NameReservedForCheckout,
        checkoutTree(gpa, io, &repo.odb, repo.worktree, repo.worktree, tree_oid, populate, null),
    );

    // The sibling sorted, and so was checked out, before the reserved
    // name: its content survives the later refusal untouched.
    const before_bytes = try readAllAlloc(gpa, io, repo.worktree, "!before.txt");
    defer gpa.free(before_bytes);
    try std.testing.expectEqualStrings("checked out before the refusal\n", before_bytes);

    // The sibling sorted after the reserved name: the walk never reached
    // it, so it was never written at all, not silently destroyed.
    try std.testing.expectError(error.FileNotFound, repo.worktree.statFile(io, "zzz-after.txt", .{}));
}

test "checkoutTree with a default Strategy populates a fresh worktree" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var repo = try TestRepo.open(gpa, io, tmp.dir);
    defer repo.deinit(io);

    const blob_oid = try repo.odb.write(.blob, "hello\n", null);
    var entries = [_]Tree.Entry{.{ .mode = .blob, .name = "greeting.txt", .oid = blob_oid }};
    const tree_oid = try writeTree(gpa, &repo.odb, &entries);

    // `.{}` on its own, with no flag set, still writes: `recreate_missing`
    // defaults to `true` precisely so this is not a silent no-op.
    try checkoutTree(gpa, io, &repo.odb, repo.worktree, repo.worktree, tree_oid, .{}, null);

    const bytes = try readAllAlloc(gpa, io, repo.worktree, "greeting.txt");
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("hello\n", bytes);
}
