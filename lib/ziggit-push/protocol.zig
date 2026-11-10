//! Receive-pack's grammar: the ref advertisement it sends, the update
//! commands we send back, and the status report that follows the pack.
//!
//! This is protocol v1. Receive-pack has no v2, so none of
//! `ziggit-proto`'s v2 parsing applies here, and `parseCapabilities`
//! would refuse this stream outright.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;

const pktline_mod = @import("ziggit-pktline");

pub const Error = error{ProtocolError} || pktline_mod.ReadError || Allocator.Error;
pub const WriteError = pktline_mod.WriteError;

/// The name receive-pack gives its one synthetic line when the repository
/// holds no refs at all.
const no_refs_marker = "capabilities^{}";

pub const Ref = struct {
    name: []const u8, // owned
    oid: Oid,
};

pub const Advertisement = struct {
    refs: []Ref, // owned
    /// The capability list exactly as sent, space separated.
    capabilities: []const u8, // owned
    gpa: Allocator,

    pub fn deinit(a: *Advertisement) void {
        for (a.refs) |r| a.gpa.free(r.name);
        a.gpa.free(a.refs);
        a.gpa.free(a.capabilities);
        a.refs = &.{};
        a.capabilities = &.{};
    }

    /// The id the remote holds for `name`, or null when it has no such
    /// ref. Null is what a create sends the zero id for.
    pub fn find(a: Advertisement, name: []const u8) ?Oid {
        for (a.refs) |r| {
            if (std.mem.eql(u8, r.name, name)) return r.oid;
        }
        return null;
    }

    pub fn supports(a: Advertisement, cap: []const u8) bool {
        var it = std.mem.tokenizeScalar(u8, a.capabilities, ' ');
        while (it.next()) |token| {
            if (std.mem.eql(u8, token, cap)) return true;
            // A valued capability, `object-format=sha1`, matches on its
            // name alone.
            if (std.mem.indexOfScalar(u8, token, '=')) |eq| {
                if (std.mem.eql(u8, token[0..eq], cap)) return true;
            }
        }
        return false;
    }
};

/// Reads the advertisement receive-pack opens with.
///
/// Every line is `<oid> <refname>`, and the first carries the capability
/// list after a NUL. A repository with no refs sends one line naming
/// `capabilities^{}` with the zero id, which is not a ref and is not
/// returned as one.
pub fn readAdvertisement(
    gpa: Allocator,
    f: Format,
    r: *std.Io.Reader,
    buf: []u8,
) Error!Advertisement {
    var refs: std.ArrayList(Ref) = .empty;
    errdefer {
        for (refs.items) |item| gpa.free(item.name);
        refs.deinit(gpa);
    }
    var caps: []const u8 = &.{};
    errdefer gpa.free(caps);

    var first = true;
    while (true) {
        const packet = try pktline_mod.read(r, buf);
        switch (packet) {
            .flush => break,
            .delimiter, .response_end => return error.ProtocolError,
            .data => |line_raw| {
                // Every line ends with a newline, after the capabilities
                // on the first one.
                const line = std.mem.trimEnd(u8, line_raw, "\n");

                var payload = line;
                if (first) {
                    first = false;
                    if (std.mem.indexOfScalar(u8, line, 0)) |nul| {
                        payload = line[0..nul];
                        caps = try gpa.dupe(u8, line[nul + 1 ..]);
                    }
                }

                const sp = std.mem.indexOfScalar(u8, payload, ' ') orelse
                    return error.ProtocolError;
                const oid = Oid.parse(f, payload[0..sp]) catch return error.ProtocolError;
                const name = payload[sp + 1 ..];
                if (name.len == 0) return error.ProtocolError;
                if (std.mem.eql(u8, name, no_refs_marker)) continue;

                try refs.append(gpa, .{ .name = try gpa.dupe(u8, name), .oid = oid });
            },
        }
    }

    return .{
        .refs = try refs.toOwnedSlice(gpa),
        .capabilities = caps,
        .gpa = gpa,
    };
}

/// One ref update. `old` is the value we expect the remote to hold, which
/// the remote checks before it moves anything: sending it is the lease.
/// The zero id as `old` creates, and as `new` deletes.
pub const Command = struct {
    name: []const u8,
    old: Oid,
    new: Oid,

    pub fn isDelete(c: Command) bool {
        return c.new.isZero();
    }
};

/// Writes the command list, then the flush that ends it. The pack, when
/// there is one, follows straight after.
///
/// Git sends no newline inside a command line, unlike the advertisement,
/// and the capabilities ride on the first line after a NUL.
pub fn writeCommands(
    gpa: Allocator,
    w: *std.Io.Writer,
    commands: []const Command,
    capabilities: []const u8,
) (WriteError || Allocator.Error)!void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);

    for (commands, 0..) |c, i| {
        line.clearRetainingCapacity();
        var hex_old: [Oid.max_formatted_length]u8 = undefined;
        var hex_new: [Oid.max_formatted_length]u8 = undefined;
        try line.appendSlice(gpa, c.old.toHex(&hex_old));
        try line.append(gpa, ' ');
        try line.appendSlice(gpa, c.new.toHex(&hex_new));
        try line.append(gpa, ' ');
        try line.appendSlice(gpa, c.name);
        if (i == 0 and capabilities.len > 0) {
            try line.append(gpa, 0);
            try line.appendSlice(gpa, capabilities);
        }
        try pktline_mod.write(w, .{ .data = line.items });
    }
    try pktline_mod.write(w, .flush);
}

pub const RefStatus = struct {
    name: []const u8, // owned
    /// False when the remote answered `ng`, which is a refused update.
    accepted: bool,
    /// The remote's reason, present only on a refusal. `non-fast-forward`
    /// is what a failed lease reports.
    reason: ?[]const u8, // owned
};

pub const Report = struct {
    /// False when the remote could not store the pack at all, in which
    /// case no ref moved.
    unpacked: bool,
    unpack_detail: ?[]const u8, // owned
    refs: []RefStatus, // owned
    gpa: Allocator,

    pub fn deinit(rep: *Report) void {
        for (rep.refs) |r| {
            rep.gpa.free(r.name);
            if (r.reason) |reason| rep.gpa.free(reason);
        }
        rep.gpa.free(rep.refs);
        if (rep.unpack_detail) |d| rep.gpa.free(d);
        rep.refs = &.{};
        rep.unpack_detail = null;
    }

    /// True when the pack landed and every ref moved.
    pub fn ok(rep: Report) bool {
        if (!rep.unpacked) return false;
        for (rep.refs) |r| {
            if (!r.accepted) return false;
        }
        return true;
    }

    pub fn find(rep: Report, name: []const u8) ?RefStatus {
        for (rep.refs) |r| {
            if (std.mem.eql(u8, r.name, name)) return r;
        }
        return null;
    }
};

/// Reads `report-status`: one `unpack` line, then one line per ref, then
/// a flush.
pub fn readReport(gpa: Allocator, r: *std.Io.Reader, buf: []u8) Error!Report {
    var statuses: std.ArrayList(RefStatus) = .empty;
    errdefer {
        for (statuses.items) |s| {
            gpa.free(s.name);
            if (s.reason) |reason| gpa.free(reason);
        }
        statuses.deinit(gpa);
    }

    var unpacked: ?bool = null;
    var unpack_detail: ?[]const u8 = null;
    errdefer if (unpack_detail) |d| gpa.free(d);

    while (true) {
        const packet = try pktline_mod.read(r, buf);
        switch (packet) {
            .flush => break,
            .delimiter, .response_end => return error.ProtocolError,
            .data => |raw| {
                const line = std.mem.trimEnd(u8, raw, "\n");
                if (std.mem.startsWith(u8, line, "unpack ")) {
                    const detail = line["unpack ".len..];
                    unpacked = std.mem.eql(u8, detail, "ok");
                    if (unpacked == false) unpack_detail = try gpa.dupe(u8, detail);
                } else if (std.mem.startsWith(u8, line, "ok ")) {
                    const name = line["ok ".len..];
                    if (name.len == 0) return error.ProtocolError;
                    try statuses.append(gpa, .{
                        .name = try gpa.dupe(u8, name),
                        .accepted = true,
                        .reason = null,
                    });
                } else if (std.mem.startsWith(u8, line, "ng ")) {
                    const rest = line["ng ".len..];
                    const sp = std.mem.indexOfScalar(u8, rest, ' ');
                    const name = if (sp) |s| rest[0..s] else rest;
                    if (name.len == 0) return error.ProtocolError;
                    const reason = if (sp) |s| try gpa.dupe(u8, rest[s + 1 ..]) else null;
                    try statuses.append(gpa, .{
                        .name = try gpa.dupe(u8, name),
                        .accepted = false,
                        .reason = reason,
                    });
                } else {
                    return error.ProtocolError;
                }
            },
        }
    }

    // A report with no `unpack` line is not a report. Treating a missing
    // one as success would turn a broken server into a silent success.
    if (unpacked == null) return error.ProtocolError;

    return .{
        .unpacked = unpacked.?,
        .unpack_detail = unpack_detail,
        .refs = try statuses.toOwnedSlice(gpa),
        .gpa = gpa,
    };
}

const testing = std.testing;

/// Scratch for `pktline.read`, which needs a full packet's worth.
fn pktBuf(gpa: Allocator) ![]u8 {
    return gpa.alloc(u8, pktline_mod.Packet.max_data_length);
}

// Captured from `git receive-pack` 2.56.0 against a bare repository, bytes
// unchanged. The trailing newline sits after the capability list, not
// before it.
const adv_multi =
    "00b79f5fa11f84d9028a65c36e4821fe7a5a8691c222 refs/heads/main\x00" ++
    "report-status report-status-v2 delete-refs side-band-64k quiet atomic " ++
    "ofs-delta object-format=sha1 agent=git/2.56.0-Linux\n" ++
    "003f606e37bceb6a844dca60217141cf578a10cae26d refs/heads/second\n" ++
    "003c606e37bceb6a844dca60217141cf578a10cae26d refs/tags/vtag\n" ++
    "0000";

const adv_empty =
    "00b70000000000000000000000000000000000000000 capabilities^{}\x00" ++
    "report-status report-status-v2 delete-refs side-band-64k quiet atomic " ++
    "ofs-delta object-format=sha1 agent=git/2.56.0-Linux\n" ++
    "0000";

test "the advertisement yields every ref and the capability list" {
    const gpa = testing.allocator;
    const buf = try pktBuf(gpa);
    defer gpa.free(buf);
    var r: std.Io.Reader = .fixed(adv_multi);

    var adv = try readAdvertisement(gpa, .sha1, &r, buf);
    defer adv.deinit();

    try testing.expectEqual(@as(usize, 3), adv.refs.len);
    try testing.expectEqualStrings("refs/heads/main", adv.refs[0].name);
    try testing.expectEqualStrings("refs/heads/second", adv.refs[1].name);
    try testing.expectEqualStrings("refs/tags/vtag", adv.refs[2].name);

    // The newline must not survive into the last capability.
    try testing.expect(adv.supports("report-status"));
    try testing.expect(adv.supports("agent"));
    try testing.expect(adv.supports("object-format"));
    try testing.expect(!adv.supports("push-cert"));
    try testing.expect(std.mem.indexOfScalar(u8, adv.capabilities, '\n') == null);
}

test "find answers with the id the remote holds, and null for an absent ref" {
    const gpa = testing.allocator;
    const buf = try pktBuf(gpa);
    defer gpa.free(buf);
    var r: std.Io.Reader = .fixed(adv_multi);
    var adv = try readAdvertisement(gpa, .sha1, &r, buf);
    defer adv.deinit();

    const main = adv.find("refs/heads/main") orelse return error.TestExpectedRef;
    var hex: [Oid.max_formatted_length]u8 = undefined;
    try testing.expectEqualStrings("9f5fa11f84d9028a65c36e4821fe7a5a8691c222", main.toHex(&hex));
    try testing.expect(adv.find("refs/heads/absent") == null);
}

test "an empty repository advertises no refs, not one called capabilities" {
    const gpa = testing.allocator;
    const buf = try pktBuf(gpa);
    defer gpa.free(buf);
    var r: std.Io.Reader = .fixed(adv_empty);

    var adv = try readAdvertisement(gpa, .sha1, &r, buf);
    defer adv.deinit();

    try testing.expectEqual(@as(usize, 0), adv.refs.len);
    try testing.expect(adv.supports("report-status"));
}

test "a command carries the expected old id, which is the lease" {
    const gpa = testing.allocator;
    const old = try Oid.parse(.sha1, "9f5fa11f84d9028a65c36e4821fe7a5a8691c222");
    const new = try Oid.parse(.sha1, "23998739ef0634a3e3efd3d599cfa4b9294ddb5c");

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const commands = [_]Command{.{ .name = "refs/heads/main", .old = old, .new = new }};
    try writeCommands(gpa, &aw.writer, &commands, "report-status");

    try testing.expectEqualStrings(
        "0073" ++
            "9f5fa11f84d9028a65c36e4821fe7a5a8691c222 " ++
            "23998739ef0634a3e3efd3d599cfa4b9294ddb5c refs/heads/main\x00report-status" ++
            "0000",
        aw.written(),
    );
}

test "only the first command carries capabilities" {
    const gpa = testing.allocator;
    const z: Oid = .zero(.sha1);
    const new = try Oid.parse(.sha1, "23998739ef0634a3e3efd3d599cfa4b9294ddb5c");

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const commands = [_]Command{
        .{ .name = "refs/heads/one", .old = z, .new = new },
        .{ .name = "refs/heads/two", .old = z, .new = new },
    };
    try writeCommands(gpa, &aw.writer, &commands, "report-status");

    const written = aw.written();
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, written, "\x00"));
    try testing.expect(std.mem.endsWith(u8, written, "0000"));
}

test "a delete sends the zero id as the new value" {
    const gpa = testing.allocator;
    const old = try Oid.parse(.sha1, "9f5fa11f84d9028a65c36e4821fe7a5a8691c222");
    const c: Command = .{ .name = "refs/heads/doomed", .old = old, .new = .zero(.sha1) };
    try testing.expect(c.isDelete());

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try writeCommands(gpa, &aw.writer, &.{c}, "");
    try testing.expect(std.mem.indexOf(
        u8,
        aw.written(),
        "0000000000000000000000000000000000000000 refs/heads/doomed",
    ) != null);
}

test "an accepted report reads as ok" {
    const gpa = testing.allocator;
    const buf = try pktBuf(gpa);
    defer gpa.free(buf);
    var r: std.Io.Reader = .fixed("000eunpack ok\n0017ok refs/heads/main\n0000");

    var rep = try readReport(gpa, &r, buf);
    defer rep.deinit();
    try testing.expect(rep.ok());
    try testing.expectEqual(@as(usize, 1), rep.refs.len);
    try testing.expect(rep.refs[0].accepted);
}

test "a refused ref carries the remote's reason and is not ok" {
    const gpa = testing.allocator;
    const buf = try pktBuf(gpa);
    defer gpa.free(buf);
    // The bytes receive-pack sends when a lease fails.
    var r: std.Io.Reader = .fixed(
        "000eunpack ok\n0028ng refs/heads/main non-fast-forward\n0000",
    );

    var rep = try readReport(gpa, &r, buf);
    defer rep.deinit();
    try testing.expect(!rep.ok());
    try testing.expect(rep.unpacked);
    const status = rep.find("refs/heads/main") orelse return error.TestExpectedRef;
    try testing.expect(!status.accepted);
    try testing.expectEqualStrings("non-fast-forward", status.reason.?);
}

test "a failed unpack is not ok even with no ref lines" {
    const gpa = testing.allocator;
    const buf = try pktBuf(gpa);
    defer gpa.free(buf);
    var r: std.Io.Reader = .fixed("001bunpack index-pack died\n0000");

    var rep = try readReport(gpa, &r, buf);
    defer rep.deinit();
    try testing.expect(!rep.ok());
    try testing.expectEqualStrings("index-pack died", rep.unpack_detail.?);
}

test "a report with no unpack line is refused rather than read as success" {
    const gpa = testing.allocator;
    const buf = try pktBuf(gpa);
    defer gpa.free(buf);
    var r: std.Io.Reader = .fixed("0017ok refs/heads/main\n0000");
    try testing.expectError(error.ProtocolError, readReport(gpa, &r, buf));
}
