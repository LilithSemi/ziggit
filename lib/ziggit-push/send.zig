//! Turning an advertisement plus a set of wanted ref updates into the
//! request receive-pack reads, and reading its answer.
//!
//! Nothing here touches a socket. A transport hands over the
//! advertisement bytes and a writer for the request, which is the same
//! shape smart HTTP, ssh and the git daemon all reduce to.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;

const core_mod = @import("ziggit-core");
const Diagnostic = core_mod.Diagnostic;

const odb_mod = @import("ziggit-odb");
const Odb = odb_mod.Odb;

const pack_mod = @import("ziggit-pack");
const pktline_mod = @import("ziggit-pktline");

const protocol_mod = @import("protocol.zig");
const Advertisement = protocol_mod.Advertisement;
const Command = protocol_mod.Command;

const objects_mod = @import("objects.zig");

pub const Error = error{
    /// The remote holds something other than the expected old value, so
    /// the update is refused here and no pack is sent. This is the local
    /// half of force-with-lease.
    LeaseNotHeld,
    /// Nothing in `updates` would change anything.
    NothingToPush,
    ProtocolError,
} || objects_mod.Error || pack_mod.PackWriterError || pktline_mod.WriteError;

/// One wanted ref update.
pub const Update = struct {
    name: []const u8,
    /// The id the ref should end at. The zero id deletes.
    new: Oid,
    /// The id we believe the remote holds now. The zero id says the ref
    /// should not exist yet. The remote compares this before it moves
    /// anything, and this module compares it against the advertisement
    /// first, so a lost race costs no upload.
    expected_old: Oid,

    pub fn create(name: []const u8, new: Oid, f: Format) Update {
        return .{ .name = name, .new = new, .expected_old = .zero(f) };
    }
};

/// Which update failed its lease, and what the remote actually holds.
pub const LeaseFailure = struct {
    name: []const u8,
    expected: Oid,
    actual: Oid,
};

/// Compares every update against the advertisement. Answers with the first
/// disagreement, or null when every lease holds.
///
/// Git refuses this client side too: its trace shows it sending no
/// commands and no pack once the advertisement contradicts what it
/// expected.
pub fn checkLeases(adv: Advertisement, updates: []const Update, f: Format) ?LeaseFailure {
    for (updates) |u| {
        const actual = adv.find(u.name) orelse Oid.zero(f);
        if (!actual.eql(u.expected_old)) {
            return .{ .name = u.name, .expected = u.expected_old, .actual = actual };
        }
    }
    return null;
}

/// The capabilities to ask for, chosen from what the remote offered.
///
/// `report-status` is the only one this needs: without it the remote
/// answers nothing and a refused update would look like a success.
/// `side-band-64k` is deliberately not asked for, so the report arrives as
/// plain pkt-lines; the cost is the remote's human-readable text, and
/// `ng <ref> <reason>` still carries the reason a caller acts on.
pub fn chooseCapabilities(gpa: Allocator, adv: Advertisement, f: Format) Allocator.Error![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try list.appendSlice(gpa, "report-status");
    if (adv.supports("object-format")) {
        try list.appendSlice(gpa, " object-format=");
        try list.appendSlice(gpa, @tagName(f));
    }
    return list.toOwnedSlice(gpa);
}

pub const Request = struct {
    /// How many objects the pack carried. Zero means no pack was written
    /// at all, which is what a delete-only push sends.
    objects: usize,
};

/// Writes the whole request: the commands, the flush, and the pack when
/// there is anything to send.
///
/// A delete-only push sends no pack. Git does the same, and a receiver
/// reading a zero object pack where it expected none is a difference not
/// worth risking.
pub fn writeRequest(
    gpa: Allocator,
    odb: *Odb,
    f: Format,
    adv: Advertisement,
    updates: []const Update,
    w: *std.Io.Writer,
    diag: ?*?Diagnostic,
) Error!Request {
    if (updates.len == 0) return error.NothingToPush;
    if (checkLeases(adv, updates, f) != null) return error.LeaseNotHeld;

    var commands: std.ArrayList(Command) = .empty;
    defer commands.deinit(gpa);
    var tips: std.ArrayList(Oid) = .empty;
    defer tips.deinit(gpa);

    for (updates) |u| {
        if (u.new.eql(u.expected_old)) continue;
        try commands.append(gpa, .{ .name = u.name, .old = u.expected_old, .new = u.new });
        if (!u.new.isZero()) try tips.append(gpa, u.new);
    }
    if (commands.items.len == 0) return error.NothingToPush;

    var haves: std.ArrayList(Oid) = .empty;
    defer haves.deinit(gpa);
    for (adv.refs) |r| try haves.append(gpa, r.oid);

    const oids = try objects_mod.collect(gpa, odb, f, tips.items, haves.items, diag);
    defer gpa.free(oids);

    const caps = try chooseCapabilities(gpa, adv, f);
    defer gpa.free(caps);

    try protocol_mod.writeCommands(gpa, w, commands.items, caps);

    if (oids.len > 0) {
        var source: objects_mod.OdbSource = .{ .odb = odb, .diag = diag };
        _ = try pack_mod.writePack(gpa, f, source.source(), oids, w, diag);
    }

    return .{ .objects = oids.len };
}
