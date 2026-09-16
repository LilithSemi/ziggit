//! The `fetch` command: write a request, then read the sequence of
//! sections a server answers it with.
//!
//! A v2 fetch response is not one shape; it is a sequence of independently
//! framed sections (RFC-less, but documented in git's own
//! `Documentation/technical/protocol-v2.txt`). `readFetchSection` reads
//! exactly one and returns `.end` once there are no more; it never tries to
//! read a whole response in a single call.

const std = @import("std");
const Allocator = std.mem.Allocator;

const oid_mod = @import("ziggit-oid");
const Format = oid_mod.Format;
const Oid = oid_mod.Oid;

const pktline_mod = @import("ziggit-pktline");

const capability_mod = @import("Capability.zig");
pub const ParseError = capability_mod.ParseError;

const ls_refs_mod = @import("ls_refs.zig");
const RefLine = ls_refs_mod.RefLine;

pub const FetchRequest = struct {
    wants: []const Oid,
    haves: []const Oid = &.{},
    done: bool = false,
    depth: ?u32 = null,
    shallows: []const Oid = &.{},
    include_tag: bool = false,
    thin_pack: bool = false,
    ofs_delta: bool = true,
};

/// Writes a `fetch` request: the command, an `object-format` capability
/// when `f` is not the implicit sha1, the delimiter, then every argument
/// `req` asks for, then the flush that ends the request.
pub fn writeFetch(w: *std.Io.Writer, f: Format, req: FetchRequest) pktline_mod.WriteError!void {
    try pktline_mod.writeLine(w, "command=fetch");
    if (f == .sha256) try pktline_mod.writeLine(w, "object-format=sha256");
    try pktline_mod.write(w, .delimiter);

    if (req.thin_pack) try pktline_mod.writeLine(w, "thin-pack");
    if (req.ofs_delta) try pktline_mod.writeLine(w, "ofs-delta");
    if (req.include_tag) try pktline_mod.writeLine(w, "include-tag");

    for (req.shallows) |s| try writeOidLine(w, "shallow", s);
    if (req.depth) |d| {
        var digits: [10]u8 = undefined;
        const n = std.fmt.printInt(&digits, d, 10, .lower, .{});
        var line_buf: [7 + 10]u8 = undefined;
        var fbs: std.Io.Writer = .fixed(&line_buf);
        fbs.writeAll("deepen ") catch return error.PktLineTooLong;
        fbs.writeAll(digits[0..n]) catch return error.PktLineTooLong;
        try pktline_mod.writeLine(w, fbs.buffered());
    }

    for (req.wants) |o| try writeOidLine(w, "want", o);
    for (req.haves) |o| try writeOidLine(w, "have", o);
    if (req.done) try pktline_mod.writeLine(w, "done");

    try pktline_mod.write(w, .flush);
}

fn writeOidLine(w: *std.Io.Writer, prefix: []const u8, oid: Oid) pktline_mod.WriteError!void {
    var hex_buf: [Oid.max_formatted_length]u8 = undefined;
    const hex = oid.toHex(&hex_buf);
    var line_buf: [16 + Oid.max_formatted_length]u8 = undefined;
    var fbs: std.Io.Writer = .fixed(&line_buf);
    fbs.writeAll(prefix) catch return error.PktLineTooLong;
    fbs.writeByte(' ') catch return error.PktLineTooLong;
    fbs.writeAll(hex) catch return error.PktLineTooLong;
    try pktline_mod.writeLine(w, fbs.buffered());
}

/// One section of the server's answer to `fetch`. A v2 response is a
/// sequence of these; call `readFetchSection` repeatedly until it returns
/// `.end`.
pub const FetchSection = union(enum) {
    /// The server acknowledged some haves and wants another round.
    acknowledgments: struct { acks: []const Oid, ready: bool }, // owned, freed by deinit
    /// Negotiation finished with no common commit.
    nak,
    shallow_info: struct { shallow: []const Oid, unshallow: []const Oid }, // owned, freed by deinit
    wanted_refs: []const RefLine, // owned, freed by deinit
    /// Pack data follows. Wrap the reader in a `Sideband` to read it.
    packfile,
    /// No more sections.
    end,

    pub fn deinit(s: *FetchSection, gpa: Allocator) void {
        switch (s.*) {
            .acknowledgments => |a| gpa.free(a.acks),
            .shallow_info => |si| {
                gpa.free(si.shallow);
                gpa.free(si.unshallow);
            },
            .wanted_refs => |refs| {
                for (refs) |ref| {
                    gpa.free(ref.name);
                    if (ref.symref_target) |t| gpa.free(t);
                }
                gpa.free(refs);
            },
            .nak, .packfile, .end => {},
        }
        s.* = undefined;
    }
};

/// Reads exactly one section of a `fetch` response.
///
/// In protocol v2, an acknowledgments section may be followed by a flush
/// with no packfile section, which means the server is asking to negotiate
/// again. A caller that loops `readFetchSection` until `.end` will receive
/// a read error on the exhausted reader in that case, not a synthesized
/// `.end`.
pub fn readFetchSection(gpa: Allocator, f: Format, r: *std.Io.Reader, buf: []u8) ParseError!FetchSection {
    const packet = pktline_mod.read(r, buf) catch |err| return mapReadError(err);
    const header = switch (packet) {
        .flush => return .end,
        .delimiter, .response_end => return error.ProtocolError,
        .data => |d| trimNewline(d),
    };

    if (std.mem.eql(u8, header, "acknowledgments")) return readAcknowledgments(gpa, f, r, buf);
    if (std.mem.eql(u8, header, "shallow-info")) return readShallowInfo(gpa, f, r, buf);
    if (std.mem.eql(u8, header, "wanted-refs")) return readWantedRefs(gpa, f, r, buf);
    if (std.mem.eql(u8, header, "packfile")) return .packfile;
    // Includes "packfile-uris": this module never requests that capability,
    // so a server sending it anyway is treated the same as any other
    // section header this module does not know.
    return error.ProtocolError;
}

fn readAcknowledgments(gpa: Allocator, f: Format, r: *std.Io.Reader, buf: []u8) ParseError!FetchSection {
    var acks: std.ArrayList(Oid) = .empty;
    errdefer acks.deinit(gpa);
    var ready = false;
    var saw_nak = false;

    while (true) {
        const packet = pktline_mod.read(r, buf) catch |err| return mapReadError(err);
        switch (packet) {
            .flush, .delimiter => break,
            .response_end => return error.ProtocolError,
            .data => |data| {
                const line = trimNewline(data);
                if (std.mem.eql(u8, line, "NAK")) {
                    saw_nak = true;
                } else if (std.mem.eql(u8, line, "ready")) {
                    ready = true;
                } else if (std.mem.startsWith(u8, line, "ACK ")) {
                    const oid = Oid.parse(f, line["ACK ".len..]) catch return error.ProtocolError;
                    try acks.append(gpa, oid);
                } else {
                    return error.ProtocolError;
                }
            },
        }
    }

    if (saw_nak) {
        acks.deinit(gpa);
        return .nak;
    }
    return .{ .acknowledgments = .{ .acks = try acks.toOwnedSlice(gpa), .ready = ready } };
}

fn readShallowInfo(gpa: Allocator, f: Format, r: *std.Io.Reader, buf: []u8) ParseError!FetchSection {
    var shallow: std.ArrayList(Oid) = .empty;
    errdefer shallow.deinit(gpa);
    var unshallow: std.ArrayList(Oid) = .empty;
    errdefer unshallow.deinit(gpa);

    while (true) {
        const packet = pktline_mod.read(r, buf) catch |err| return mapReadError(err);
        switch (packet) {
            .flush, .delimiter => break,
            .response_end => return error.ProtocolError,
            .data => |data| {
                // Unlike most section body lines, git writes these two
                // without a trailing newline; `trimNewline` copes with
                // either, so this still works if that ever changes.
                const line = trimNewline(data);
                if (std.mem.startsWith(u8, line, "shallow ")) {
                    const oid = Oid.parse(f, line["shallow ".len..]) catch return error.ProtocolError;
                    try shallow.append(gpa, oid);
                } else if (std.mem.startsWith(u8, line, "unshallow ")) {
                    const oid = Oid.parse(f, line["unshallow ".len..]) catch return error.ProtocolError;
                    try unshallow.append(gpa, oid);
                } else {
                    return error.ProtocolError;
                }
            },
        }
    }

    return .{ .shallow_info = .{
        .shallow = try shallow.toOwnedSlice(gpa),
        .unshallow = try unshallow.toOwnedSlice(gpa),
    } };
}

fn readWantedRefs(gpa: Allocator, f: Format, r: *std.Io.Reader, buf: []u8) ParseError!FetchSection {
    var list: std.ArrayList(RefLine) = .empty;
    errdefer {
        for (list.items) |*ref| ref.deinit(gpa);
        list.deinit(gpa);
    }

    while (true) {
        const packet = pktline_mod.read(r, buf) catch |err| return mapReadError(err);
        switch (packet) {
            .flush, .delimiter => break,
            .response_end => return error.ProtocolError,
            .data => |data| {
                const line = trimNewline(data);
                const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return error.ProtocolError;
                const oid = Oid.parse(f, line[0..sp]) catch return error.ProtocolError;
                const name_src = line[sp + 1 ..];
                if (name_src.len == 0) return error.ProtocolError;
                const name = try gpa.dupe(u8, name_src);
                errdefer gpa.free(name);
                try list.append(gpa, .{ .oid = oid, .name = name, .peeled = null, .symref_target = null });
            },
        }
    }

    return .{ .wanted_refs = try list.toOwnedSlice(gpa) };
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

// Byte-exact vectors, captured from real git 2.55.0 against the repository
// from Capability.zig's vector comment (one commit "one" on master, tag
// "v1"), by driving `upload-pack --stateless-rpc` with a `command=fetch`
// body:
//
//   COMMIT=$(git rev-parse master)
//   printf '0012command=fetch\n0013agent=test/1.0\n0001%s%s0000' \
//     "$(pkt "want $COMMIT")" "$(pkt "have $COMMIT")" \
//     | GIT_PROTOCOL=version=2 git upload-pack --stateless-rpc . > fetch_ack.raw
//
// (`pkt` computes the 4 hex digit pkt-line header for its argument.) This
// response carries an acknowledgments section that goes straight to
// "ready", then a packfile section with a sideband band 2 progress line and
// band 1 pack bytes.
const fetch_ack_response_vector =
    "0014acknowledgments\x0a0031ACK f84b93de622a59266138347cf963fe97cfb339fd\x0a000aready\x0a0001" ++
    "000dpackfile\x0a0043\x02Total 0 (delta 0), reused 0 (delta 0), pack-reused 0 (from 0)\x0a002" ++
    "4\x01PACK\x00\x00\x00\x02\x00\x00\x00\x00\x02\x9d\x08\x82;\xd8\xa8\xea\xb5\x10\xadj\xc7\x5c" ++
    "\x82<\xfd>\xd30006\x01\x1e0000";
// length: 209 bytes

// A second repository with four linear commits c1..c4. The request declares
// the client already shallow at c3 and asks to deepen to include c2 (but
// not c1):
//
//   printf '0012command=fetch\n0013agent=test/1.0\n0001%s%s%s%s0000' \
//     "$(pkt "want $C4")" "$(pkt "shallow $C3")" "$(pkt "deepen 3")" "$(pkt "done")" \
//     | GIT_PROTOCOL=version=2 git upload-pack --stateless-rpc . > fetch_shallow.raw
//
// The response carries a shallow-info section with both a "shallow" and an
// "unshallow" line (neither newline-terminated, unlike every other section
// body line git writes), then a packfile section.
const fetch_shallow_response_vector =
    "0011shallow-info\x0a0034shallow 8e6a76775124063ed8b40b8480560d52bede4e740036unshallow 04f3e2" ++
    "724ee8fd3046305a4049c3ef7573e4e3620001000dpackfile\x0a0081\x02Enumerating objects: 2, done." ++
    "\x0aCounting objects:  50% (1/2)\x0dCounting objects: 100% (2/2)\x0dCounting objects: 100% (" ++
    "2/2), done.\x0a0045\x02Compressing objects:  50% (1/2)\x0dCompressing objects: 100% (2/2)" ++
    "\x0d002c\x02Compressing objects: 100% (2/2), done.\x0a0043\x02Total 2 (delta 0), reused 0 (d" ++
    "elta 0), pack-reused 0 (from 0)\x0a011b\x01PACK\x00\x00\x00\x02\x00\x00\x00\x02\x95\x0ax\x9c" ++
    "}\xcaA\x0eB!\x0c\x05\xc0=\xa7\xe0\x02&\x95\x96\x16\x12c\xbcJ\x81Gt\xf1\xfd\x86\xe0\xfd\xbd" ++
    "\x81\xb3\x9e\xbd\x80(\xad\xa4<\xbaJ\xeaM\xd1\xaa\x93\x12\xb2\xb4Y\x86\xd6T\xcal\x80T\x92\xf0" ++
    "\xf1\x85\xf7\x8e$\x93\x91,\x09P\xe6`\x12e\xca.$\xb53\xa6ec\x08XS\xf0\xef~\x9e+z\xbc\xf9\xa3" ++
    "\xdd\xe3\xd5J\xcd\xc6f\x1a/dD\xa1\x9f\xc7\xf1\xda\x1b\x7fJ\xe8\x12~\x11\xb6,%\x95\x0ax\x9c}" ++
    "\xca\xcb\x0d\xc20\x0c\x00\xd0{\xa6\xc8\x02Hn\xe2\xf8#!\xc4*qb\x0b\x0e\xa5\xa8\x0a\xfbw\x03" ++
    "\xde\xf9\xad\xd3=\xa3Iis\x10\x96a\xe4\xa6\x1d\x08\xbc\xa1\x85L\xd2\x22\x12\xe6\x8e\x0a\x98" ++
    "\xbe\xfd\xf4\xcf\xca\x5c\xc5\x84\x1a6\x0c\x8f\x02\xa8\x13i\xf0\xa4p\x0d\x06!h\xb5\xa2l\x9e" ++
    "\xfao\xbd\x8e3\xf7|\xefO{\xe4\x8dE\x1bWf\xca7`\x804\x8e}\x7f\xaf\xe5\x7fJ\x1a%]\x0b\x17,\x11" ++
    "\xde\x97k\xf3\xf9\xdeL\x01^8\x85\xd0\xe6$fa\xc73o0006\x01\xac0000";
// length: 742 bytes

// expected

test "writeFetch emits one want line per oid" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const a = try Oid.parse(.sha1, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const b = try Oid.parse(.sha1, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    try writeFetch(&w, .sha1, .{ .wants = &.{ a, b } });

    const written = w.buffered();
    try std.testing.expectEqual(2, std.mem.count(u8, written, "want "));
    try std.testing.expect(std.mem.indexOf(u8, written, "want aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "want bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n") != null);
}

test "writeFetch emits have lines and a done line" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const a = try Oid.parse(.sha1, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    const c = try Oid.parse(.sha1, "cccccccccccccccccccccccccccccccccccccccc");
    try writeFetch(&w, .sha1, .{ .wants = &.{a}, .haves = &.{c}, .done = true });

    const written = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "have cccccccccccccccccccccccccccccccccccccccc\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "done\n") != null);
}

test "writeFetch emits a deepen line when depth is set" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const a = try Oid.parse(.sha1, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    try writeFetch(&w, .sha1, .{ .wants = &.{a}, .depth = 5 });

    const written = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, written, "deepen 5\n") != null);
}

test "readFetchSection reads an acknowledgments section" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed(fetch_ack_response_vector);
    var buf: [pktline_mod.Packet.max_data_length]u8 = undefined;

    var section = try readFetchSection(gpa, .sha1, &r, &buf);
    defer section.deinit(gpa);

    try std.testing.expect(section == .acknowledgments);
    try std.testing.expectEqual(@as(usize, 1), section.acknowledgments.acks.len);
    var oid_buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings(
        "f84b93de622a59266138347cf963fe97cfb339fd",
        section.acknowledgments.acks[0].toHex(&oid_buf),
    );
}

test "readFetchSection reports ready in the acknowledgments section" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed(fetch_ack_response_vector);
    var buf: [pktline_mod.Packet.max_data_length]u8 = undefined;

    var section = try readFetchSection(gpa, .sha1, &r, &buf);
    defer section.deinit(gpa);

    try std.testing.expect(section.acknowledgments.ready);

    // The delimiter after "ready" ends this section; the next call reads
    // the packfile section that follows it in the same response.
    var next = try readFetchSection(gpa, .sha1, &r, &buf);
    defer next.deinit(gpa);
    try std.testing.expect(next == .packfile);
}

test "readFetchSection reads shallow and unshallow lines" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed(fetch_shallow_response_vector);
    var buf: [pktline_mod.Packet.max_data_length]u8 = undefined;

    var section = try readFetchSection(gpa, .sha1, &r, &buf);
    defer section.deinit(gpa);

    try std.testing.expect(section == .shallow_info);
    try std.testing.expectEqual(@as(usize, 1), section.shallow_info.shallow.len);
    try std.testing.expectEqual(@as(usize, 1), section.shallow_info.unshallow.len);
    var shallow_buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings(
        "8e6a76775124063ed8b40b8480560d52bede4e74",
        section.shallow_info.shallow[0].toHex(&shallow_buf),
    );
    var unshallow_buf: [Oid.max_formatted_length]u8 = undefined;
    try std.testing.expectEqualStrings(
        "04f3e2724ee8fd3046305a4049c3ef7573e4e362",
        section.shallow_info.unshallow[0].toHex(&unshallow_buf),
    );
}

// suspicious

test "readFetchSection rejects an unknown section header" {
    const gpa = std.testing.allocator;
    var r: std.Io.Reader = .fixed("0011bogus-header\n0000");
    var buf: [pktline_mod.Packet.max_data_length]u8 = undefined;

    try std.testing.expectError(error.ProtocolError, readFetchSection(gpa, .sha1, &r, &buf));
}
