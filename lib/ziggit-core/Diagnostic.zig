//! Detail about a fault, for a caller that wants to report it. A library
//! module never prints; it hands a `Diagnostic` back through an out
//! parameter instead.

const std = @import("std");

pub const Diagnostic = struct {
    pub const Kind = enum {
        corrupt_object,
        corrupt_pack,
        corrupt_index,
        corrupt_config,
        /// A loose or packed ref file holds bytes that do not parse as a
        /// ref: a bad id, a malformed symref target, or a truncated line.
        corrupt_ref,
        /// A file under `.git` that names or shapes the repository itself
        /// (`HEAD`, a gitdir file, a gitfile pointer) holds bytes that do
        /// not parse.
        corrupt_gitfile,
        /// An object exists and is well formed, but its real size is over
        /// the caller's own allocation budget for `readAlloc`. Distinct
        /// from a genuine allocator failure so a caller can tell "retry or
        /// give up" apart from "use the streaming `read` instead".
        object_too_large,
        bad_refname,
        lock_contended,
        /// A lock file could not be removed after its write finished or
        /// failed. The lock stays on disk; every later attempt to lock the
        /// same ref reports `lock_contended` until an operator removes it
        /// by hand.
        stuck_lock_release,
        /// A reflog line written for an update that then failed could not
        /// be undone. The line stays on disk, describing a change that
        /// never took effect.
        stuck_reflog_revert,
        io,
    };

    kind: Kind,
    path: ?[]const u8, // owned, freed by Diagnostic.deinit
    detail: ?[]const u8, // owned, freed by Diagnostic.deinit

    pub fn deinit(d: *Diagnostic, gpa: std.mem.Allocator) void {
        if (d.path) |p| gpa.free(p);
        if (d.detail) |dt| gpa.free(dt);
        d.path = null;
        d.detail = null;
    }
};

/// True when the caller asked for detail. Guard every diagnostic allocation
/// with this so a null `diag` costs nothing.
pub fn wants(diag: ?*?Diagnostic) bool {
    return diag != null;
}

/// Stores `d` into `diag` when the caller asked for detail. Takes ownership
/// of `d.path` and `d.detail`. When `diag` is null, or already holds a
/// diagnostic, this frees what it does not keep instead of leaking it.
pub fn report(diag: ?*?Diagnostic, gpa: std.mem.Allocator, d: Diagnostic) void {
    var owned = d;
    if (diag) |slot| {
        if (slot.*) |*old| old.deinit(gpa);
        slot.* = owned;
    } else {
        owned.deinit(gpa);
    }
}

// expected

test "wants is false for a null diagnostic" {
    try std.testing.expect(!wants(null));
}

test "wants is true for a non-null diagnostic" {
    var slot: ?Diagnostic = null;
    try std.testing.expect(wants(&slot));
}

test "report stores the diagnostic when the caller asked for one" {
    const gpa = std.testing.allocator;
    var slot: ?Diagnostic = null;
    const path = try gpa.dupe(u8, "refs/heads/bad");
    report(&slot, gpa, .{ .kind = .bad_refname, .path = path, .detail = null });
    try std.testing.expect(slot != null);
    try std.testing.expectEqualStrings("refs/heads/bad", slot.?.path.?);
    slot.?.deinit(gpa);
}

// suspicious

test "report frees the diagnostic immediately when the caller declined" {
    const gpa = std.testing.allocator;
    const path = try gpa.dupe(u8, "refs/heads/bad");
    const wants_it = wants(null);
    report(null, gpa, .{ .kind = .bad_refname, .path = path, .detail = null });
    // `std.testing.allocator` panics on a leak at test teardown, so the
    // absence of a panic here is the real assertion: `path` was freed
    // during `report`, not left owned by a diagnostic no one holds.
    try std.testing.expect(!wants_it);
}
