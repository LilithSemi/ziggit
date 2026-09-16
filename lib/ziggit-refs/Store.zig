//! The ref database for one repository: loose ref files and `packed-refs`
//! together, read with loose winning over packed, and written through a
//! lock file and an atomic rename.
//!
//! Compare-and-swap is the point of this file. Every write names the value
//! it expects to replace; a mismatch changes nothing and reports
//! `error.CasMismatch` instead of silently picking a winner.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;
const Committer = core_mod.Committer;

const loose_mod = @import("loose.zig");
const packed_mod = @import("packed.zig");
const reflog_mod = @import("reflog.zig");

/// What a reference points at.
pub const Target = loose_mod.Target;

/// A single ref: its own name and what it currently points at. Returned by
/// `Store.lookup` and by `Store.Iterator.next`.
pub const Reference = struct {
    /// The ref's own name, for example "refs/heads/main". Owned, freed by
    /// `deinit`.
    name: []const u8,
    target: Target,
    /// The object a packed, fully peeled annotated tag ultimately points
    /// at. Set only when `packed-refs` carried a "^" line for this ref;
    /// null for every loose ref, since only `packed-refs` records peeling.
    peeled: ?Oid,

    /// Frees `name`, and `target`'s string when `target` is `.symbolic`.
    pub fn deinit(r: *Reference, gpa: Allocator) void {
        switch (r.target) {
            .symbolic => |s| gpa.free(s),
            .oid => {},
        }
        gpa.free(r.name);
        r.* = undefined;
    }
};

/// A ref chain longer than this is treated as a cycle rather than followed
/// forever. git resolves real chains in one or two hops; this leaves ample
/// headroom without ever looping without bound.
const max_symbolic_depth: usize = 5;

/// Largest `packed-refs` file this reads in one call. A defensive ceiling,
/// not a spec limit: a repository with more refs than this fits in 64 MiB
/// of hex and names is not one this module is sized for.
const max_packed_refs_len: std.Io.Limit = .limited(64 * 1024 * 1024);

pub const Store = struct {
    gpa: Allocator,
    io: std.Io,
    /// Borrowed. The caller opens this before `init` and closes it after
    /// `deinit`; `Store` never closes it itself. For a linked worktree this
    /// is the common directory, not the per-worktree directory: this
    /// module does not resolve that distinction, it only reads and writes
    /// whatever directory it is given.
    git_dir: std.Io.Dir,
    format: Format,
    /// Who a reflog line written by this `Store` is attributed to. Null
    /// means this `Store` cannot attribute a write to anyone; a caller
    /// that then asks for a reflog entry is refused with
    /// `error.NoCommitterIdentity` rather than getting a fabricated or
    /// missing one. A caller that never passes `reflog_message` never
    /// needs this and is unaffected by it being null.
    committer: ?Committer,

    /// Counts a lock file this `Store` created but could not remove after
    /// use. Each `Store` keeps its own count, since a lock file stuck by
    /// one instance says nothing about any other. See `releaseLockAndReport`.
    stuck_lock_releases: usize = 0,
    /// Counts a reflog line this `Store` wrote for an update that then
    /// failed, where undoing that line also failed. See
    /// `reportStuckReflogRevert`.
    stuck_reflog_reverts: usize = 0,

    /// `packed-refs`, parsed once and kept until a write to that file
    /// invalidates it. `iterate` calls `lookup` once per candidate name, so
    /// re-reading and re-parsing `packed-refs` on every one of those would
    /// cost time quadratic in the number of packed refs; every lookup after
    /// the first instead scans this in memory. Null means "not loaded
    /// yet"; loaded but empty (no `packed-refs` file, or one with no
    /// entries) is an empty slice, kept distinct so a missing file is not
    /// re-read on every call either. Owned by this `Store`, freed by
    /// `invalidatePackedCache` and by `deinit`.
    packed_cache: ?[]PackedEntry = null,

    /// One packed ref, owned independently of the file content it was
    /// parsed from: `packed_cache` outlives the buffer `ensurePackedCache`
    /// reads `packed-refs` into.
    const PackedEntry = struct { name: []u8, oid: Oid, peeled: ?Oid };

    pub const Error = error{
        RefNotFound,
        InvalidRefName,
        LockContended,
        CorruptRefFile,
        CasMismatch,
        InvalidReflogMessage,
        /// A caller asked for a reflog entry, and this `Store` has no
        /// `Committer` to attribute it to. Refused before anything is
        /// locked or written: a ref update that git could not attribute
        /// never happens, rather than happening with the reflog entry
        /// silently dropped or a fabricated identity written in its
        /// place.
        NoCommitterIdentity,
        IoFailed,
    } || std.mem.Allocator.Error;

    /// `committer` is who a reflog line this `Store` writes is
    /// attributed to; null when the caller has no identity to give. A
    /// null `committer` only matters to a call that also passes a
    /// `reflog_message`, which then fails with `error.NoCommitterIdentity`.
    pub fn init(gpa: Allocator, io: std.Io, git_dir: std.Io.Dir, f: Format, committer: ?Committer) Store {
        return .{ .gpa = gpa, .io = io, .git_dir = git_dir, .format = f, .committer = committer };
    }

    /// Releases the packed-refs cache, if one was ever loaded; `git_dir`
    /// itself is borrowed, so this never touches it. Exists so a caller can
    /// treat every ziggit type uniformly.
    pub fn deinit(s: *Store) void {
        s.invalidatePackedCache();
        s.* = undefined;
    }

    /// Reads the ref named `name`, loose ref files winning over the same
    /// name in `packed-refs`. `error.RefNotFound` means neither has it,
    /// which is a normal state, not a fault, so this never reports it
    /// through `diag`.
    pub fn lookup(s: *Store, name: []const u8, diag: ?*?Diagnostic) Error!Reference {
        core_mod.refname.validate(name) catch |err| {
            try s.reportBadRefname(diag, name);
            return err;
        };

        const loose_target = loose_mod.read(s.gpa, s.git_dir, s.io, name, s.format) catch |err| {
            if (err == error.CorruptRefFile) try s.reportCorruptRef(diag, name);
            return err;
        };
        if (loose_target) |target| {
            const owned_name = s.gpa.dupe(u8, name) catch |err| {
                freeTarget(s.gpa, target);
                return err;
            };
            return .{ .name = owned_name, .target = target, .peeled = null };
        }

        if (try s.packedLookup(name, diag)) |m| {
            return .{ .name = try s.gpa.dupe(u8, name), .target = .{ .oid = m.oid }, .peeled = m.peeled };
        }

        return error.RefNotFound;
    }

    /// Follows symrefs to `max_symbolic_depth`, returning the object id the
    /// chain ends at. A cycle never loops forever: past the depth limit
    /// this reports `error.CorruptRefFile`. A chain that ends at a name
    /// with no ref at all, which is what an unborn HEAD looks like, reports
    /// `error.RefNotFound` exactly as `lookup` would for that name.
    pub fn resolve(s: *Store, name: []const u8, diag: ?*?Diagnostic) Error!Oid {
        var current: []const u8 = name;
        var owned: ?[]u8 = null;
        defer if (owned) |o| s.gpa.free(o);

        var depth: usize = 0;
        while (true) {
            var ref = try s.lookup(current, diag);
            defer ref.deinit(s.gpa);

            switch (ref.target) {
                .oid => |o| return o,
                .symbolic => |sym| {
                    depth += 1;
                    if (depth > max_symbolic_depth) return error.CorruptRefFile;
                    const next = try s.gpa.dupe(u8, sym);
                    if (owned) |o| s.gpa.free(o);
                    owned = next;
                    current = next;
                },
            }
        }
    }

    /// Compare and swap. `expected_old` of null means `name` must not
    /// already exist. A mismatch is `error.CasMismatch`; nothing is
    /// written, and whatever `name` held before stays exactly as it was.
    /// A `CasMismatch` is an ordinary result of the race this function
    /// exists to resolve, not a fault, so it is never reported through
    /// `diag`. `reflog_message` of null skips the reflog entirely; a
    /// message with a newline or a tab is `error.InvalidReflogMessage`,
    /// and a non-null message on a `Store` with no committer is
    /// `error.NoCommitterIdentity`, both checked before anything is
    /// locked or written.
    ///
    /// A repository with no configured committer therefore gets no reflog
    /// entry, because a caller that still wants its refs written must ask
    /// for no reflog message at all. This refusal is deliberate, not
    /// missing: an identity is not something to invent. See
    /// `Repository.OpenOptions.committer`.
    pub fn update(
        s: *Store,
        name: []const u8,
        new: Oid,
        expected_old: ?Oid,
        reflog_message: ?[]const u8,
        diag: ?*?Diagnostic,
    ) Error!void {
        return s.writeThroughLock(name, .{ .oid = new }, .{ .cas = expected_old }, reflog_message, diag);
    }

    /// Forces `name` to point at `new` in place of whatever it holds now,
    /// for the one case `update`'s compare-and-swap cannot express: `name`
    /// currently a symbolic ref, which has no oid of its own to check
    /// `new` against. `error.CasMismatch` when `name` currently holds an
    /// oid instead; replacing that still needs a caller to state what it
    /// expects to replace, exactly as `update` requires, so this is not a
    /// second way to skip that check, only the one case it cannot cover.
    /// Otherwise behaves exactly like `update`: the same lock, the same
    /// validated refname, the same atomic rename, and the same reflog
    /// entry appended when `reflog_message` is non-null.
    pub fn forceReplaceSymbolic(
        s: *Store,
        name: []const u8,
        new: Oid,
        reflog_message: ?[]const u8,
        diag: ?*?Diagnostic,
    ) Error!void {
        return s.writeThroughLock(name, .{ .oid = new }, .force_replace_symbolic, reflog_message, diag);
    }

    /// Sets HEAD to a symbolic reference pointing at `target_refname`.
    /// HEAD may be currently absent, symbolic, or an oid; all are replaced.
    /// `target_refname` must be a valid ref name. Goes through the lock,
    /// atomic rename, and refname validation. Reflog is not written for
    /// symbolic HEAD updates, matching git behavior when HEAD is unborn.
    pub fn setHead(
        s: *Store,
        target_refname: []const u8,
        reflog_message: ?[]const u8,
        diag: ?*?Diagnostic,
    ) Error!void {
        // The TARGET is an ordinary ref name and is validated. HEAD itself
        // is not a ref name under `refs/`, which is why the write goes
        // through the door that skips validation of the name it writes.
        core_mod.refname.validate(target_refname) catch |err| {
            try s.reportBadRefname(diag, target_refname);
            return err;
        };
        return s.writeThroughLockNoValidate(
            "HEAD",
            .{ .symbolic = target_refname },
            .set_head_symbolic,
            reflog_message,
            diag,
        );
    }

    /// Sets HEAD to point directly at `oid`, making it a detached HEAD.
    /// HEAD may be currently absent, symbolic, or an oid; all are replaced.
    /// The same lock, atomic rename, and optional reflog entry as other ref
    /// operations.
    pub fn setHeadDetached(
        s: *Store,
        new: Oid,
        reflog_message: ?[]const u8,
        diag: ?*?Diagnostic,
    ) Error!void {
        return s.writeThroughLockNoValidate("HEAD", .{ .oid = new }, .set_head_detached, reflog_message, diag);
    }

    /// What `writeThroughLock` requires of the value `name` holds before
    /// it writes `new` over it. `cas` is `update`'s ordinary
    /// compare-and-swap; `force_replace_symbolic` is `forceReplaceSymbolic`'s
    /// one deliberate exception; `set_head_detached` allows replacing any
    /// existing value with an oid, for HEAD specifically.
    const WriteMode = union(enum) {
        cas: ?Oid,
        force_replace_symbolic,
        set_head_detached,
        /// HEAD becoming symbolic. Whatever HEAD held before is replaced,
        /// the same as `set_head_detached`, because attaching HEAD to a
        /// branch is not a compare-and-swap on a value.
        set_head_symbolic,
    };

    /// What a write puts in the ref file. A ref file holds an object id or
    /// a pointer to another ref, so the one shared write path has to be
    /// able to write both. Writing symbolic content through a second path
    /// of its own is how a ref write loses its lock, its reflog, or its
    /// validation, which has already happened once in this file.
    const WriteValue = union(enum) {
        oid: Oid,
        symbolic: []const u8,
    };

    /// The lock, validate, compare, write and reflog dance shared by
    /// `update` and `forceReplaceSymbolic`; `mode` is the only thing that
    /// differs between them.
    fn writeThroughLock(
        s: *Store,
        name: []const u8,
        new: WriteValue,
        mode: WriteMode,
        reflog_message: ?[]const u8,
        diag: ?*?Diagnostic,
    ) Error!void {
        core_mod.refname.validate(name) catch |err| {
            try s.reportBadRefname(diag, name);
            return err;
        };
        return s.writeThroughLockImpl(name, new, mode, reflog_message, diag);
    }

    /// Like `writeThroughLock` but skips refname validation. Used for HEAD,
    /// which is not a normal ref name and may not validate through the usual
    /// rules.
    fn writeThroughLockNoValidate(
        s: *Store,
        name: []const u8,
        new: WriteValue,
        mode: WriteMode,
        reflog_message: ?[]const u8,
        diag: ?*?Diagnostic,
    ) Error!void {
        return s.writeThroughLockImpl(name, new, mode, reflog_message, diag);
    }

    /// The common implementation for both `writeThroughLock` and
    /// `writeThroughLockNoValidate`.
    fn writeThroughLockImpl(
        s: *Store,
        name: []const u8,
        new: WriteValue,
        mode: WriteMode,
        reflog_message: ?[]const u8,
        diag: ?*?Diagnostic,
    ) Error!void {
        if (reflog_message) |msg| {
            try reflog_mod.validateMessage(msg);
            // git refuses to record history it cannot attribute; so do
            // we, and before any lock or write, not after.
            if (s.committer == null) return error.NoCommitterIdentity;
        }

        const lock_path = try loose_mod.lockPath(s.gpa, name);
        defer s.gpa.free(lock_path);

        loose_mod.acquireLock(s.git_dir, s.io, lock_path) catch |err| {
            if (err == error.LockContended) try s.reportLockContended(diag, lock_path);
            return err;
        };
        errdefer s.releaseLockAndReport(lock_path, diag);

        const existing = try s.currentValue(name, diag);
        const ok = switch (mode) {
            .cas => |expected_old| switch (existing) {
                .absent => expected_old == null,
                .symbolic => false,
                .oid => |o| if (expected_old) |eo| o.eql(eo) else false,
            },
            .force_replace_symbolic => switch (existing) {
                .absent, .symbolic => true,
                .oid => false,
            },
            .set_head_detached => switch (existing) {
                .absent, .symbolic, .oid => true,
            },
            .set_head_symbolic => switch (existing) {
                .absent, .symbolic, .oid => true,
            },
        };
        if (!ok) return error.CasMismatch;

        var hex_buf: [Oid.max_formatted_length]u8 = undefined;
        const content = switch (new) {
            .oid => |o| try std.fmt.allocPrint(s.gpa, "{s}\n", .{o.toHex(&hex_buf)}),
            .symbolic => |target| try std.fmt.allocPrint(s.gpa, "ref: {s}\n", .{target}),
        };
        defer s.gpa.free(content);

        // The reflog line is appended here, before the rename that commits
        // `new`, while `lock_path` still exists. As long as that file is
        // there, no other `update` on this same `name` can get past its own
        // `acquireLock`, so this append and the commit below are exclusive
        // against every other writer of this ref's reflog too, not only
        // against a racing rename. If the commit then fails, the append is
        // undone below, since a reflog line describing an update that never
        // happened is worse than one that is simply missing.
        if (reflog_message) |msg| {
            const old_oid = switch (existing) {
                .oid => |o| o,
                else => Oid.zero(s.format),
            };
            // A reflog line records the id the ref holds AFTER the write.
            // For a symbolic write that is whatever the target resolves
            // to, and the zero id when the target is an unborn branch,
            // which is how git records the same event.
            const new_oid = switch (new) {
                .oid => |o| o,
                .symbolic => |target| switch (try s.currentValue(target, diag)) {
                    .oid => |o| o,
                    .absent, .symbolic => Oid.zero(s.format),
                },
            };
            // Checked above: a null committer already returned
            // `NoCommitterIdentity` before the lock was even taken.
            const committer = s.committer.?;
            const seconds: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(s.io, .real).nanoseconds, std.time.ns_per_s));
            const identity = committer.at(seconds);
            const reflog_offset = reflog_mod.append(s.gpa, s.git_dir, s.io, name, old_oid, new_oid, identity, msg) catch |err| switch (err) {
                // `RevertFailed` means `append` already tried and failed to
                // put the file back the way it was: the same fault as a
                // failed `revert` below, just caught one step earlier.
                error.RevertFailed => {
                    s.reportStuckReflogRevert(name, diag);
                    return error.IoFailed;
                },
                error.InvalidReflogMessage => return error.InvalidReflogMessage,
                error.IoFailed => return error.IoFailed,
                error.OutOfMemory => return error.OutOfMemory,
            };
            loose_mod.commitLock(s.git_dir, s.io, lock_path, name, content) catch |err| {
                reflog_mod.revert(s.gpa, s.git_dir, s.io, name, reflog_offset) catch |revert_err| switch (revert_err) {
                    // Out of memory happened before `revert` even tried to
                    // touch the file; it is a fault of its own, not a
                    // report-and-continue case, so it takes precedence over
                    // the commit failure `err` that triggered this cleanup.
                    error.OutOfMemory => return error.OutOfMemory,
                    // The truncate itself failed: the reflog line for this
                    // failed update is stuck on disk describing a change
                    // that never took effect.
                    error.IoFailed => s.reportStuckReflogRevert(name, diag),
                };
                return err;
            };
        } else {
            try loose_mod.commitLock(s.git_dir, s.io, lock_path, name, content);
        }
    }

    /// Compare and swap delete. `expected_old` of null deletes `name`
    /// unconditionally; a value deletes only when the current value
    /// matches. `error.RefNotFound` means there was nothing to delete.
    pub fn delete(s: *Store, name: []const u8, expected_old: ?Oid, diag: ?*?Diagnostic) Error!void {
        core_mod.refname.validate(name) catch |err| {
            try s.reportBadRefname(diag, name);
            return err;
        };

        const lock_path = try loose_mod.lockPath(s.gpa, name);
        defer s.gpa.free(lock_path);

        loose_mod.acquireLock(s.git_dir, s.io, lock_path) catch |err| {
            if (err == error.LockContended) try s.reportLockContended(diag, lock_path);
            return err;
        };
        errdefer s.releaseLockAndReport(lock_path, diag);

        const existing = try s.currentValue(name, diag);
        switch (existing) {
            .absent => return error.RefNotFound,
            .symbolic => return error.CasMismatch,
            .oid => |o| if (expected_old) |eo| {
                if (!o.eql(eo)) return error.CasMismatch;
            },
        }

        s.git_dir.deleteFile(s.io, name) catch |err| {
            if (err != error.FileNotFound) return error.IoFailed;
        };
        try s.removeFromPackedRefs(name, diag);
        s.releaseLockAndReport(lock_path, diag);
    }

    /// Points `name` at `target` unconditionally: no compare-and-swap,
    /// since a symref has no object id to compare.
    pub fn setSymbolic(s: *Store, name: []const u8, target: []const u8, diag: ?*?Diagnostic) Error!void {
        core_mod.refname.validate(name) catch |err| {
            try s.reportBadRefname(diag, name);
            return err;
        };
        core_mod.refname.validate(target) catch |err| {
            try s.reportBadRefname(diag, target);
            return err;
        };

        const content = try std.fmt.allocPrint(s.gpa, "ref: {s}\n", .{target});
        defer s.gpa.free(content);

        const stuck_before = s.stuck_lock_releases;
        loose_mod.writeAtomic(s.gpa, s.git_dir, s.io, name, content, &s.stuck_lock_releases) catch |err| {
            if (s.stuck_lock_releases != stuck_before) s.reportStuckLockRelease(name, diag);
            if (err == error.LockContended) try s.reportLockContended(diag, name);
            return err;
        };
    }

    /// Yields every ref, loose or packed, whose name starts with `prefix`.
    /// Loose wins over packed for a name in both, exactly as `lookup` does,
    /// since this calls `lookup` once per name under the hood.
    pub fn iterate(s: *Store, prefix: []const u8) Error!Iterator {
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| s.gpa.free(n);
            names.deinit(s.gpa);
        }
        var seen: std.StringHashMapUnmanaged(void) = .empty;
        defer seen.deinit(s.gpa);

        var refs_dir = s.git_dir.openDir(s.io, "refs", .{ .iterate = true }) catch |err| blk: {
            if (err == error.FileNotFound) break :blk null;
            return error.IoFailed;
        };
        if (refs_dir) |*rd| {
            defer rd.close(s.io);
            var walker = rd.walk(s.gpa) catch return error.OutOfMemory;
            defer walker.deinit();
            while (true) {
                const entry = walker.next(s.io) catch return error.IoFailed;
                if (entry == null) break;
                if (entry.?.kind != .file) continue;
                const candidate = try std.fmt.allocPrint(s.gpa, "refs/{s}", .{entry.?.path});
                if (!std.mem.startsWith(u8, candidate, prefix) or seen.contains(candidate)) {
                    s.gpa.free(candidate);
                    continue;
                }
                names.append(s.gpa, candidate) catch |err| {
                    s.gpa.free(candidate);
                    return err;
                };
                try seen.put(s.gpa, candidate, {});
            }
        }

        const packed_content = s.git_dir.readFileAlloc(s.io, "packed-refs", s.gpa, max_packed_refs_len) catch |err| blk: {
            if (err == error.FileNotFound) break :blk null;
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.IoFailed;
        };
        if (packed_content) |content| {
            defer s.gpa.free(content);
            var it = packed_mod.packed_refs.Iterator.init(content, s.format);
            while (try it.next()) |entry| {
                if (!std.mem.startsWith(u8, entry.name, prefix) or seen.contains(entry.name)) continue;
                const candidate = try s.gpa.dupe(u8, entry.name);
                names.append(s.gpa, candidate) catch |err| {
                    s.gpa.free(candidate);
                    return err;
                };
                try seen.put(s.gpa, candidate, {});
            }
        }

        var refs: std.ArrayList(Reference) = .empty;
        errdefer {
            for (refs.items) |*r| r.deinit(s.gpa);
            refs.deinit(s.gpa);
        }
        for (names.items) |n| {
            const ref = try s.lookup(n, null);
            try refs.append(s.gpa, ref);
        }

        return .{ .refs = try refs.toOwnedSlice(s.gpa), .index = 0 };
    }

    pub const Iterator = struct {
        refs: []Reference,
        index: usize,

        /// Returns the next ref, transferring ownership to the caller: the
        /// caller must call `Reference.deinit` on it. Returns null once
        /// every ref has been yielded.
        pub fn next(it: *Iterator) ?Reference {
            if (it.index >= it.refs.len) return null;
            defer it.index += 1;
            return it.refs[it.index];
        }

        /// Frees every ref this iterator has not yet yielded, then its own
        /// backing storage. Call this once done, whether or not `next` ran
        /// to completion.
        pub fn deinit(it: *Iterator, gpa: Allocator) void {
            for (it.refs[it.index..]) |*r| r.deinit(gpa);
            gpa.free(it.refs);
            it.* = undefined;
        }
    };

    const Existing = union(enum) {
        absent,
        symbolic,
        oid: Oid,
    };

    /// The current direct value of `name`, without following a symref.
    /// `.symbolic` means `name` exists but is not a value a compare and
    /// swap can match against.
    fn currentValue(s: *Store, name: []const u8, diag: ?*?Diagnostic) Error!Existing {
        const loose_target = loose_mod.read(s.gpa, s.git_dir, s.io, name, s.format) catch |err| {
            if (err == error.CorruptRefFile) try s.reportCorruptRef(diag, name);
            return err;
        };
        if (loose_target) |target| {
            switch (target) {
                .oid => |o| return .{ .oid = o },
                .symbolic => |sym| {
                    s.gpa.free(sym);
                    return .symbolic;
                },
            }
        }
        if (try s.packedLookup(name, diag)) |m| return .{ .oid = m.oid };
        return .absent;
    }

    const PackedMatch = struct { oid: Oid, peeled: ?Oid };

    /// Loads `s.packed_cache` from `packed-refs` the first time it is
    /// needed, then leaves it in place: later calls scan memory already
    /// read rather than reading and reparsing the file again.
    fn ensurePackedCache(s: *Store, diag: ?*?Diagnostic) Error!void {
        if (s.packed_cache != null) return;

        const content = s.git_dir.readFileAlloc(s.io, "packed-refs", s.gpa, max_packed_refs_len) catch |err| {
            if (err == error.FileNotFound) {
                s.packed_cache = try s.gpa.alloc(PackedEntry, 0);
                return;
            }
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.IoFailed;
        };
        defer s.gpa.free(content);

        var entries: std.ArrayList(PackedEntry) = .empty;
        errdefer {
            for (entries.items) |e| s.gpa.free(e.name);
            entries.deinit(s.gpa);
        }

        var it = packed_mod.packed_refs.Iterator.init(content, s.format);
        while (true) {
            const entry = it.next() catch |err| {
                try s.reportCorruptRef(diag, "packed-refs");
                return err;
            };
            const e = entry orelse break;
            const owned_name = try s.gpa.dupe(u8, e.name);
            errdefer s.gpa.free(owned_name);
            try entries.append(s.gpa, .{ .name = owned_name, .oid = e.oid, .peeled = e.peeled });
        }
        s.packed_cache = try entries.toOwnedSlice(s.gpa);
    }

    /// Frees `s.packed_cache`, if one was loaded, and sets it back to null.
    /// Called on `deinit`, and after any write to `packed-refs`: the file
    /// on disk has changed, so a cache built before that write no longer
    /// describes it.
    fn invalidatePackedCache(s: *Store) void {
        const entries = s.packed_cache orelse return;
        for (entries) |e| s.gpa.free(e.name);
        s.gpa.free(entries);
        s.packed_cache = null;
    }

    fn packedLookup(s: *Store, name: []const u8, diag: ?*?Diagnostic) Error!?PackedMatch {
        try s.ensurePackedCache(diag);
        for (s.packed_cache.?) |e| {
            if (std.mem.eql(u8, e.name, name)) return .{ .oid = e.oid, .peeled = e.peeled };
        }
        return null;
    }

    /// Rewrites `packed-refs` without `name`'s entry, if it has one. A
    /// caller that has already deleted the loose file for `name` calls
    /// this so `lookup` cannot find `name` again through the packed
    /// fallback afterward. A no-op when `name` is not packed.
    fn removeFromPackedRefs(s: *Store, name: []const u8, diag: ?*?Diagnostic) Error!void {
        const content = s.git_dir.readFileAlloc(s.io, "packed-refs", s.gpa, max_packed_refs_len) catch |err| {
            if (err == error.FileNotFound) return;
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return error.IoFailed;
        };
        defer s.gpa.free(content);

        var kept: std.ArrayList(packed_mod.packed_refs.Entry) = .empty;
        defer kept.deinit(s.gpa);
        var found = false;

        var it = packed_mod.packed_refs.Iterator.init(content, s.format);
        while (true) {
            const entry = it.next() catch |err| {
                try s.reportCorruptRef(diag, "packed-refs");
                return err;
            } orelse break;
            if (std.mem.eql(u8, entry.name, name)) {
                found = true;
                continue;
            }
            try kept.append(s.gpa, entry);
        }
        if (!found) return;

        var out: std.Io.Writer.Allocating = .init(s.gpa);
        defer out.deinit();
        packed_mod.packed_refs.write(&out.writer, kept.items) catch return error.IoFailed;

        const stuck_before = s.stuck_lock_releases;
        loose_mod.writeAtomic(s.gpa, s.git_dir, s.io, "packed-refs", out.written(), &s.stuck_lock_releases) catch |err| {
            if (s.stuck_lock_releases != stuck_before) s.reportStuckLockRelease("packed-refs", diag);
            if (err == error.LockContended) try s.reportLockContended(diag, "packed-refs");
            return err;
        };
        // The file on disk just changed; a cache built before this write,
        // if `packedLookup` ever ran on this `Store`, no longer matches it.
        s.invalidatePackedCache();
    }

    fn reportBadRefname(s: *Store, diag: ?*?Diagnostic, name: []const u8) Allocator.Error!void {
        if (!core_mod.wants(diag)) return;
        core_mod.report(diag, s.gpa, .{ .kind = .bad_refname, .path = try s.gpa.dupe(u8, name), .detail = null });
    }

    /// Reports a loose or packed ref file that failed to parse. `path` is
    /// the ref name for a loose file, or "packed-refs" for the packed one.
    fn reportCorruptRef(s: *Store, diag: ?*?Diagnostic, path: []const u8) Allocator.Error!void {
        if (!core_mod.wants(diag)) return;
        core_mod.report(diag, s.gpa, .{ .kind = .corrupt_ref, .path = try s.gpa.dupe(u8, path), .detail = null });
    }

    fn reportLockContended(s: *Store, diag: ?*?Diagnostic, lock_path: []const u8) Allocator.Error!void {
        if (!core_mod.wants(diag)) return;
        core_mod.report(diag, s.gpa, .{ .kind = .lock_contended, .path = try s.gpa.dupe(u8, lock_path), .detail = null });
    }

    /// Removes `lock_path`, counting and reporting through `diag` when the
    /// removal itself fails: the lock file stays on disk, and every later
    /// `acquireLock` on the same name reports `LockContended` until an
    /// operator clears it by hand.
    fn releaseLockAndReport(s: *Store, lock_path: []const u8, diag: ?*?Diagnostic) void {
        if (loose_mod.releaseLock(s.git_dir, s.io, lock_path)) {
            s.stuck_lock_releases += 1;
            s.reportStuckLockRelease(lock_path, diag);
        }
    }

    /// Reports a lock file that could not be removed. Does not touch
    /// `s.stuck_lock_releases`; the caller has already counted it, since
    /// some callers learn about the fault through `loose_mod.writeAtomic`
    /// incrementing the field directly rather than through this function's
    /// return value.
    fn reportStuckLockRelease(s: *Store, path: []const u8, diag: ?*?Diagnostic) void {
        if (!core_mod.wants(diag)) return;
        const owned = s.gpa.dupe(u8, path) catch {
            core_mod.report(diag, s.gpa, .{ .kind = .stuck_lock_release, .path = null, .detail = null });
            return;
        };
        core_mod.report(diag, s.gpa, .{ .kind = .stuck_lock_release, .path = owned, .detail = null });
    }

    /// Counts and reports a reflog line that could not be undone after the
    /// update it recorded failed to take effect. `name` is the ref whose
    /// reflog is left holding that stray line.
    fn reportStuckReflogRevert(s: *Store, name: []const u8, diag: ?*?Diagnostic) void {
        s.stuck_reflog_reverts += 1;
        if (!core_mod.wants(diag)) return;
        const owned = s.gpa.dupe(u8, name) catch {
            core_mod.report(diag, s.gpa, .{ .kind = .stuck_reflog_revert, .path = null, .detail = null });
            return;
        };
        core_mod.report(diag, s.gpa, .{ .kind = .stuck_reflog_revert, .path = owned, .detail = null });
    }
};

fn freeTarget(gpa: Allocator, target: Target) void {
    switch (target) {
        .symbolic => |s| gpa.free(s),
        .oid => {},
    }
}

/// The committer every test below that writes a reflog entry uses, when
/// a real one does not matter to what the test is checking.
const test_committer: Committer = .{ .name = "A U Thor", .email = "author@example.com" };

// expected

test "lookup reads a loose ref file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();
    try store.update("refs/heads/main", try Oid.parse(.sha1, "333333333333333333333333333333333333333c"), null, null, null);

    var ref = try store.lookup("refs/heads/main", null);
    defer ref.deinit(std.testing.allocator);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("333333333333333333333333333333333333333c", ref.target.oid.toHex(&buf));
}

test "lookup reads a ref that exists only in packed-refs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "packed-refs",
        .data = "# pack-refs with: peeled fully-peeled sorted\n333333333333333333333333333333333333333c refs/heads/main\n",
    });

    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();
    var ref = try store.lookup("refs/heads/main", null);
    defer ref.deinit(std.testing.allocator);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("333333333333333333333333333333333333333c", ref.target.oid.toHex(&buf));
}

test "lookup prefers the loose ref when a name is in both" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "packed-refs",
        .data = "# pack-refs with: peeled fully-peeled sorted\n111111111111111111111111111111111111111a refs/heads/main\n",
    });
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();
    const packed_oid = try Oid.parse(.sha1, "111111111111111111111111111111111111111a");
    try store.update("refs/heads/main", try Oid.parse(.sha1, "333333333333333333333333333333333333333c"), packed_oid, null, null);

    var ref = try store.lookup("refs/heads/main", null);
    defer ref.deinit(std.testing.allocator);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("333333333333333333333333333333333333333c", ref.target.oid.toHex(&buf));
}

test "lookup returns the peeled id for a packed annotated tag" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "packed-refs",
        .data = "# pack-refs with: peeled fully-peeled sorted\n" ++
            "111111111111111111111111111111111111111a refs/tags/v0.1.0\n" ++
            "^222222222222222222222222222222222222222b\n",
    });
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();

    var ref = try store.lookup("refs/tags/v0.1.0", null);
    defer ref.deinit(std.testing.allocator);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("222222222222222222222222222222222222222b", ref.peeled.?.toHex(&buf));
}

test "resolve follows a symbolic HEAD to its object id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();
    try store.update("refs/heads/main", try Oid.parse(.sha1, "333333333333333333333333333333333333333c"), null, null, null);
    try store.setSymbolic("HEAD", "refs/heads/main", null);

    const oid = try store.resolve("HEAD", null);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("333333333333333333333333333333333333333c", oid.toHex(&buf));
}

test "update writes a new ref when expected_old is null" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();

    try store.update("refs/heads/main", try Oid.parse(.sha1, "333333333333333333333333333333333333333c"), null, null, null);

    var ref = try store.lookup("refs/heads/main", null);
    defer ref.deinit(std.testing.allocator);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("333333333333333333333333333333333333333c", ref.target.oid.toHex(&buf));
}

test "update replaces a ref when expected_old matches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();
    const old_oid = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");
    try store.update("refs/heads/main", old_oid, null, null, null);

    const new_oid = try Oid.parse(.sha1, "444444444444444444444444444444444444444d");
    try store.update("refs/heads/main", new_oid, old_oid, null, null);

    var ref = try store.lookup("refs/heads/main", null);
    defer ref.deinit(std.testing.allocator);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("444444444444444444444444444444444444444d", ref.target.oid.toHex(&buf));
}

test "iterate yields every ref under refs/heads/" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();
    try store.update("refs/heads/main", try Oid.parse(.sha1, "333333333333333333333333333333333333333c"), null, null, null);
    try store.update("refs/heads/dev", try Oid.parse(.sha1, "444444444444444444444444444444444444444d"), null, null, null);
    try store.update("refs/tags/v0.1.0", try Oid.parse(.sha1, "111111111111111111111111111111111111111a"), null, null, null);

    var it = try store.iterate("refs/heads/");
    defer it.deinit(std.testing.allocator);

    var seen: usize = 0;
    while (it.next()) |ref_const| {
        var ref = ref_const;
        defer ref.deinit(std.testing.allocator);
        try std.testing.expect(std.mem.startsWith(u8, ref.name, "refs/heads/"));
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
}

// suspicious

test "update with expected_old null fails when the ref already exists" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();
    try store.update("refs/heads/main", try Oid.parse(.sha1, "333333333333333333333333333333333333333c"), null, null, null);

    try std.testing.expectError(
        error.CasMismatch,
        store.update("refs/heads/main", try Oid.parse(.sha1, "444444444444444444444444444444444444444d"), null, null, null),
    );
}

test "update fails with CasMismatch when expected_old does not match" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();
    try store.update("refs/heads/main", try Oid.parse(.sha1, "333333333333333333333333333333333333333c"), null, null, null);

    const wrong_old = try Oid.parse(.sha1, "111111111111111111111111111111111111111a");
    try std.testing.expectError(
        error.CasMismatch,
        store.update("refs/heads/main", try Oid.parse(.sha1, "444444444444444444444444444444444444444d"), wrong_old, null, null),
    );
}

test "update leaves the old value in place after a CasMismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();
    const old_oid = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");
    try store.update("refs/heads/main", old_oid, null, null, null);

    const wrong_old = try Oid.parse(.sha1, "111111111111111111111111111111111111111a");
    try std.testing.expectError(
        error.CasMismatch,
        store.update("refs/heads/main", try Oid.parse(.sha1, "444444444444444444444444444444444444444d"), wrong_old, null, null),
    );

    var ref = try store.lookup("refs/heads/main", null);
    defer ref.deinit(std.testing.allocator);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("333333333333333333333333333333333333333c", ref.target.oid.toHex(&buf));
}

test "resolve stops with an error on a symref cycle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();
    try store.setSymbolic("refs/heads/a", "refs/heads/b", null);
    try store.setSymbolic("refs/heads/b", "refs/heads/a", null);

    try std.testing.expectError(error.CorruptRefFile, store.resolve("refs/heads/a", null));
}

test "resolve reports RefNotFound for an unborn HEAD" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();
    try store.setSymbolic("HEAD", "refs/heads/main", null);

    try std.testing.expectError(error.RefNotFound, store.resolve("HEAD", null));
}

test "lookup rejects a name that fails refname validation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();

    try std.testing.expectError(error.InvalidRefName, store.lookup("refs/heads/bad..name", null));
}

test "a stale .lock file makes update fail with LockContended rather than overwrite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();
    try store.update("refs/heads/main", try Oid.parse(.sha1, "333333333333333333333333333333333333333c"), null, null, null);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "refs/heads/main.lock", .data = "leftover" });

    try std.testing.expectError(
        error.LockContended,
        store.update("refs/heads/main", try Oid.parse(.sha1, "444444444444444444444444444444444444444d"), null, null, null),
    );

    var ref = try store.lookup("refs/heads/main", null);
    defer ref.deinit(std.testing.allocator);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("333333333333333333333333333333333333333c", ref.target.oid.toHex(&buf));

    const lock_content = try tmp.dir.readFileAlloc(std.testing.io, "refs/heads/main.lock", std.testing.allocator, .limited(256));
    defer std.testing.allocator.free(lock_content);
    try std.testing.expectEqualStrings("leftover", lock_content);
}

// regression

test "delete removes a ref so a later lookup reports RefNotFound" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();
    const oid = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");
    try store.update("refs/heads/main", oid, null, null, null);

    try store.delete("refs/heads/main", oid, null);

    try std.testing.expectError(error.RefNotFound, store.lookup("refs/heads/main", null));
}

test "delete also drops a packed-refs entry so the ref does not reappear" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "packed-refs",
        .data = "# pack-refs with: peeled fully-peeled sorted\n333333333333333333333333333333333333333c refs/heads/main\n",
    });
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();
    const oid = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");

    try store.delete("refs/heads/main", oid, null);

    try std.testing.expectError(error.RefNotFound, store.lookup("refs/heads/main", null));
}

test "update with a reflog message writes the ref and a matching reflog entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, test_committer);
    defer store.deinit();
    const oid = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");

    try store.update("refs/heads/main", oid, null, "create main", null);

    var ref = try store.lookup("refs/heads/main", null);
    defer ref.deinit(std.testing.allocator);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("333333333333333333333333333333333333333c", ref.target.oid.toHex(&buf));

    const log_content = try tmp.dir.readFileAlloc(std.testing.io, "logs/refs/heads/main", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(log_content);
    try std.testing.expect(std.mem.endsWith(u8, log_content, "\tcreate main\n"));
}

test "update never writes a reflog entry when the CAS check fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, test_committer);
    defer store.deinit();
    try store.update("refs/heads/main", try Oid.parse(.sha1, "333333333333333333333333333333333333333c"), null, null, null);

    const wrong_old = try Oid.parse(.sha1, "111111111111111111111111111111111111111a");
    try std.testing.expectError(
        error.CasMismatch,
        store.update("refs/heads/main", try Oid.parse(.sha1, "444444444444444444444444444444444444444d"), wrong_old, "should not be recorded", null),
    );

    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.readFileAlloc(std.testing.io, "logs/refs/heads/main", std.testing.allocator, .limited(4096)),
    );
}

test "update leaves the ref untouched when the reflog step fails, proving the reflog is written before the ref commits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A plain file at "logs" blocks reflog.append's own `createDirPath`
    // from making "logs/refs/heads", so the reflog step fails before
    // `Store.update` ever reaches the rename that would commit the ref.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "logs", .data = "not a directory" });
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, test_committer);
    defer store.deinit();

    try std.testing.expectError(
        error.IoFailed,
        store.update("refs/heads/main", try Oid.parse(.sha1, "333333333333333333333333333333333333333c"), null, "create main", null),
    );

    // If the ref had been committed before the failed reflog step, this
    // would find it. Ordering it the other way round means a reflog
    // failure can never leave a ref changed with nothing recorded.
    try std.testing.expectError(error.RefNotFound, store.lookup("refs/heads/main", null));
}

test "update rejects a reflog message with a newline before writing anything" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();

    try std.testing.expectError(
        error.InvalidReflogMessage,
        store.update("refs/heads/main", try Oid.parse(.sha1, "333333333333333333333333333333333333333c"), null, "two\nlines", null),
    );
    try std.testing.expectError(error.RefNotFound, store.lookup("refs/heads/main", null));
}

test "update refuses a reflog message with NoCommitterIdentity when the Store has no committer, leaving the ref untouched" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();

    try std.testing.expectError(
        error.NoCommitterIdentity,
        store.update("refs/heads/main", try Oid.parse(.sha1, "333333333333333333333333333333333333333c"), null, "create main", null),
    );

    // Refused before any lock or write: no ref, and no reflog file either.
    try std.testing.expectError(error.RefNotFound, store.lookup("refs/heads/main", null));
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.readFileAlloc(std.testing.io, "logs/refs/heads/main", std.testing.allocator, .limited(4096)),
    );
}

test "update with no reflog message still succeeds on a Store with no committer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();

    try store.update("refs/heads/main", try Oid.parse(.sha1, "333333333333333333333333333333333333333c"), null, null, null);

    var ref = try store.lookup("refs/heads/main", null);
    defer ref.deinit(std.testing.allocator);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("333333333333333333333333333333333333333c", ref.target.oid.toHex(&buf));
}

test "an InvalidRefName error carries the offending name through diag" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();

    var diag: ?Diagnostic = null;
    try std.testing.expectError(error.InvalidRefName, store.lookup("refs/heads/bad..name", &diag));
    try std.testing.expect(diag != null);
    try std.testing.expectEqual(Diagnostic.Kind.bad_refname, diag.?.kind);
    try std.testing.expectEqualStrings("refs/heads/bad..name", diag.?.path.?);
    diag.?.deinit(std.testing.allocator);
}

/// A `std.Io` that behaves exactly like `std.testing.io`, except every
/// `dirRename` fails with `error.AccessDenied`. `commitLock`'s rename is
/// the very last step of a write, so this forces a failure there and
/// nowhere earlier: everything before it, including a reflog `append`,
/// runs for real.
const RenameAlwaysFails = struct {
    var table: std.Io.VTable = undefined;

    fn rename(
        userdata: ?*anyopaque,
        old_dir: std.Io.Dir,
        old_sub_path: []const u8,
        new_dir: std.Io.Dir,
        new_sub_path: []const u8,
    ) std.Io.Dir.RenameError!void {
        _ = userdata;
        _ = old_dir;
        _ = old_sub_path;
        _ = new_dir;
        _ = new_sub_path;
        return error.AccessDenied;
    }

    fn io() std.Io {
        table = std.testing.io.vtable.*;
        table.dirRename = rename;
        return .{ .userdata = std.testing.io.userdata, .vtable = &table };
    }
};

test "update leaves the ref and the reflog exactly as they were when commitLock fails after append already succeeded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, test_committer);
    defer store.deinit();
    const old_oid = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");
    try store.update("refs/heads/main", old_oid, null, "create main", null);

    const before_log = try tmp.dir.readFileAlloc(std.testing.io, "logs/refs/heads/main", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(before_log);

    // A second `Store` over the same directory, whose `io` fails only the
    // rename `commitLock` performs at the very end of a write. The append
    // above it in `update` still runs to completion, so this exercises the
    // revert path end to end rather than the `append`-fails path already
    // covered elsewhere.
    var failing_store = Store.init(std.testing.allocator, RenameAlwaysFails.io(), tmp.dir, .sha1, test_committer);
    defer failing_store.deinit();
    const new_oid = try Oid.parse(.sha1, "444444444444444444444444444444444444444d");
    try std.testing.expectError(
        error.IoFailed,
        failing_store.update("refs/heads/main", new_oid, old_oid, "second update", null),
    );

    var ref = try store.lookup("refs/heads/main", null);
    defer ref.deinit(std.testing.allocator);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("333333333333333333333333333333333333333c", ref.target.oid.toHex(&buf));

    const after_log = try tmp.dir.readFileAlloc(std.testing.io, "logs/refs/heads/main", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(after_log);
    try std.testing.expectEqualStrings(before_log, after_log);
}

test "a successful update never counts a stuck reflog revert" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, test_committer);
    defer store.deinit();

    try store.update("refs/heads/main", try Oid.parse(.sha1, "333333333333333333333333333333333333333c"), null, "create main", null);

    try std.testing.expectEqual(@as(usize, 0), store.stuck_reflog_reverts);
}

/// A `std.Io` that fails every `dirRename` the same way `RenameAlwaysFails`
/// does, and every `fileSetLength` too, so `revert`'s own attempt to undo
/// the append also fails. This is the double fault `stuck_reflog_reverts`
/// exists to count.
const RenameAndTruncateAlwaysFail = struct {
    var table: std.Io.VTable = undefined;

    fn rename(
        userdata: ?*anyopaque,
        old_dir: std.Io.Dir,
        old_sub_path: []const u8,
        new_dir: std.Io.Dir,
        new_sub_path: []const u8,
    ) std.Io.Dir.RenameError!void {
        _ = userdata;
        _ = old_dir;
        _ = old_sub_path;
        _ = new_dir;
        _ = new_sub_path;
        return error.AccessDenied;
    }

    fn setLength(userdata: ?*anyopaque, file: std.Io.File, new_length: u64) std.Io.File.SetLengthError!void {
        _ = userdata;
        _ = file;
        _ = new_length;
        return error.InputOutput;
    }

    fn io() std.Io {
        table = std.testing.io.vtable.*;
        table.dirRename = rename;
        table.fileSetLength = setLength;
        return .{ .userdata = std.testing.io.userdata, .vtable = &table };
    }
};

test "a revert that cannot truncate the reflog counts and reports a stuck reflog revert" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, test_committer);
    defer store.deinit();
    const old_oid = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");
    try store.update("refs/heads/main", old_oid, null, "create main", null);

    var failing_store = Store.init(std.testing.allocator, RenameAndTruncateAlwaysFail.io(), tmp.dir, .sha1, test_committer);
    defer failing_store.deinit();
    const new_oid = try Oid.parse(.sha1, "444444444444444444444444444444444444444d");

    try std.testing.expectEqual(@as(usize, 0), failing_store.stuck_reflog_reverts);

    var diag: ?Diagnostic = null;
    try std.testing.expectError(
        error.IoFailed,
        failing_store.update("refs/heads/main", new_oid, old_oid, "second update", &diag),
    );

    try std.testing.expectEqual(@as(usize, 1), failing_store.stuck_reflog_reverts);
    try std.testing.expect(diag != null);
    try std.testing.expectEqual(Diagnostic.Kind.stuck_reflog_revert, diag.?.kind);
    try std.testing.expectEqualStrings("refs/heads/main", diag.?.path.?);
    diag.?.deinit(std.testing.allocator);
}

test "setHead makes HEAD symbolic and reading HEAD back resolves to the target ref id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();
    const target_oid = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");
    try store.update("refs/heads/main", target_oid, null, null, null);

    try store.setHead("refs/heads/main", null, null);

    const resolved_oid = try store.resolve("HEAD", null);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("333333333333333333333333333333333333333c", resolved_oid.toHex(&buf));
}

test "setHeadDetached makes HEAD a direct id and reading HEAD back gives that id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();
    const detached_oid = try Oid.parse(.sha1, "444444444444444444444444444444444444444d");

    try store.setHeadDetached(detached_oid, null, null);

    const resolved_oid = try store.resolve("HEAD", null);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("444444444444444444444444444444444444444d", resolved_oid.toHex(&buf));
}

test "setHead on a detached HEAD re-attaches it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();
    const oid1 = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");
    const oid2 = try Oid.parse(.sha1, "444444444444444444444444444444444444444d");
    try store.update("refs/heads/main", oid1, null, null, null);

    try store.setHeadDetached(oid2, null, null);

    try store.setHead("refs/heads/main", null, null);

    const resolved_oid = try store.resolve("HEAD", null);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("333333333333333333333333333333333333333c", resolved_oid.toHex(&buf));
}

test "setHeadDetached on a symbolic HEAD detaches it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();
    const oid1 = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");
    const oid2 = try Oid.parse(.sha1, "444444444444444444444444444444444444444d");
    try store.update("refs/heads/main", oid1, null, null, null);

    try store.setHead("refs/heads/main", null, null);

    try store.setHeadDetached(oid2, null, null);

    const resolved_oid = try store.resolve("HEAD", null);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("444444444444444444444444444444444444444d", resolved_oid.toHex(&buf));
}

test "setHead rejects invalid refname" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();

    try std.testing.expectError(error.InvalidRefName, store.setHead("refs/heads/bad..name", null, null));
}

test "setHead to a non-existent branch succeeds as an unborn branch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();

    try store.setHead("refs/heads/unborn", null, null);

    var head_ref = try store.lookup("HEAD", null);
    defer head_ref.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("refs/heads/unborn", head_ref.target.symbolic);
}

test "setHeadDetached uses the lock path and rejects a stale HEAD.lock file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();
    const oid = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "HEAD.lock", .data = "leftover" });

    try std.testing.expectError(error.LockContended, store.setHeadDetached(oid, null, null));
}

test "setHeadDetached verifies the lock blocks writes and is released on success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();
    const oid1 = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");
    const oid2 = try Oid.parse(.sha1, "444444444444444444444444444444444444444d");

    try store.setHeadDetached(oid1, null, null);

    var head_ref = try store.lookup("HEAD", null);
    defer head_ref.deinit(std.testing.allocator);
    var buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("333333333333333333333333333333333333333c", head_ref.target.oid.toHex(&buf));

    try store.setHeadDetached(oid2, null, null);

    var head_ref2 = try store.lookup("HEAD", null);
    defer head_ref2.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("444444444444444444444444444444444444444d", head_ref2.target.oid.toHex(&buf));
}

test "setHead writes a reflog entry when a message is given" {
    // The first version of `setHead` took `reflog_message` and discarded
    // it with `_ = reflog_message;`. Every test passed, because no test
    // asked what the message did. An option a caller can set and the code
    // ignores is the inert-option bug this project has shipped before.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, test_committer);
    defer store.deinit();

    const oid = try Oid.parse(.sha1, "333333333333333333333333333333333333333c");
    try store.update("refs/heads/main", oid, null, null, null);
    try store.setHead("refs/heads/main", "checkout: moving to main", null);

    const log = try tmp.dir.readFileAlloc(std.testing.io, "logs/HEAD", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "checkout: moving to main") != null);
    // The line records the id HEAD holds after the write, which is what
    // the target resolves to, not a zero id.
    try std.testing.expect(std.mem.indexOf(u8, log, "333333333333333333333333333333333333333c") != null);
}

test "setHead with a reflog message and no committer is NoCommitterIdentity" {
    // The same rule `update` follows: git refuses to record history it
    // cannot attribute, and an identity is not something to invent.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, null);
    defer store.deinit();

    try std.testing.expectError(
        error.NoCommitterIdentity,
        store.setHead("refs/heads/main", "checkout: moving to main", null),
    );
}

test "setHeadDetached writes a reflog entry naming the id it moved to" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.allocator, std.testing.io, tmp.dir, .sha1, test_committer);
    defer store.deinit();

    const oid = try Oid.parse(.sha1, "444444444444444444444444444444444444444d");
    try store.setHeadDetached(oid, "checkout: moving to a revision", null);

    const log = try tmp.dir.readFileAlloc(std.testing.io, "logs/HEAD", std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "checkout: moving to a revision") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "444444444444444444444444444444444444444d") != null);
}
