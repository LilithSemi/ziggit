//! The `ls-refs` command: write a request, then read the ref list a server
//! answers it with.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;

const pktline_mod = @import("ziggit-pktline");

const capability_mod = @import("Capability.zig");
pub const ParseError = capability_mod.ParseError;

/// One ref line from an `ls-refs` response.
pub const RefLine = struct {
    oid: Oid,
    name: []const u8, // owned by this RefLine, freed by deinit
    peeled: ?Oid,
    symref_target: ?[]const u8, // owned by this RefLine, freed by deinit

    pub fn deinit(r: *RefLine, gpa: Allocator) void {
        gpa.free(r.name);
        if (r.symref_target) |t| gpa.free(t);
        r.* = undefined;
    }
};

pub const LsRefsOptions = struct {
    prefixes: []const []const u8 = &.{},
    symrefs: bool = true,
    peel: bool = true,
};

/// Writes an `ls-refs` request: the command, an `object-format` capability
/// when `f` is not the implicit sha1, the delimiter, then the requested
/// arguments, then the flush that ends the request.
pub fn writeLsRefs(w: *std.Io.Writer, f: Format, o: LsRefsOptions) pktline_mod.WriteError!void {
    try pktline_mod.writeLine(w, "command=ls-refs");
    if (f == .sha256) try pktline_mod.writeLine(w, "object-format=sha256");
    try pktline_mod.write(w, .delimiter);

    if (o.symrefs) try pktline_mod.writeLine(w, "symrefs");
    if (o.peel) try pktline_mod.writeLine(w, "peel");
    for (o.prefixes) |prefix| {
        var line_buf: [11 + 4096]u8 = undefined; // "ref-prefix " + a generous refname
        var fbs: std.Io.Writer = .fixed(&line_buf);
        fbs.writeAll("ref-prefix ") catch return error.PktLineTooLong;
        fbs.writeAll(prefix) catch return error.PktLineTooLong;
        try pktline_mod.writeLine(w, fbs.buffered());
    }

    try pktline_mod.write(w, .flush);
}

/// Reads an `ls-refs` response: one ref line per pkt-line, up to the flush
/// pkt-line that ends it.
pub fn readLsRefs(gpa: Allocator, f: Format, r: *std.Io.Reader, buf: []u8) ParseError![]RefLine {
    var list: std.ArrayList(RefLine) = .empty;
    errdefer {
        for (list.items) |*ref| ref.deinit(gpa);
        list.deinit(gpa);
    }

    while (true) {
        const packet = pktline_mod.read(r, buf) catch |err| return mapReadError(err);
        switch (packet) {
            .flush => break,
            .delimiter, .response_end => return error.ProtocolError,
            .data => |data| {
                const line = trimNewline(data);
                const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return error.ProtocolError;
                const oid = Oid.parse(f, line[0..sp]) catch return error.ProtocolError;
                const rest = line[sp + 1 ..];
                if (rest.len == 0) return error.ProtocolError;

                var it = std.mem.tokenizeScalar(u8, rest, ' ');
                const name_src = it.next() orelse return error.ProtocolError;
                const name = try gpa.dupe(u8, name_src);
                errdefer gpa.free(name);

                var peeled: ?Oid = null;
                var symref_target: ?[]const u8 = null;
                errdefer if (symref_target) |t| gpa.free(t);

                while (it.next()) |attr| {
                    if (std.mem.startsWith(u8, attr, "symref-target:")) {
                        if (symref_target != null) return error.ProtocolError;
                        symref_target = try gpa.dupe(u8, attr["symref-target:".len..]);
                    } else if (std.mem.startsWith(u8, attr, "peeled:")) {
                        if (peeled != null) return error.ProtocolError;
                        peeled = Oid.parse(f, attr["peeled:".len..]) catch return error.ProtocolError;
                    } else {
                        return error.ProtocolError;
                    }
                }

                try list.append(gpa, .{ .oid = oid, .name = name, .peeled = peeled, .symref_target = symref_target });
            },
        }
    }

    return list.toOwnedSlice(gpa);
}

fn trimNewline(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\n') return line[0 .. line.len - 1];
    return line;
}

/// Every pkt-line fault, truncation included, becomes `error.ProtocolError`:
/// `ParseError` carries no lower-level read error, by design.
fn mapReadError(_: pktline_mod.ReadError) ParseError {
    return error.ProtocolError;
}

// Byte-exact vector, captured from real git 2.55.0 with:
//   cd /tmp/protovec/r   # the repository from Capability.zig's vector comment,
//                        # which also carries an annotated tag "v1"
//   printf '0014command=ls-refs\n0013agent=test/1.0\n0001000csymrefs\n0009peel\n0000' \
//     | GIT_PROTOCOL=version=2 git upload-pack --stateless-rpc . > lsrefs.raw
const ls_refs_response_vector =
    "0052f84b93de622a59266138347cf963fe97cfb339fd HEAD symref-target:refs/heads/master\x0a003ff84" ++
    "b93de622a59266138347cf963fe97cfb339fd refs/heads/master\x0a006a7ee3c738f0b2aedf9d3b2677d92d0" ++
    "2d2c7216b8c refs/tags/v1 peeled:f84b93de622a59266138347cf963fe97cfb339fd\x0a0000";
// length: 255 bytes

// expected

test "readLsRefs reads an oid, a name and a peeled tag" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed(ls_refs_response_vector);
    var buf: [pktline_mod.Packet.max_data_length]u8 = undefined;

    const refs = try readLsRefs(gpa, .sha1, &r, &buf);
    defer {
        for (refs) |*ref| ref.deinit(gpa);
        gpa.free(refs);
    }

    try std.testing.expectEqual(@as(usize, 3), refs.len);

    const tag = refs[2];
    try std.testing.expectEqualStrings("refs/tags/v1", tag.name);
    var oid_buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("7ee3c738f0b2aedf9d3b2677d92d02d2c7216b8c", tag.oid.toHex(&oid_buf));
    var peeled_buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings("f84b93de622a59266138347cf963fe97cfb339fd", tag.peeled.?.toHex(&peeled_buf));
}

test "readLsRefs reads the symref target of HEAD" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed(ls_refs_response_vector);
    var buf: [pktline_mod.Packet.max_data_length]u8 = undefined;

    const refs = try readLsRefs(gpa, .sha1, &r, &buf);
    defer {
        for (refs) |*ref| ref.deinit(gpa);
        gpa.free(refs);
    }

    const head = refs[0];
    try std.testing.expectEqualStrings("HEAD", head.name);
    try std.testing.expectEqualStrings("refs/heads/master", head.symref_target.?);
}

test "writeLsRefs emits the prefixes it was given" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeLsRefs(&w, .sha1, .{ .prefixes = &.{ "refs/heads/", "refs/tags/" }, .symrefs = false, .peel = false });

    const written = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "ref-prefix refs/heads/\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "ref-prefix refs/tags/\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "symrefs") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "peel") == null);
}

// suspicious

test "readLsRefs rejects a line whose oid is not valid hex" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed("002fnot-hex-at-all-not-hex-at-all refs/heads/x\n0000");
    var buf: [pktline_mod.Packet.max_data_length]u8 = undefined;

    try std.testing.expectError(error.ProtocolError, readLsRefs(gpa, .sha1, &r, &buf));
}

test "readLsRefs rejects a line with no space after the oid" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed("002df84b93de622a59266138347cf963fe97cfb339fd\n0000");
    var buf: [pktline_mod.Packet.max_data_length]u8 = undefined;

    try std.testing.expectError(error.ProtocolError, readLsRefs(gpa, .sha1, &r, &buf));
}

test "readLsRefs rejects a ref line with two symref-target attributes" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed("007ff84b93de622a59266138347cf963fe97cfb339fd HEAD symref-target:refs/heads/master symref-target:refs/heads/main\n0000");
    var buf: [pktline_mod.Packet.max_data_length]u8 = undefined;

    try std.testing.expectError(error.ProtocolError, readLsRefs(gpa, .sha1, &r, &buf));
}

test "readLsRefs rejects a ref line with two peeled attributes" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed("0077f84b93de622a59266138347cf963fe97cfb339fd refs/tags/v1 peeled:7ee3c738f0b2aedf9d3b2677d92d02d2c7216b8c peeled:f84b93de622a59266138347cf963fe97cfb339fd\n0000");
    var buf: [pktline_mod.Packet.max_data_length]u8 = undefined;

    try std.testing.expectError(error.ProtocolError, readLsRefs(gpa, .sha1, &r, &buf));
}
